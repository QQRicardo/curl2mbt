"""Compares the programs curl2mbt emits with curl.

    python3 tools/compare_programs.py TARGET CLI...

Builds the program for each command in `CASES` for TARGET (native or wasm),
runs it and curl against a server on 127.0.0.1, and compares the requests that
arrive, the output and whether the run succeeds. Needs a recent curl, moon, and
for the https case openssl.

Differences that are left out on purpose: the User-Agent curl sends by default,
Accept-Encoding unless the command sets it, the order of header fields, and
blanks around their values.
"""

import glob
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import urllib.parse

TARGET = sys.argv[1]
CLI = sys.argv[2:]
CURL = shutil.which("curl")
MOON = shutil.which("moon")
ASYNC = "moonbitlang/async@0.22.10"
SECRETS = {
    "TOKEN": "t0k en", "A": "x=y", "BEARER_TOKEN": "sec ret", "BASIC_AUTH": "u:p\u00e9",
    "COOKIE": "c=1; d=2", "X_API_KEY": "k\u00e9y", "BASIC_CREDENTIALS": "dTpw",
    "AUTHORIZATION_VALUE": "v", "BEARER_TOKEN_2": "other",
}

# Each case is a command line, or a text for a POSIX shell; with the codes of
# the reasons if it must be rejected.
CASES = [
    ["U"],
    ["U/a/../b?x=1&y=%20#f"],
    ["U/a|b\"<>^`c"],
    ["-g", "U/{a}?[b]"],
    ["-I", "U"],
    ["-X", "DELETE", "U"],
    ["-X", "OPTIONS", "U"],
    ["-X", "TRACE", "U"],
    ["-X", "PATCH", "-d", "x", "U"],
    ["-X", "GET", "-d", "x", "U"],
    ["-X", "POST", "U"],
    ["-X", "PUT", "-d", "", "U"],
    ["-d", "a=1", "-d", "b=2", "U"],
    ["--data-binary", "line\n\"quoted\" \\x41 \\{y}\n  #|\ttab\r\n", "U"],
    ["--data-binary", "first\n\nlast\n", "U"],
    ["--json", '{"a": "\u00e9 \U0001f600", "b": "\\u0041"}', "U"],
    ["--data-raw", "\x01\x7f\u00ad\u200e\u202e\ufeff$\\", "U"],
    ["--data-raw", "x" * 20000, "U"],
    ["--data-urlencode", "a=b c&d", "-G", "U/q?z"],
    ["-H", "X: a \"b\" \\ \\{c} \u00e9", "-H", "Y;", "U"],
    ["-H", "Accept:", "-A", "agent/1", "-e", "http://r/", "U"],
    ["-H", "Content-Type:", "-d", "x", "U"],
    ["-H", "TE: trailers", "-H", "Connection: close", "U"],
    ["-H", "Expect:", "-d", "x", "U"],
    ["-u", "u:p\u00e9", "U"],
    ["--oauth2-bearer", "sec ret", "U"],
    ["-H", "Authorization: Bearer sec ret", "-H", "X-Api-Key: k\u00e9y", "U"],
    ["-H", "Authorization: Basic dTpw", "U"],
    ["-H", "Authorization: token v", "U"],
    ["-b", "c=1; d=2", "U"],
    ["-r", "0-3", "U"],
    ["--compressed", "U/gzip"],
    ["--compressed", "-H", "Accept-Encoding: br", "U/gzip"],
    ["-f", "U/status/404"],
    ["-f", "U/status/204"],
    ["U/status/500"],
    ["-m", "20", "U"],
    ["-m", "0.5", "U/slow"],
    ["-k", "S/secure"],
    ["S/secure"],
    # Redirects
    ["-L", "U"],
    ["-L", "U/r/302?to=/t"],
    ["-L", "-d", "x", "U/r/301?to=/t"],
    ["-L", "-d", "x", "U/r/302?to=/t"],
    ["-L", "-d", "x", "U/r/303?to=/t"],
    ["-L", "-d", "x", "U/r/300?to=/t"],
    ["-L", "-d", "x", "U/r/307?to=/t"],
    ["-L", "-d", "x", "U/r/308?to=/t"],
    ["-L", "-X", "PUT", "-d", "x", "U/r/302?to=/t"],
    ["-L", "-X", "POST", "-d", "x", "U/r/303?to=/t"],
    ["-L", "-X", "GET", "-d", "x", "U/r/301?to=/t"],
    ["-L", "-X", "DELETE", "U/r/302?to=/t"],
    ["-L", "-I", "U/r/302?to=/t"],
    ["-L", "--json", "{}", "U/r/302?to=/t"],
    ["-L", "-H", "Content-Type: a/b", "-d", "x", "U/r/302?to=/t"],
    ["-L", "-d", "", "-H", "Content-Type;", "U/r/302?to=/t"],
    ["-L", "-u", "u:p\u00e9", "-d", "x", "U/r/307?to=V/t"],
    ["-L", "-u", "u:p\u00e9", "U/r/302?to=/t"],
    ["-L", "--oauth2-bearer", "sec ret", "U/r/302?to=V/t"],
    ["-L", "-H", "Cookie: c=1; d=2", "-H", "X-Api-Key: k\u00e9y", "U/r/302?to=V/t"],
    ["-L", "-H", "Cookie: c=1; d=2", "U/r/302?to=V/r/302%3Fto=U/t"],
    ["-L", "-A", "agent", "-e", "ref", "-r", "0-1", "U/r/302?to=V/t"],
    ["-L", "U/r/302?to=t"],
    ["-L", "U/r/302?to=./t/./x"],
    ["-L", "U/r/302?to=../../t"],
    ["-L", "U/r/302?to=%3Fq=1"],
    ["-L", "U/r/302?to=V"],
    ["-L", "U/r/302?to=V%3Fz"],
    ["-L", "U/r/302?to=//HOSTV/x"],
    ["-L", "U/r/302?to=/t%23frag"],
    ["-L", "U/r/302?to=/t%3F"],
    ["-L", "U/r/302?to=/%252e%252e/t//u/.."],
    ["-L", "U/r/302?to="],
    ["-L", "U/r/304"],
    ["-L", "U/loop"],
    ["-L", "--max-redirs", "0", "U/r/302?to=/t"],
    ["-L", "--max-redirs", "2", "U/loop"],
    ["-L", "--max-redirs", "0", "U"],
    ["-L", "-f", "U/r/302?to=/status/404"],
    ["-L", "U/r/302?to=javascript:1"],
    # Files and forms
    ["-d", "@f", "U"],
    ["--data-binary", "@f", "-X", "PUT", "U"],
    ["--json", "@f", "--json", "x", "U"],
    ["-d", "a=1", "--data-urlencode", "n@f", "--data-urlencode", "n@empty", "U"],
    ["--data-urlencode", "@f", "U"],
    ["-d", "@missing", "U"],
    ["-F", "a=1", "-F", "b=\u00e9 \"x\"", "U"],
    ["-F", "a\n\"\u00e9=b;type=text/html;filename=\"x;\\\"\u202e\"", "U"],
    ["-F", "a=@f", "-F", "b=<f", "-F", "c=@empty;filename=p.png", "U"],
    ["-F", "a=@missing", "U"],
    ["--form-string", "a=@f;", "--form-string", "b=--------------------------form", "U"],
    ["-F", "a=1", "-H", "Content-Type: multipart/form-data", "-X", "PUT", "U"],
    ["-T", "f", "U/up/"],
    ["-T", "f", "-X", "POST", "--url-query", "a=b c", "U/up"],
    ["-T", "missing", "U/up"],
    ["-L", "-T", "f", "U/r/301?to=/t"],
    ["-L", "-T", "f", "U/r/302?to=/t"],
    ["-L", "-T", "f", "U/r/303?to=/t"],
    ["-L", "-T", "f", "U/r/307?to=V/t"],
    ["-L", "-T", "f", "-X", "POST", "U/r/303?to=/t"],
    ["-L", "-F", "a=@f", "U/r/307?to=V/t"],
    ["-L", "-F", "a=@f", "U/r/302?to=/t"],
    ["-L", "-d", "@f", "U/r/308?to=/t"],
    ["-L", "-d", "@f", "U/r/303?to=/t"],
    # Output
    ["-o", "out", "U"],
    ["-o", "old", "U/empty"],
    ["-o", "-", "U"],
    ["-o", "sub/out", "U"],
    ["--create-dirs", "-o", "sub/deeper/out", "U"],
    ["-o", "exists", "U"],
    ["-O", "U/x/a%20b.txt?q=1"],
    ["-O", "U/x/"],
    ["-O", "U"],
    ["--output-dir", "exists", "-O", "U/x/f.txt"],
    ["--output-dir", "nodir", "-o", "out", "U"],
    ["--output-dir", "nodir", "--create-dirs", "-O", "U/f.txt"],
    ["-f", "-o", "out", "U/status/404"],
    ["-f", "-o", "old", "U/status/404"],
    ["--fail-with-body", "-o", "out", "U/status/404"],
    ["--fail-with-body", "U/status/404"],
    ["-f", "--fail-with-body", "U/status/500"],
    ["-o", "out", "U/status/404"],
    ["-L", "-o", "out", "U/r/302?to=/t"],
    ["-O", "-o", "b", "U/x/a"],
    ["--remote-name-all", "-o", "x", "U/y"],
    ["--remote-name-all", "--no-remote-name", "U/y"],
    ["-O", "--no-remote-name", "U/y"],
    "curl U --form-string \"a=$TOKEN\" --form-string 'b=x'\"$A\"",
    "curl U --data-raw \"$A\" ",
    "curl U -d \"x$A\" -d @f",
    # Texts
    "curl U -H \"Authorization: Bearer $TOKEN\" -H 'Authorization-Extra: y'",
    "curl U --data-raw \"$A$TOKEN\" -u \"$TOKEN:${A}\"",
    "curl U --data-raw \"{\\\"k\\\": \\\"$TOKEN\\\"}\" -H \"X: \\\"$A\\\" $A\"",
    "curl U --data-raw $'\\xff\\xfe\\\\\"\\n\\x01'",
    "curl U --data-raw $'\\xff'\"$A\"",
    "curl U -H \"A: $BEARER_TOKEN\" --oauth2-bearer other",
    # Rejected
    (["-X", "PURGE", "U"], ["unsupported-method"]),
    (["-X", "get", "U"], ["unsupported-method"]),
    (["-X", "CONNECT", "U"], ["unsupported-method"]),
    (["-A", "", "U"], ["unsupported-header"]),
    (["-H", "User-Agent:", "U"], ["unsupported-header"]),
    (["-H", "X: 1", "-H", "x: 2", "U"], ["duplicate-header"]),
    (["-H", "Host: x", "U"], ["unsupported-header"]),
    (["-H", "TE: gzip", "-H", "Upgrade: h2c", "U"], ["unsupported-header"] * 2),
    (["-L", "-b", "a=b", "U"], ["unsupported-redirects"]),
    (["http://[::1]/"], ["unsupported-host"]),
    (["-d", "@-", "U"], ["file-not-supported"]),
    (["-o", "", "U"], ["unsupported-value"]),
    (["-J", "-O", "U"], ["unsupported-option"]),
    (["--no-clobber", "-o", "old", "U"], ["unsupported-option"]),
    ("curl U -d $'\\xff\\x00y'", ["shell-syntax"]),
]


class Server:
    def __init__(self, context=None):
        self.socket = socket.socket()
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(16)
        self.context = context
        self.authority = "127.0.0.1:%d" % self.socket.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            connection, _ = self.socket.accept()
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()

    def handle(self, connection):
        connection.settimeout(3)
        data = b""
        try:
            if self.context:
                connection = self.context.wrap_socket(connection, server_side=True)
            while not complete(data):
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
            if data:
                REQUESTS.append((self.authority, data))
                connection.sendall(answer(data))
        except OSError:
            pass
        connection.close()


REQUESTS = []


def complete(data):
    head, end, body = data.partition(b"\r\n\r\n")
    if not end:
        return False
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.lower() == b"content-length":
            return len(body) >= int(value)
    return True


def answer(data):
    method, target = data.split(b" ", 2)[:2]
    parts = urllib.parse.urlsplit(target.decode())
    status, fields, body = 200, [], b"answer\n"
    if parts.path[:3] == "/r/" and parts.path[3:].isdigit():
        status = int(parts.path[3:])
        for pair in parts.query.split("&"):
            if pair.startswith("to="):
                fields.append("Location: " + urllib.parse.unquote(pair[3:]))
    elif parts.path == "/loop":
        status, fields = 302, ["Location: /loop"]
    elif parts.path.startswith("/status/"):
        status = int(parts.path[8:])
    elif parts.path == "/slow":
        import time

        time.sleep(2)
    elif parts.path == "/gzip":
        import gzip

        offered = [l for l in data.split(b"\r\n") if l.lower().startswith(b"accept-encoding:")]
        if offered and b"gzip" in offered[0]:
            fields, body = ["Content-Encoding: gzip"], gzip.compress(body)
    if method == b"HEAD" or status in (204, 304):
        length, body = len(body), b""
        fields.append("Content-Length: %d" % (0 if status == 204 else length))
    else:
        fields.append("Content-Length: %d" % len(body))
    if status == 204:
        fields.pop()
    head = ["HTTP/1.1 %d X" % status, "Connection: close"] + fields
    return ("\r\n".join(head) + "\r\n\r\n").encode() + body


def normal(requests, plan):
    """The requests without what is left out on purpose."""
    names = {header["name"].lower() for header in plan["headers"]}
    out = []
    for authority, data in requests:
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        fields = []
        for line in lines[1:]:
            name, _, value = line.partition(b":")
            name = name.lower().decode()
            if name == "user-agent" and name not in names:
                continue
            if name == "accept-encoding" and (name not in names or plan.get("compressed")):
                continue
            fields.append((name, value.strip(b" \t")))
        for i, (name, value) in enumerate(fields):
            start, found, boundary = value.partition(b"; boundary=")
            if name == "content-type" and found:
                # The boundary is not the same, nor is the length then.
                if boundary in body.replace(b"--" + boundary, b""):
                    raise AssertionError("the boundary occurs in a part")
                fields[i] = (name, start)
                body = body.replace(b"--" + boundary, b"--BOUNDARY")
                fields = [(n, b"" if n == "content-length" else v) for n, v in fields]
        out.append((authority, lines[0], sorted(fields), body))
    return out


def run_in(files, command, environment):
    """Runs `command` in a new copy of `files`, with a directory `exists` and
    a file `old`, and gives what it changed there."""
    directory = tempfile.mkdtemp()
    work = os.path.join(directory, "w")
    shutil.copytree(files, work)
    os.mkdir(os.path.join(work, "exists"))
    with open(os.path.join(work, "old"), "wb") as file:
        file.write(b"old content")
    before = snapshot(work)
    result = subprocess.run(command, capture_output=True, env=environment, cwd=work)
    after = snapshot(work)
    shutil.rmtree(directory, ignore_errors=True)
    return result, {k: v for k, v in after.items() if before.get(k) != v}


def snapshot(directory):
    out = {}
    for root, directories, names in os.walk(directory):
        for name in directories:
            out[os.path.relpath(os.path.join(root, name), directory) + "/"] = b""
        for name in names:
            path = os.path.join(root, name)
            with open(path, "rb") as file:
                out[os.path.relpath(path, directory)] = file.read()
    return out


def cli(arguments):
    result = subprocess.run(CLI + arguments, capture_output=True)
    if result.returncode not in (0, 1):
        raise SystemExit(result.stdout.decode() + result.stderr.decode())
    return result.returncode == 0, result.stdout.decode()


def main():
    directory = tempfile.mkdtemp()
    servers = {"U": Server(), "V": Server()}
    if shutil.which("openssl"):
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
             "-subj", "/CN=localhost", "-keyout", directory + "/key", "-out", directory + "/cert"],
            check=True, capture_output=True,
        )
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(directory + "/cert", directory + "/key")
        servers["S"] = Server(context)

    def fill(text):
        text = text.replace("HOSTV", servers["V"].authority)
        for name, server in servers.items():
            scheme = "https" if name == "S" else "http"
            for before in ("", "=", " "):
                for after in ("/", "?", "%", ""):
                    old = before + name + after
                    new = before + scheme + "://" + server.authority + after
                    if after == "":
                        if text == old:
                            text = new
                        elif text.endswith(old) and before:
                            text = text[: -len(old)] + new
                    elif before == "":
                        if text.startswith(old):
                            text = new + text[len(old):]
                    else:
                        text = text.replace(old, new)
        return text

    failures, programs, rejected = [], [], 0
    files = os.path.join(directory, "files")
    os.mkdir(files)
    for name, data in (("f", b"a b\r\nc\0d&\xff\n"), ("empty", b"")):
        with open(os.path.join(files, name), "wb") as file:
            file.write(data)
    project = os.path.join(directory, "programs")
    os.mkdir(project)
    with open(project + "/moon.mod", "w") as file:
        file.write('name = "test/programs"\n\nversion = "0.1.0"\n\nimport {\n  "%s",\n}\n' % ASYNC)
    for number, case in enumerate(CASES):
        case, codes = case if isinstance(case, tuple) else (case, None)
        if isinstance(case, str):
            text = case.replace("curl U", "curl http://" + servers["U"].authority)
            arguments = ["--text", text]
        else:
            if any(a.startswith("S/") for a in case) and "S" not in servers:
                print("skipped, no openssl: %r" % case)
                continue
            arguments = ["curl"] + [fill(a) for a in case]
        ok, output = cli(arguments)
        if codes is not None or not ok:
            found = [l[6 : l.index("]")] for l in output.splitlines() if l.startswith("error[")]
            if ok or found != codes:
                failures.append("%r: wanted %r, got %r" % (case, codes, found if not ok else "a program"))
            rejected += 1
            continue
        plan = json.loads(cli(["--plan"] + arguments)[1])["plan"]
        package = "case%d" % number
        os.mkdir(os.path.join(project, package))
        imports = [l[8:] for l in output.splitlines() if l.startswith('//     "')]
        with open(os.path.join(project, package, "moon.pkg"), "w") as file:
            file.write("import {\n%s\n}\n\npkgtype(kind: \"executable\")\n" % "\n".join('  "' + i for i in imports))
        with open(os.path.join(project, package, "main.mbt"), "w", encoding="utf-8", newline="\n") as file:
            file.write(output)
        programs.append((case, arguments, plan, package))
    build = [MOON, "-C", project, "build", "--target", TARGET, "--deny-warn"]
    result = subprocess.run(build, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(result.stdout.decode() + result.stderr.decode())
    same = 0
    for case, arguments, plan, package in programs:
        extension = "exe" if TARGET == "native" else "wasm"
        path = "%s/_build/%s/**/%s/%s.%s" % (project, TARGET, package, package, extension)
        binary = glob.glob(path, recursive=True)[0]
        command = [binary] if TARGET == "native" else [shutil.which("moonrun"), binary]
        environment = dict(os.environ, **SECRETS, LC_ALL="C.UTF-8")
        REQUESTS.clear()
        ours, our_files = run_in(files, command, environment)
        our_requests = normal(REQUESTS, plan)
        options = " -q -sS"
        if arguments[0] == "--text":
            script = directory + "/script"
            with open(script, "w", encoding="utf-8", newline="") as file:
                file.write(arguments[1].replace("curl", "curl" + options, 1))
            run = [shutil.which("bash"), "--norc", script]
        else:
            run = [CURL, "-q", "-sS"] + arguments[1:]
        REQUESTS.clear()
        theirs, their_files = run_in(files, run, environment)
        their_requests = normal(REQUESTS, plan)
        # With -I and -f, curl shows other things than the body.
        output = "-I" in case or (theirs.returncode != 0) or ours.stdout == theirs.stdout
        if (our_requests != their_requests or not output or our_files != their_files
                or (ours.returncode == 0) != (theirs.returncode == 0)):
            failures.append("%r\nprogram %r %r %d %r %r\ncurl    %r %r %d %r %r" % (
                case, our_requests[:4], ours.stdout, ours.returncode, ours.stderr[-300:], our_files,
                their_requests[:4], theirs.stdout, theirs.returncode, theirs.stderr[-300:], their_files))
        else:
            same += 1
    for failure in failures:
        print(failure)
    print("%s: %d programs behave like curl, %d commands rejected, %d failures" % (TARGET, same, rejected, len(failures)))
    shutil.rmtree(directory, ignore_errors=True)
    if failures:
        raise SystemExit(1)


main()

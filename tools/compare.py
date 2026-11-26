"""Compares what curl2mbt reads from commands with what curl and bash do.

    python3 tools/compare.py CLI...

CLI... starts curl2mbt, such as `path/to/main.exe`. Needs bash and a recent
curl (8.18 and 8.19 are known to work); all requests go to a server this
script runs on 127.0.0.1. SEED in the environment picks other random cases.

1. Each command line in `ARGV_CASES`, and random ones, are run by curl against
   the server, and the request that arrives is compared with the plan.
2. Each text in `TEXT_CASES`, and random ones, are read by bash with a program
   named curl that only shows its arguments; the plan of the text must be the
   plan of these arguments.

3. Each config file in `CONFIG_CASES`, and random ones, are read by curl with
   `-K` and by curl2mbt with `--config`, and compared as in 1.

4. Each command of 1, 2 and 3 that curl2mbt accepts is written back with
   `--to-curl posix`. bash runs that text with curl, and the request must be
   the same, or with the program that shows its arguments, and the plan of
   these must be the same but for which header fields are implied.

A command that curl2mbt rejects is counted, not compared; the lists say which
ones those must be. Something curl2mbt accepts must be the same. Differences
that are left out on purpose: the User-Agent curl sends by default, Host
unless the command sets it, Content-Length (checked against the body), and
blanks around header values.
"""

import base64
import json
import os
import random
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.parse

from compare_cases import (
    ARGV_CASES, ARGV_PARTS, CONFIG_CASES, CONFIG_OPTIONS, CONFIG_PARTS, CONFIG_SEPARATORS, FORM_PARTS, TEXT_CASES, TEXT_PARTS,
)

CLI = sys.argv[1:]
CURL = shutil.which("curl")
BASH = shutil.which("bash")
DIRECTORY = tempfile.mkdtemp()
FILES = {
    "sub/q?#\u00e9.bin": b"z", "{x}": b"braces",
    "f": b"a b\r\nc\0d&\xff\n", "empty": b"", "t.txt": b"text", "p.PNG": b"\x89P",
    "j.json": b"{}\n", "d e;f,g.xml": b"<x/>",
}
VARIABLES = {"TOKEN": "t0k en", "EMPTY": "", "A_1": "x=y"}
RANDOM_ARGV = 1500
RANDOM_FORM = 1500
RANDOM_TEXT = 5000
RANDOM_CONFIG = 1500


class Server:
    """Keeps the bytes of each request and answers with 200."""

    def __init__(self):
        self.socket = socket.socket()
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(16)
        self.authority = "127.0.0.1:%d" % self.socket.getsockname()[1]
        self.requests = []
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            connection, _ = self.socket.accept()
            connection.settimeout(3)
            data = b""
            try:
                while not self.complete(data):
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    data += chunk
            except OSError:
                pass
            self.requests.append(data)
            try:
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
            except OSError:
                pass
            connection.close()

    @staticmethod
    def complete(data):
        head, end, body = data.partition(b"\r\n\r\n")
        if not end:
            return False
        for line in head.split(b"\r\n")[1:]:
            name, _, value = line.partition(b":")
            if name.lower() == b"content-length":
                return len(body) >= int(value)
        return True


def value_bytes(value):
    if isinstance(value, str):
        return value.encode()
    out = b""
    for piece in value:
        if "text" in piece:
            out += piece["text"].encode()
        elif "base64" in piece:
            out += base64.b64decode(piece["base64"])
        elif "file" in piece:
            out += file_bytes(piece)
        else:
            out += VARIABLES[piece["env"]].encode()
    return out


def file_bytes(piece):
    with open(os.path.join(DIRECTORY, piece["file"]), "rb") as file:
        data = file.read()
    if piece.get("without_line_breaks"):
        return data.translate(None, b"\r\n\0")
    if "form_encoded" in piece:
        if not data:
            return b""
        name = piece["form_encoded"]
        encoded = urllib.parse.quote_plus(data, safe="").encode()
        return (name + "=" if name else "").encode() + encoded
    return data


def form_parts(boundary, body):
    """The parts of a multipart body."""
    parts = (b"\r\n" + body).split(b"\r\n--" + boundary)
    if parts[0] or parts[-1] != b"--\r\n":
        raise AssertionError("not a multipart body")
    return [part[2:] for part in parts[1:-1]]


def expected(plan):
    """The request line, fields and body a plan stands for, the body of a form
    as its parts."""
    rest = plan["url"].split("://", 1)[1]
    authority, slash, target = rest.partition("/")
    fields = []
    auth = plan.get("auth", {})
    if "basic" in auth:
        token = base64.b64encode(value_bytes(auth["basic"]))
        fields.append((b"authorization", b"Basic " + token))
    if "bearer" in auth:
        fields.append((b"authorization", b"Bearer " + value_bytes(auth["bearer"])))
    for header in plan["headers"]:
        fields.append((header["name"].lower().encode(), value_bytes(header["value"])))
    body = None
    if "data" in plan.get("body", {}):
        body = value_bytes(plan["body"]["data"])
    elif "upload" in plan.get("body", {}):
        body = file_bytes({"file": plan["body"]["upload"]})
    elif "body" in plan:
        fields.append((b"content-type", b"multipart/form-data"))
        body = []
        for part in plan["body"]["multipart"]:
            escaped = [
                part.get(key, "").replace("\r", "%0D").replace("\n", "%0A").replace('"', "%22")
                for key in ("name", "filename")
            ]
            head = 'Content-Disposition: form-data; name="%s"' % escaped[0]
            if "filename" in part:
                head += '; filename="%s"' % escaped[1]
            if "type" in part:
                head += "\r\nContent-Type: " + part["type"]
            body.append(head.encode() + b"\r\n\r\n" + value_bytes(part["content"]))
    line = ("%s /%s" % (plan["method"], target)).encode()
    return line, sorted(fields), body


def received(data, plan):
    """What arrived, without what is left out on purpose."""
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    set_names = {header["name"].lower() for header in plan["headers"]}
    fields, length, body_parts = [], None, None
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        name, value = name.lower(), value.strip(b" \t")
        if name == b"content-length":
            length = int(value)
            continue
        if name == b"host" and "host" not in set_names:
            continue
        if name == b"user-agent" and "user-agent" not in set_names:
            if plan.get("omit_user_agent"):
                raise AssertionError("a User-Agent was sent")
            continue
        start, found, boundary = value.partition(b"; boundary=")
        if name == b"content-type" and found:
            value, body_parts = start, form_parts(boundary, body)
        fields.append((name, value))
    if length is not None and length != len(body):
        raise AssertionError("Content-Length does not fit the body")
    line = lines[0].rsplit(b" HTTP/1.1", 1)[0]
    if body_parts is not None:
        return line, sorted(fields), body_parts
    return line, sorted(fields), None if length is None else body


def run_cli(arguments):
    """The plan, or the codes of the reasons it was rejected for."""
    result = subprocess.run(CLI + ["--plan"] + arguments, capture_output=True)
    output = result.stdout.decode()
    if result.returncode == 0:
        return json.loads(output)["plan"], None
    if result.returncode == 1:
        lines = [l for l in output.splitlines() if l.startswith("error[")]
        if lines:
            return None, [l[6 : l.index("]")] for l in lines]
    raise SystemExit("curl2mbt failed: %r\n%s%s" % (arguments, output, result.stderr.decode()))


ROUND_TRIP = {}
NOT_EXPRESSIBLE = {}


def to_curl(arguments):
    """The text of `--to-curl posix`, or None if there is none."""
    result = subprocess.run(CLI + ["--to-curl", "posix"] + arguments, capture_output=True)
    if result.returncode == 0:
        return result.stdout.decode()
    if result.returncode == 1 and result.stdout.startswith(b"error[not-expressible]"):
        reason = result.stdout.decode().strip()[len("error[not-expressible]: "):]
        NOT_EXPRESSIBLE.setdefault(reason, arguments)
        return None
    raise SystemExit("curl2mbt failed: %r\n%s%s" % (arguments, result.stdout.decode(), result.stderr.decode()))


def tally(outcome):
    ROUND_TRIP[outcome] = ROUND_TRIP.get(outcome, 0) + 1
    if outcome not in ("same", "not expressible"):
        print(outcome)


def round_trip_argv(server, arguments, plan, want):
    """Sends what `--to-curl` writes for the command of `arguments` with bash
    and curl."""
    text = to_curl(arguments)
    if text is None:
        return tally("not expressible")
    script = DIRECTORY + "-script"
    with open(script, "w", encoding="utf-8", newline="") as file:
        file.write("'%s' -q -sS --max-time 5%s" % (CURL, text[len("curl"):]))
    server.requests.clear()
    result = subprocess.run([BASH, "--norc", "--noprofile", script], capture_output=True, cwd=DIRECTORY)
    if len(server.requests) != 1:
        return tally("round trip %r -> %r: curl made %d requests: %r" % (
            arguments, text, len(server.requests), result.stderr))
    try:
        got = received(server.requests[0], plan)
    except AssertionError as error:
        return tally("round trip %r -> %r: %s" % (arguments, text, error))
    tally("same" if got == want else "round trip %r -> %r:\nplan %r\ncurl %r" % (arguments, text, want, got))


def without_implied(plan):
    return dict(plan, headers=[{k: v for k, v in h.items() if k != "implied"} for h in plan["headers"]])


def round_trip_text(text, plan, directory):
    """Reads what `--to-curl` writes for `text` with bash."""
    again = to_curl(["--text", text])
    if again is None:
        return tally("not expressible")
    words = bash_arguments(again, directory)
    if words is None:
        return tally("round trip %r -> %r: bash does not run this" % (text, again))
    try:
        words = [word.decode() for word in words]
    except UnicodeDecodeError:
        return tally("same")
    other, codes = run_cli(["curl"] + words)
    if other is None:
        return tally("round trip %r -> %r: rejected %s" % (text, again, codes))
    same = without_implied(substitute(plan)) == without_implied(other)
    tally("same" if same else "round trip %r -> %r:\nplan %r\nbash %r" % (text, again, plan, other))


def names_missing_file(node):
    if isinstance(node, dict):
        if "file" in node:
            return not os.path.isfile(os.path.join(DIRECTORY, node["file"]))
        return any(names_missing_file(x) for x in node.values())
    return isinstance(node, list) and any(names_missing_file(x) for x in node)


def compare_argv(server, arguments):
    """`same`, `rejected ...`, or what differs."""
    arguments = [a.replace("HOST", server.authority) for a in arguments]
    return compare_with_curl(server, ["curl"] + arguments, arguments)


def compare_config(server, text):
    """Like `compare_argv`, for the text of a config file."""
    path = DIRECTORY + "-config"
    with open(path, "w", encoding="utf-8", newline="") as file:
        file.write(text.replace("HOST", server.authority))
    return compare_with_curl(server, ["--config", path], ["-K", path])


def compare_with_curl(server, cli_arguments, arguments):
    """Compares the plan of `cli_arguments` with what curl sends for
    `arguments`."""
    plan, codes = run_cli(cli_arguments)
    if plan is None:
        return "rejected " + " ".join(codes)
    server.requests.clear()
    result = subprocess.run(
        [CURL, "-q", "-sS", "--max-time", "5"] + arguments, capture_output=True, cwd=DIRECTORY
    )
    if names_missing_file(plan):
        return "same" if result.returncode == 26 else "curl reads this file"
    if len(server.requests) != 1:
        return "curl made %d requests: %r" % (len(server.requests), result.stderr)
    try:
        want, got = expected(plan), received(server.requests[0], plan)
    except AssertionError as error:
        return str(error)
    if want != got:
        return "plan %r\ncurl %r" % (want, got)
    round_trip_argv(server, cli_arguments, plan, want)
    return "same"


def bash_arguments(text, directory):
    """The arguments bash gives to the program curl, or None."""
    environment = {"PATH": directory + os.pathsep + os.environ["PATH"]}
    # bash writes \u escapes in the encoding of the locale.
    environment["LC_ALL"] = "C.UTF-8"
    environment.update(VARIABLES)
    script = os.path.join(directory, "script")
    with open(script, "w", encoding="utf-8", newline="") as file:
        file.write(text)
    result = subprocess.run(
        [BASH, "--norc", "--noprofile", script],
        capture_output=True,
        cwd=os.path.join(directory, "empty"),
        env=environment,
    )
    if result.returncode != 0 or not result.stdout.endswith(b"\0"):
        return None
    return result.stdout.split(b"\0")[:-1]


def substitute(plan):
    """The plan with the variables replaced by what they hold."""

    def walk(node):
        if isinstance(node, dict):
            return {k: walk(v) for k, v in node.items()}
        if isinstance(node, list):
            if node and all(isinstance(x, dict) and set(x) <= {"text", "base64", "env"} for x in node):
                data = value_bytes(node)
                try:
                    return data.decode()
                except UnicodeDecodeError:
                    return [{"base64": base64.b64encode(data).decode()}]
            return [walk(x) for x in node]
        return node

    return walk(plan)


def compare_text(text, directory):
    plan, codes = run_cli(["--text", text])
    if plan is None:
        return "rejected " + " ".join(codes)
    words = bash_arguments(text, directory)
    if words is None:
        return "bash does not run this"
    try:
        words = [word.decode() for word in words]
    except UnicodeDecodeError:
        return "same"
    other, codes = run_cli(["curl"] + words)
    if other is None:
        return "the arguments of bash are rejected: %s %r" % (codes, words)
    if substitute(plan) != other:
        return "plan %r\nbash %r" % (plan, other)
    round_trip_text(text, plan, directory)
    return "same"


def main():
    failures = 0

    def check(kind, case, outcome, want=None):
        nonlocal failures
        ok = outcome == want if want else outcome == "same" or outcome.startswith("rejected")
        if not ok:
            failures += 1
            print("%s %r: wanted %s, got\n%s" % (kind, case, want, outcome))
        return outcome.split(" ")[0]

    os.mkdir(os.path.join(DIRECTORY, "sub"))
    for name, data in FILES.items():
        with open(os.path.join(DIRECTORY, name), "wb") as file:
            file.write(data)
    server = Server()
    counts = {}

    def count(kind, outcome):
        counts[kind, outcome] = counts.get((kind, outcome), 0) + 1

    for want, case in ARGV_CASES:
        count("listed arguments", check("arguments", case, compare_argv(server, case), want))
    source = random.Random(int(os.environ.get("SEED", "1")))
    for _ in range(RANDOM_ARGV):
        parts = [source.choice(ARGV_PARTS) for _ in range(source.randint(1, 5))]
        case = [a for part in parts for a in part] + ["http://HOST/p?q=1"]
        count("random arguments", check("arguments", case, compare_argv(server, case)))
    for _ in range(RANDOM_FORM):
        text = "".join(source.choice(FORM_PARTS) for _ in range(source.randint(1, 8)))
        case = ["-F", "a=" + text, "http://HOST/"]
        count("random forms", check("form", case, compare_argv(server, case)))

    for want, text in CONFIG_CASES:
        count("listed config files", check("config", text, compare_config(server, text), want))
    for _ in range(RANDOM_CONFIG):
        lines = ["url = http://HOST/"]
        for _ in range(source.randint(1, 3)):
            option = source.choice(CONFIG_OPTIONS) + source.choice(CONFIG_SEPARATORS)
            lines.append(option + "".join(source.choice(CONFIG_PARTS) for _ in range(source.randint(0, 6))))
        text = "\n".join(lines) + source.choice(["", "\n", "\r\n"])
        count("random config files", check("config", text, compare_config(server, text)))

    with tempfile.TemporaryDirectory() as directory:
        os.mkdir(os.path.join(directory, "empty"))
        stub = os.path.join(directory, "curl")
        with open(stub, "w", newline="\n") as file:
            file.write("#!/bin/sh\nprintf '%s\\0' \"$@\"\n")
        os.chmod(stub, 0o755)
        for want, text in TEXT_CASES:
            count("listed texts", check("text", text, compare_text(text, directory), want))
        for _ in range(RANDOM_TEXT):
            words = "".join(source.choice(TEXT_PARTS) for _ in range(source.randint(1, 8)))
            text = "curl http://h/ --data-raw x%s" % words
            count("random texts", check("text", text, compare_text(text, directory)))

    shutil.rmtree(DIRECTORY, ignore_errors=True)
    for (kind, outcome), number in sorted(counts.items()):
        print("%s: %d %s" % (kind, number, outcome))
    for outcome in ("same", "not expressible"):
        print("written back: %d %s" % (ROUND_TRIP.pop(outcome, 0), outcome))
    for reason, example in sorted(NOT_EXPRESSIBLE.items()):
        print("  not expressible: %s, as for %r" % (reason, example))
    failures += sum(ROUND_TRIP.values())
    if failures:
        raise SystemExit("%d failures" % failures)


main()

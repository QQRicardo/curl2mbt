"""Compares what curl2mbt reads from commands for cmd with what cmd.exe and
curl.exe do. Runs on Windows only.

    python tools/compare_cmd.py CLI...

Each text in `CASES`, and random ones, are given to the prompt of cmd.exe,
where curl.exe of Windows sends the request to a server this script runs on
127.0.0.1; the target and the body that arrive are compared with the plan.
SEED in the environment picks other random cases.

What `--to-curl cmd` writes for each text that curl2mbt accepts goes through
cmd.exe and curl.exe as well, and its plan must be the same but for which
header fields are implied.

A command that curl2mbt rejects is counted, not compared. All texts are ASCII,
since curl for Windows sends other characters in the code page of the system.
"""

import base64
import json
import os
import random
import socket
import subprocess
import sys
import threading

CLI = sys.argv[1:]
SYSTEM = os.path.join(os.environ["SystemRoot"], "System32")
VARIABLES = {"TOKEN": "t0k en", "A_1": "x=y"}
RANDOM = 1500

# How Chrome writes strings for cmd.
CHROME = (
    'curl ^"http://HOST/a?b=1^&c=^%^20^%^41^" ^\n'
    '  -H ^"accept: */*^" ^\n'
    '  -H ^"x: ^\\^"quoted^\\^" ^%^TOKEN^% a^|b^<c^>^^^" ^\n'
    '  --data-raw ^"^{^\\^"a^\\^":^\\^"b \\\\ \\n^\\^",^\n\n^\\^"c^\\^":^[1^]^}^"'
)

CASES = [
    "curl http://HOST/",
    "\n\n  curl http://HOST/  \n\n",
    "CURL.EXE http://HOST/",
    '"curl" "http://HOST/"',
    'curl "http://HOST/?a=1&b=2"',
    "curl http://HOST/?a=1^&b=2",
    'curl ^"http://HOST/?a=1^&b=2^"',
    "curl http://HOST/ ^\n  -d x",
    "curl http://HOST/ ^\n-d ^\n\"x\"",
    "curl http://HOST/ ^\r\n  -d x\r\n",
    'curl http://HOST/ -d "a^b"',
    "curl http://HOST/ -d a^^b^c",
    'curl http://HOST/ -d "a\\"b\\\\\\"c\\\\"',
    'curl http://HOST/ -d "a\\b\\\\c" -d \\\\x\\',
    'curl http://HOST/ -d ""',
    'curl http://HOST/ -d a"b c"d',
    'curl http://HOST/ -d "a | b & c > d"',
    'curl http://HOST/ -d \\"a -d b\\"',
    "curl http://HOST/ -d 'a' -d 'b",
    "curl http://HOST/ -d (a) -d a,b;c=d -d !x! -d {y}",
    'curl http://HOST/ --data-raw "%TOKEN%a%A_1%b"',
    'curl http://HOST/ -d "%20%41%C3%A9 100% %% %a b%"',
    'curl http://HOST/ -d "%^TOKEN%"',
    'curl http://HOST/ --data-raw ^"%TOKEN%^"',
    "curl http://HOST/ -d a^\n\nb",
    'curl http://HOST/ -d "a"^\n\n"b"',
    'curl http://HOST/ -d ^"a^\n\nb^"',
    "curl\thttp://HOST/\t-d\tx",
    CHROME,
]

# Put together at random, after `curl http://HOST/ --data-raw x`. A command
# that does not end there would not reach the server.
PARTS = [
    "a", "b", " ", '"', '"', "^", "^", '^"', '^"', "\\", '\\"', "\\\\", "^\n", "^\n\n",
    "%", "%20", "%TOKEN%", "%A_1%", "^%", "%^", "'", "(", ")", ",", ";", "=", "!", "{", "}",
    "\t", "^&", "^|", "^<", "^>", "^^", "@", ":", "/", "~", "`", "$",
]


class Server:
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
                self.requests.append(data)
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
        else:
            out += VARIABLES[piece["env"]].encode()
    return out


def read(text):
    """The plan, or the codes of the reasons it was rejected for."""
    result = subprocess.run(
        CLI + ["--plan", "--shell", "cmd", "--text", text], capture_output=True
    )
    output = result.stdout.decode()
    if result.returncode == 0:
        return json.loads(output)["plan"], None
    if result.returncode == 1:
        return None, [l[6 : l.index("]")] for l in output.splitlines() if l.startswith("error[")]
    raise SystemExit("curl2mbt failed: %r\n%s%s" % (text, output, result.stderr.decode()))


ROUND_TRIP = {}


def without_implied(plan):
    return dict(plan, headers=[{k: v for k, v in h.items() if k != "implied"} for h in plan["headers"]])


def round_trip(server, text, plan):
    result = subprocess.run(CLI + ["--to-curl", "cmd", "--shell", "cmd", "--text", text], capture_output=True)
    if result.returncode == 1 and result.stdout.startswith(b"error[not-expressible]"):
        return "not expressible"
    if result.returncode != 0:
        raise SystemExit("curl2mbt failed: %r\n%s%s" % (text, result.stdout.decode(), result.stderr.decode()))
    again = result.stdout.decode()
    other, codes = read(again)
    if other is None:
        return "%r is rejected: %s" % (again, codes)
    if without_implied(other) != without_implied(plan):
        return "%r reads as\n%r" % (again, other)
    outcome = compare(server, again, write_back=False)
    return outcome if outcome == "same" else "%r: %s" % (again, outcome)


def compare(server, text, write_back=True):
    text = text.replace("HOST", server.authority)
    plan, codes = read(text)
    if plan is None:
        return "rejected " + " ".join(codes)
    # Every byte of the text is seen by a prompt, as when it is pasted.
    environment = dict(os.environ, **VARIABLES, PATH=SYSTEM, CURL_HOME="C:\\nowhere")
    script = text.replace("\r\n", "\n").replace("\n", "\r\n") + "\r\nexit\r\n"
    server.requests.clear()
    subprocess.run(
        [os.path.join(SYSTEM, "cmd.exe"), "/D", "/Q", "/V:OFF", "/K"],
        input=script.encode(), capture_output=True, env=environment, timeout=30,
    )
    if len(server.requests) != 1:
        return "curl made %d requests" % len(server.requests)
    head, _, body = server.requests[0].partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    got = {"line": lines[0].rsplit(b" ", 1)[0], "body": body, "headers": []}
    names = {h["name"].lower() for h in plan["headers"]}
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        if name.decode().lower() in names:
            got["headers"].append((name.decode().lower(), value.strip(b" \t")))
    target = "/" + plan["url"].split("://", 1)[1].partition("/")[2]
    data = plan["body"]["data"] if "body" in plan else ""
    want = {
        "line": ("%s %s" % (plan["method"], target)).encode(),
        "body": value_bytes(data),
        "headers": sorted((h["name"].lower(), value_bytes(h["value"])) for h in plan["headers"]),
    }
    got["headers"].sort()
    if want != got:
        return "plan %r\ncmd  %r" % (want, got)
    if write_back:
        outcome = round_trip(server, text, plan)
        ROUND_TRIP[outcome] = ROUND_TRIP.get(outcome, 0) + 1
        if outcome not in ("same", "not expressible"):
            print("written back %r: %s" % (text, outcome))
    return "same"


def main():
    server = Server()
    failures, counts = 0, {}
    cases = [(case, True) for case in CASES]
    source = random.Random(int(os.environ.get("SEED", "1")))
    for _ in range(RANDOM):
        text = "".join(source.choice(PARTS) for _ in range(source.randint(1, 8)))
        cases.append(("curl http://HOST/ --data-raw x" + text, False))
    for text, listed in cases:
        outcome = compare(server, text)
        if outcome != "same" and (listed or not outcome.startswith("rejected")):
            failures += 1
            print("%r: %s" % (text, outcome))
        kind = ("listed" if listed else "random", outcome.split(" ")[0])
        counts[kind] = counts.get(kind, 0) + 1
    for (kind, outcome), number in sorted(counts.items()):
        print("%s: %d %s" % (kind, number, outcome))
    for outcome in ("same", "not expressible"):
        print("written back: %d %s" % (ROUND_TRIP.pop(outcome, 0), outcome))
    failures += sum(ROUND_TRIP.values())
    if failures:
        raise SystemExit("%d failures" % failures)


main()

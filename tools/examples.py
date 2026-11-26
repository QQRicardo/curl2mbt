"""Writes the programs in examples/ from the commands in examples/commands/.

    python3 tools/examples.py [--check] CLI...

CLI... starts curl2mbt, such as `path/to/main.exe`. For each command
`NAME.sh` (for a POSIX shell) or `NAME.cmd.txt` (for the prompt of cmd.exe),
the program goes to `examples/NAME/main.mbt`, with a `moon.pkg` that imports
what the program says it needs. With `--check`, nothing is written, and the
script fails if a program differs from what curl2mbt writes now.
"""

import os
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "examples")


def generate(cli, path, shell):
    result = subprocess.run(cli + ["--shell", shell, "--file", path], capture_output=True)
    if result.returncode != 0:
        raise SystemExit("curl2mbt rejects %s:\n%s%s" % (path, result.stdout.decode(), result.stderr.decode()))
    program = result.stdout.decode().replace("\r\n", "\n").rstrip("\n") + "\n"
    imports = [line[len("//     "):] for line in program.splitlines() if line.startswith('//     "')]
    package = "import {\n%s\n}\n\npkgtype(kind: \"executable\")\n" % "\n".join("  " + i for i in imports)
    return {"main.mbt": program, "moon.pkg": package}


def main():
    arguments = sys.argv[1:]
    check = arguments[:1] == ["--check"]
    cli = arguments[1:] if check else arguments
    if not cli:
        raise SystemExit(__doc__)
    commands = os.path.join(ROOT, "commands")
    names, stale = [], []
    for entry in sorted(os.listdir(commands)):
        if entry.endswith(".cmd.txt"):
            name, shell = entry[: -len(".cmd.txt")], "cmd"
        elif entry.endswith(".sh"):
            name, shell = entry[: -len(".sh")], "posix"
        else:
            raise SystemExit("not a command: %s" % entry)
        names.append(name)
        files = generate(cli, os.path.join(commands, entry), shell)
        directory = os.path.join(ROOT, name)
        for file, content in files.items():
            path = os.path.join(directory, file)
            try:
                with open(path, encoding="utf-8", newline="") as old:
                    same = old.read() == content
            except FileNotFoundError:
                same = False
            if same:
                continue
            if check:
                stale.append(name + "/" + file)
            else:
                os.makedirs(directory, exist_ok=True)
                with open(path, "w", encoding="utf-8", newline="\n") as new:
                    new.write(content)
    # Programs whose command is gone.
    for entry in sorted(os.listdir(ROOT)):
        if os.path.isdir(os.path.join(ROOT, entry)) and entry not in names + ["commands", "_build", ".mooncakes"]:
            stale.append(entry + "/")
    if stale:
        raise SystemExit("not what curl2mbt writes now: %s; run tools/examples.py" % ", ".join(stale))
    print("%d examples%s" % (len(names), " are up to date" if check else " written"))


main()

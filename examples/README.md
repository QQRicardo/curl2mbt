# Examples

Each directory holds the program that curl2mbt writes for one command in
`commands/`. Nothing here is edited by hand: `tools/examples.py` writes the
programs, and CI checks that they are what curl2mbt writes now and that they
build on native and wasm.

| Program | Command | What it shows |
|---|---|---|
| `github_issues` | `commands/github_issues.sh` | a bearer token read from `GITHUB_TOKEN`, header fields, `-L` |
| `post_json` | `commands/post_json.sh` | `--json`, `-f`, `--retry` |
| `upload_form` | `commands/upload_form.sh` | a multipart form with a file read when the program runs |
| `download_file` | `commands/download_file.sh` | `-o` with `--create-dirs`, `-f` and `-L` |
| `put_file` | `commands/put_file.sh` | `-T`, which also names the file in the URL, and `--url-query` |
| `copied_from_chrome` | `commands/copied_from_chrome.cmd.txt` | a command for cmd.exe, as Chrome copies it, with `%SESSION%` and `--compressed` |

To build and run one:

```text
$ cd examples
$ moon build --target native
$ GITHUB_TOKEN=... moon run --target native github_issues
```

After a change to curl2mbt, write them again from the root of the repository:

```text
$ moon build --target native --release cmd/main
$ python3 tools/examples.py _build/native/release/build/QQRicardo/curl2mbt-cli/main/main.exe
```

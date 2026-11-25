# curl2mbt

Reads a curl command, as API documentation and browsers give them, and says
what HTTP request it makes: as typed MoonBit data and as JSON. If a part of the
command cannot be represented faithfully, the command is rejected, with the
place and the reason. Nothing is sent, and nothing leaves your machine.

It is for MoonBit programs that take requests as curl commands (API testers,
agents, proxies, documentation tools), and for anyone who wants to know what a
curl command really sends.

## Usage

```mbt check
///|
test "read a command" {
  let text =
    #|curl https://api.example.com/v1/items \
    #|  -H "Authorization: Bearer $API_TOKEN" \
    #|  --json '{"name": "apple"}'
  let plan = @curl2mbt.parse(text).plan
  inspect(plan.http_method, content="POST")
  inspect(plan.url.authority(), content="api.example.com")
  // Variables stay references; nothing is expanded.
  assert_eq(plan.headers[0].value.env_names(), ["API_TOKEN"])
  // `--json` also sets two header fields.
  inspect(
    plan.headers.map(header => header.name).join(", "),
    content="Authorization, Content-Type, Accept",
  )
}

///|
test "what cannot be represented" {
  let text = "curl -F file=@a.png https://example.com/{id} | jq ."
  let found = @curl2mbt.parse(text).diagnostics catch {
      CurlError(found) => found
    }
  inspect(
    found.map(item => item.render(source=text)).join("\n"),
    content=(
      #|error[unsupported-option] at 1:6: -F is not supported
      #|error[url-globbing] at 1:21: curl expands {} and [] in a URL into several requests
      #|  help: replace placeholders by values; for literal braces or brackets use -g or percent-encode them
      #|error[shell-syntax] at 1:46: a pipeline is not part of the request
      #|  help: keep only the curl command
    ),
  )
}
```

`parse` reads the text of a command, `parse_argv` a command that has been split
into arguments. Both give a `Parsed`: the `plan`, and warnings and notes about
the command. `RequestPlan::to_json` and `RequestPlan::from_json` keep plans in
JSON. Messages never repeat option values, which may hold passwords.

The command line tool does the same; put `curl2mbt` before the command, or give
it the text:

```text
$ moon run cmd/main -- curl -u user:pass -d a=1 https://example.com/
$ moon run cmd/main -- --text 'curl -H "X-Key: $KEY" https://example.com/'
$ moon run cmd/main -- --file request.sh
```

It prints JSON with the plan and the findings, and exits with 1 if the command
is rejected.

## What is read

| | |
|---|---|
| Shell | POSIX shell and bash words: quotes, `$'...'`, continued lines, comments, and `"$NAME"` or `"${NAME}"` as references to environment variables |
| Method | `-X`, `-I`, `-G` |
| URL | http and https; `--url`, `-g`, `--path-as-is`, user information |
| Header fields | `-H` with all its forms, `-A`, `-e`, `-b` with cookies, `-r` |
| Body | `-d`, `--data-ascii`, `--data-binary`, `--data-raw`, `--data-urlencode`, `--json`, any number of them |
| Authentication | Basic (`-u`), bearer tokens (`--oauth2-bearer`) |
| Kept for the one who sends it | `-L`, `--max-redirs`, `-k`, `-f`, `-m`, `--compressed` |
| Reported as without effect on the request | options about output, progress and connection reuse |

Everything else is rejected: the other options of curl 8.19.0, data from files,
multipart forms, several URLs, variables in URLs, pipelines, redirections and
substitutions, other protocols, header lines that change how the message is
framed, and URLs that clients read differently.

Three things differ from a shell on purpose. An unset variable is an empty string
to a shell; here it stays a reference, and whoever sends the request decides.
Unquoted `*`, `?` and `[` are taken literally, with a warning, since no file
names are known. Two `\u` escapes that are the halves of a surrogate pair, as
Chrome writes them, are read as one character, with a warning.

## How it is checked

- `moon test` on wasm, wasm-gc, js and native.
- `tools/compare.py` runs command lines through the installed curl against a
  local server and compares what arrives with the plan, and runs texts through
  bash and compares the arguments. Listed and random cases; CI runs it with the
  curl and bash of Ubuntu 26.04. Not compared: the User-Agent curl sends by default,
  Host unless the command sets it, and blanks around header values.

TLS, redirects, timeouts and decompression are only recorded in the plan; there
is nothing here that could carry them out yet.

## Status

Implemented: all of the above. Planned: MoonBit code that sends the request,
commands in the syntax of Windows `cmd`, multipart forms and data from files.

## License

Apache-2.0. The list of options in `options_table.mbt` was made from the output
of `curl --help all`; no code of curl or of another converter is used.

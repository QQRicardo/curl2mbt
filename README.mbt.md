# curl2mbt

Turns a curl command, as API documentation and browsers give them, into a
MoonBit program that makes the same HTTP request with
[moonbitlang/async](https://mooncakes.io/docs/moonbitlang/async), or into a
typed description of the request. If a part of the command cannot be reproduced
faithfully, the command is rejected, with the place and the reason. Nothing is
sent, and nothing leaves your machine.

It is for those who call HTTP APIs from MoonBit, and for MoonBit programs that
take requests as curl commands (API testers, agents, proxies, documentation
tools).

```text
$ moon run cmd/main -- --text 'curl https://api.example.com/v1/items \
    -H "Authorization: Bearer $API_TOKEN" --json "{\"name\": \"apple\"}"'
// Needs moonbitlang/async 0.22: moon add moonbitlang/async
// Imports for moon.pkg, with pkgtype(kind: "executable"):
//   import {
//     "moonbitlang/async/io",
//     "moonbitlang/core/env",
//     "moonbitlang/async/http",
//     "moonbitlang/async/stdio",
//     "moonbitlang/core/encoding/utf8",
//   }
// Environment variables: API_TOKEN

///|
/// The value of the environment variable `name`.
fn env(name : String) -> String raise {
  match @env.get_env_var(name) {
    Some(value) => value
    None => fail("the environment variable \{name} is not set")
  }
}

///|
/// POST https://api.example.com/v1/items
async fn send_request() -> (@http.Response, &@io.Data) {
  let env_api_token = env("API_TOKEN")
  let text =
    #|{"name": "apple"}
  let body = @utf8.encode(text)
  let client = @http.Client("https://api.example.com")
  defer client.close()
  client.request(Post, "/v1/items", extra_headers={
    "Authorization": "Bearer \{env_api_token}",
    "Content-Type": "application/json",
    "Accept": "application/json",
    "Content-Length": body.length().to_string(),
  })
  client.write(body)
  let response = client.end_request()
  (response, client.read_all())
}

///|
async fn main {
  let (response, body) = send_request()
  ignore(response)
  @stdio.stdout.write(body)
}
```

## The command line tool

Put `curl2mbt` before the command, or give it the text:

```text
$ moon run cmd/main -- curl -u user:pass -d a=1 https://example.com/
$ moon run cmd/main -- --text 'curl -H "X-Key: $KEY" https://example.com/'
$ moon run cmd/main -- --file request.sh
$ moon run cmd/main -- --shell cmd --file request.txt
$ moon run cmd/main -- --shell cmd --to-curl posix --file request.txt
```

`--shell cmd` is for commands that were copied for the prompt of Windows. The
tool prints a program. With `--plan` it prints the request as JSON instead, and
with `--to-curl posix` or `--to-curl cmd` as a curl command for that shell. It
exits with 1 if the command is rejected, with every reason.

Passwords, tokens and cookies of the command do not go into the program, which
reads them from environment variables instead; comments at its start name them.
What counts are `-u`, `--oauth2-bearer`, `-b` and header fields such as
`Authorization`, `Cookie` and `X-Api-Key`. Secrets in a URL or a body stay where
they are; for some query parameters there is a warning. `--inline-secrets`
writes everything into the program.

## The library

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
test "write a program" {
  let plan = @curl2mbt.parse("curl -u user:pass https://example.com/").plan
  let emitted = plan.emit()
  assert_true(emitted.code.contains("@http.Client(\"https://example.com\")"))
  // The packages to import, and the variables the program reads.
  assert_true(emitted.imports.contains("moonbitlang/async/http"))
  assert_eq(emitted.environment, ["BASIC_AUTH"])
}

///|
test "write the command for another shell" {
  let text = "curl -H \"X-Key: %KEY%\" -d \"a=1&b=2\" https://example.com/"
  let plan = @curl2mbt.parse(text, shell=Cmd).plan
  inspect(
    plan.to_curl(shell=Posix),
    content="curl -H 'X-Key: '\"${KEY}\" --data-raw 'a=1&b=2' https://example.com/",
  )
}

///|
test "what cannot be represented" {
  let text = "curl --digest -u user:pass https://example.com/{id} | jq ."
  let found = @curl2mbt.parse(text).diagnostics catch {
      CurlError(found) => found
    }
  inspect(
    found.map(item => item.render(source=text)).join("\n"),
    content=(
      #|error[unsupported-option] at 1:6: --digest is not supported
      #|error[url-globbing] at 1:28: curl expands {} and [] in a URL into several requests
      #|  help: replace placeholders by values; for literal braces or brackets use -g or percent-encode them
      #|error[shell-syntax] at 1:53: a pipeline is not part of the request
      #|  help: keep only the curl command
    ),
  )
}
```

`parse` reads the text of a command, for a POSIX shell or with `shell=Cmd` for
the prompt of Windows, and `parse_argv` a command that has been split into
arguments. Both give a `Parsed`: the `plan`, and warnings and notes about the
command. `RequestPlan::to_json` and `RequestPlan::from_json` keep plans in
JSON. Messages never repeat option values, which may hold passwords.

`RequestPlan::to_curl` writes the plan as a curl command for a POSIX shell or
cmd. Before it returns the text, it reads the text back and checks that curl
sends the same request; header fields that curl adds on its own may then be
written as options. What no command for the shell can say, such as bytes that
are not UTF-8 for cmd, raises `ToCurlError`.

`RequestPlan::emit` writes the program, or raises `EmitError` with every reason
why moonbitlang/async cannot make the request. The library itself has no
dependency and works on every backend; the programs run on native and wasm.

## What is read

| | |
|---|---|
| Shell | POSIX shell and bash words: quotes, `$'...'`, continued lines, comments, and `"$NAME"` or `"${NAME}"` as references to environment variables |
| Windows cmd | the prompt, not batch files: carets, quotes, continued lines, and `"%NAME%"` as a reference to an environment variable |
| Method | `-X`, `-I`, `-G` |
| URL | http and https; `--url`, `--url-query`, `-g`, `--path-as-is`, user information |
| Header fields | `-H` with all its forms, `-A`, `-e`, `-b` with cookies, `-r` |
| Body | `-d`, `--data-ascii`, `--data-binary`, `--data-raw`, `--data-urlencode`, `--json`, any number of them, also from files with `@` |
| Uploads | `-T` with a file, which becomes the last part of a URL that ends with `/`; with `--path-as-is`, `-T` and `--url-query` are rejected, because curl then normalizes the path anyway |
| Forms | `-F` with text, files (`@`, `<`), `;type=` and `;filename=`; `--form-string` |
| Authentication | Basic (`-u`), bearer tokens (`--oauth2-bearer`) |
| How it is sent | `-L`, `--max-redirs`, `-k`, `-f`, `--fail-with-body`, `-m`, `--compressed` |
| Retries | `--retry`, `--retry-delay`, `--retry-max-time`, `--retry-all-errors`; `--retry-connrefused` only together with `--retry-all-errors` |
| Where the response goes | `-o`, `-O`, `--remote-name-all`, `--output-dir`, `--create-dirs`; the first of `-o` and `-O` counts, and a later one is reported |
| Reported as without effect on the request | options about headers in the output, progress and connection reuse |

Everything else is rejected: the other options of curl 8.19.0, the standard
input, header fields and cookies from files, forms inside forms, several URLs,
variables in URLs and file names, pipelines, redirections and substitutions,
other protocols, header lines that change how the message is framed, and URLs
that clients read differently.

Three things differ from a shell on purpose. An unset variable is an empty string
to a shell; here it stays a reference, and whoever sends the request decides.
Unquoted `*`, `?` and `[` are taken literally, with a warning, since no file
names are known. Two `\u` escapes that are the halves of a surrogate pair, as
Chrome writes them, are read as one character, with a warning.

For cmd, `%NAME%` stays a reference in the same way, and its value is used as it
is, while cmd would give a meaning to quotes and `&` in it. `%C3%A9` is taken for
percent-encoding and not for a variable named `C3`. Characters outside ASCII are
UTF-8, where curl for Windows may use the code page of the system. All of this
comes with a warning where it can matter.

## What programs do

A program writes the body of the response to the standard output, as curl does,
or to the file that `-o` or `-O` names, which it replaces. With `-f` a status of
400 or more ends the program before anything is written; with `--fail-with-body`
after the body is written. `-i` and `-I` do not put the header lines in the file.

With `--retry` it sends the request again after a timeout of `-m`, or after a
status of 408, 429, 500, 502, 503, 504, 522 or 524, as curl does: it waits one
second, twice as long each time, or what `--retry-delay` says, or longer if
`Retry-After` asks for it in seconds; a date there ends the program with an
error. Like curl, it writes the body of each attempt to the standard output, and
only the last one stays in a file. `-m` limits each attempt.
Files that the command names are read when the program runs, relative to where
it runs, and held in memory. The boundary of a form is one that occurs in none of
its parts.

With `-L` it follows redirects as curl does: what becomes of the method and the
body after each status, which header fields are kept, and no credentials for
another host. A redirect it cannot resolve with certainty ends the program with
an error.

Plans that moonbitlang/async 0.22 cannot send as they are get no program:
methods other than GET, HEAD, POST, PUT, DELETE, OPTIONS, TRACE and PATCH,
a header field that occurs twice, `Host`, `Upgrade`, `TE` other than `trailers`,
no User-Agent at all, IPv6 addresses in URLs, and `-L` together with `-b`.

Programs differ from curl in this:

- Unless the command sets them, User-Agent and Accept-Encoding are those of
  moonbitlang/async. It asks for gzip and decompresses it.
- A variable that is not set is an error, where a shell takes an empty string.
- `-I` and `-i` do not print the header fields of the response.
- There is no `Expect: 100-continue`, which curl adds to large bodies.
- Certificates are checked by the TLS library of the system, which may trust
  others than curl does.

## How it is checked

- `moon test` on wasm, wasm-gc, js and native.
- `tools/compare.py` runs command lines through the installed curl against a
  local server and compares what arrives with the plan, and runs texts through
  bash and compares the arguments. Listed and random cases; CI runs it with the
  curl and bash of Ubuntu 26.04. Not compared: the User-Agent curl sends by
  default, Host unless the command sets it, and blanks around header values.
  What `--to-curl posix` writes for each command goes through bash and curl
  again, and the request must be the same.
- `tools/compare_programs.py` builds the programs for a list of commands, runs
  them and curl against local servers, and compares the requests, the output and
  whether the run succeeds. CI does this on native and wasm, on Linux. With TLS
  only `-k` and the rejection of a self-signed certificate are compared, with
  HTTP/1.1 only.
- `tools/compare_cmd.py` gives texts to the prompt of cmd.exe with the curl.exe
  of Windows and compares what arrives with the plan, also for what
  `--to-curl cmd` writes. Listed and random cases of ASCII characters; CI runs
  it on Windows.

## Status

Implemented: all of the above. Not planned: requests that are not HTTP, and batch
files.

## License

Apache-2.0. The list of options in `options_table.mbt` was made from the output
of `curl --help all`; no code of curl or of another converter is used.

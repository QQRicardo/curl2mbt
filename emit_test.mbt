///|
/// The program for a command.
fn program(
  text : String,
  secrets~ : @curl2mbt.Secrets = FromEnv,
) -> @curl2mbt.Emitted raise {
  @curl2mbt.parse(text).plan.emit(secrets~)
}

///|
/// The codes of the reasons why a command that can be read has no program.
fn reasons(text : String) -> String raise {
  let plan = @curl2mbt.parse(text).plan
  let found = plan.emit().diagnostics catch { EmitError(found) => found }
  found.filter(item => item.severity is Error).map(item => item.code).join(" ")
}

///|
/// The lines of a program that contain `part`, without indentation.
fn lines_with(code : String, part : String) -> String {
  code
  .split("\n")
  .filter(line => line.contains(part))
  .map(line => line.trim().to_owned())
  .collect()
  .join("\n")
}

///|
test "the program for a plain request" {
  let emitted = program("curl https://example.com/a?b=c")
  inspect(
    emitted.code,
    content=(
      #|///|
      #|/// GET https://example.com/a
      #|async fn send_request() -> (@http.Response, &@io.Data) {
      #|  let client = @http.Client("https://example.com")
      #|  defer client.close()
      #|  client.request(Get, "/a?b=c", extra_headers={
      #|    "Accept": "*/*",
      #|  })
      #|  let response = client.end_request()
      #|  (response, client.read_all())
      #|}
      #|
      #|///|
      #|async fn main {
      #|  let (response, body) = send_request()
      #|  ignore(response)
      #|  @stdio.stdout.write(body)
      #|}
      #|
    ),
  )
  inspect(
    emitted.imports.join(" "),
    content="moonbitlang/async/io moonbitlang/async/http moonbitlang/async/stdio",
  )
  assert_eq(emitted.environment, [])
  assert_eq(emitted.diagnostics.length(), 0)
}

///|
test "options that act on the response" {
  let code = program("curl -f -k -m 2.5 -X DELETE https://h/").code
  inspect(
    lines_with(code, "response"),
    content=(
      #|let response = client.end_request()
      #|(response, client.read_all())
      #|let (response, body) = @async.with_timeout(2500, send_request)
      #|if response.code >= 400 {
      #|fail("HTTP status \{response.code}")
    ),
  )
  inspect(
    lines_with(code, "@http.Client"),
    content=(
      #|let client = @http.Client("https://h", trust=NoVerification)
    ),
  )
}

///|
test "bodies" {
  inspect(
    lines_with(program("curl h --data-raw a=1").code, "body"),
    content=(
      #|let body = b"a=1"
      #|"Content-Length": body.length().to_string(),
      #|client.write(body)
      #|let (response, body) = send_request()
      #|@stdio.stdout.write(body)
    ),
  )
  let json = program("curl h --json '{\"a\": \"\\n\"}\n'")
  assert_true(
    json.code.contains("  let text =\n    #|{\"a\": \"\\n\"}\n    #|\n"),
  )
  assert_true(json.imports.contains("moonbitlang/core/encoding/utf8"))
  let bytes = program("curl h --data-raw $'\\xff\"\\\\\\x01'")
  inspect(
    lines_with(bytes.code, "let body"),
    content=(
      #|let body = b"\xff\"\\\x01"
    ),
  )
  let mixed = program("curl h --data-raw $'\\xff'\"$A\"")
  inspect(
    lines_with(mixed.code, "let body"),
    content=(
      #|let body = b"\xff" + @utf8.encode(env_a)
    ),
  )
}

///|
/// Characters that an editor does not show, or shows elsewhere, are escaped.
test "text is escaped" {
  let emitted = program("curl h -H $'X: \"\\\\{a}\\t\\u202e\\u00ad\\u00e9'")
  inspect(
    lines_with(emitted.code, "\"X\""),
    content=(
      #|"X": "\"\\{a}\t\u{202e}\u{ad}é",
    ),
  )
  let body = program("curl h --data-raw $'\"\\u202e'")
  inspect(
    lines_with(body.code, "let body"),
    content=(
      #|let body = @utf8.encode("\"\u{202e}")
    ),
  )
}

///|
test "secrets come from the environment" {
  let text = "curl h -H 'Authorization: Bearer s3cret' -H 'X-Api-Key: s3cret' -b 'a=s3cret'"
  let emitted = program(text)
  assert_false(emitted.code.contains("s3cret"))
  assert_eq(emitted.environment, ["COOKIE", "BEARER_TOKEN", "X_API_KEY"])
  assert_true(
    emitted.diagnostics
    .iter()
    .all(item => {
      item.code == "secret-from-environment" &&
      !item.render().contains("s3cret")
    }),
  )
  inspect(
    lines_with(emitted.code, "Bearer"),
    content=(
      #|"Authorization": "Bearer \{env_bearer_token}",
    ),
  )
  let inline = program(text, secrets=Inline)
  assert_eq(inline.environment, [])
  assert_eq(inline.diagnostics.length(), 0)
  inspect(
    lines_with(inline.code, "s3cret"),
    content=(
      #|"Cookie": "a=s3cret",
      #|"Authorization": "Bearer s3cret",
      #|"X-Api-Key": "s3cret",
    ),
  )
}

///|
test "credentials" {
  let basic = program("curl -u user:s3cret h")
  assert_eq(basic.environment, ["BASIC_AUTH"])
  inspect(
    lines_with(basic.code, "Authorization"),
    content=(
      #|"Authorization": "Basic " + @base64.encode(@utf8.encode("\{env_basic_auth}")),
    ),
  )
  inspect(
    lines_with(program("curl -u user:p h", secrets=Inline).code, "Basic"),
    content=(
      #|"Authorization": "Basic " + @base64.encode(b"user:p"),
    ),
  )
}

///|
/// Names of variables of the command and of lifted secrets never coincide.
test "names of variables" {
  let emitted = program(
    "curl h -H \"A: $BEARER_TOKEN $bearer_token\" --oauth2-bearer s3cret",
  )
  assert_eq(emitted.environment, [
    "BEARER_TOKEN_2", "BEARER_TOKEN", "bearer_token",
  ])
  inspect(
    lines_with(emitted.code, "env(\""),
    content=(
      #|let env_bearer_token_2 = env("BEARER_TOKEN_2")
      #|let env_bearer_token = env("BEARER_TOKEN")
      #|let env_bearer_token_3 = env("bearer_token")
    ),
  )
}

///|
test "secrets in URLs are reported" {
  let emitted = program("curl 'https://h/?x=1&Access_Token=s3cret'")
  inspect(
    emitted.diagnostics.map(item => item.render()).join("\n"),
    content="warning[secret-in-url]: the query parameter access_token may be a secret, and the program holds the whole URL",
  )
}

///|
test "redirects" {
  let code = program("curl -L -u u:p -d a=1 --max-redirs 3 http://h/").code
  assert_true(code.contains("fn redirect_target("))
  inspect(
    lines_with(code, "redirects"),
    content=(
      #|for redirects = 0; ; redirects = redirects + 1 {
      #|if redirects == 3 {
      #|fail("more than 3 redirects")
    ),
  )
  inspect(
    lines_with(code, "headers["),
    content=(
      #|headers["Authorization"] = "Basic " + @base64.encode(@utf8.encode("\{env_basic_auth}"))
      #|headers["Content-Type"] = "application/x-www-form-urlencoded"
      #|headers["Content-Length"] = body.length().to_string()
    ),
  )
  inspect(
    lines_with(code, "meth"),
    content=(
      #|let meth : @http.RequestMethod = if with_body { Post } else { Get }
      #|client.request(meth, path, extra_headers=headers)
    ),
  )
  // With -X the method stays.
  inspect(
    lines_with(program("curl -L -X PUT -d a h").code, "client.request"),
    content="client.request(Put, path, extra_headers=headers)",
  )
}

///|
test "ranges are of the data as it is" {
  inspect(
    lines_with(program("curl -r 0-9 h").code, "Encoding"),
    content=(
      #|"Accept-Encoding": "identity",
    ),
  )
}

///|
test "requests the library cannot make" {
  for
    entry in [
      ("curl -X PURGE h", "unsupported-method"),
      ("curl -X get h", "unsupported-method"),
      ("curl -A '' h", "unsupported-header"),
      ("curl -H 'A: 1' -H 'a: 2' h", "duplicate-header"),
      ("curl -H 'Host: x' h", "unsupported-header"),
      ("curl -H 'TE: gzip' h", "unsupported-header"),
      ("curl -H 'Upgrade: h2c' h", "unsupported-header"),
      ("curl -L -b a=b h", "unsupported-redirects"),
      ("curl 'http://[::1]/'", "unsupported-host"),
      // Every reason is given.
      ("curl -X PURGE -A '' h", "unsupported-method unsupported-header"),
      ("curl -H 'TE: trailers' h", ""),
      ("curl -b a=b h", ""),
    ] {
    assert_eq(reasons(entry.0), entry.1)
  }
}

///|
test "programs do not depend on anything but the plan" {
  let text = "curl -L -u u:p -H 'X-Api-Key: k' --data-raw \"$A$B\" http://h/?a=1"
  let parsed = @curl2mbt.parse(text).plan
  let restored = @curl2mbt.RequestPlan::from_json(parsed.to_json())
  assert_eq(parsed.emit().code, restored.emit().code)
  assert_eq(parsed.emit().imports, restored.emit().imports)
}

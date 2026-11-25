///|
fn no_file(_path : String) -> String raise {
  fail("no such file")
}

///|
test "accepted commands" {
  let outcome = run(["--plan", "curl", "-s", "http://h/"], no_file)
  assert_eq(outcome.status, 0)
  let json = @json.parse(outcome.output)
  guard json
    is {
      "plan": plan,
      "diagnostics": [{ "code": String(code), "argument": Number(1, ..), .. }],
      ..
    } else {
    fail("unexpected output")
  }
  inspect(code, content="no-effect-on-request")
  assert_eq(@curl2mbt.RequestPlan::from_json(plan).url.to_string(), "http://h/")
}

///|
test "text and files" {
  let text = "curl http://h/ -d \"$A\" -v"
  inspect(
    run(["--text", text], no_file).output.split("\n").collect()[0],
    content="error[variable-may-name-file] at 1:19: curl reads a file if the variable starts with @",
  )
  fn read(path : String) -> String raise {
    if path == "f" {
      "\u{FEFF}curl http://h/ -v"
    } else {
      fail("no such file")
    }
  }

  let outcome = run(["--plan", "--file", "f"], read)
  assert_eq(outcome.status, 0)
  // Offsets do not count the byte order mark.
  assert_true(outcome.output.contains("\"start\": 15"))
  assert_eq(run(["--file", "g"], read).status, 2)
}

///|
test "programs" {
  let outcome = run(["curl", "-s", "-u", "u:s3cret", "https://h/"], no_file)
  assert_eq(outcome.status, 0)
  assert_false(outcome.output.contains("s3cret"))
  let lines = outcome.output.split("\n").map(line => line.to_owned())
  inspect(
    lines.filter(line => line.has_prefix("//") && line != "///|").collect()[:]
    .iter()
    .take(13)
    .join("\n"),
    content=(
      #|// Needs moonbitlang/async 0.22: moon add moonbitlang/async
      #|// Imports for moon.pkg, with pkgtype(kind: "executable"):
      #|//   import {
      #|//     "moonbitlang/async/io",
      #|//     "moonbitlang/core/env",
      #|//     "moonbitlang/async/http",
      #|//     "moonbitlang/async/stdio",
      #|//     "moonbitlang/core/encoding/utf8",
      #|//     "moonbitlang/core/encoding/base64",
      #|//   }
      #|// Environment variables: BASIC_AUTH
      #|//
      #|// note[no-effect-on-request] at argument 1: -s only changes what curl reports
    ),
  )
  let inline = run(
    ["--inline-secrets", "curl", "-u", "u:s3cret", "https://h/"],
    no_file,
  )
  assert_true(inline.output.contains("s3cret"))
  // The plan has a method the library does not have.
  let refused = ["curl", "-X", "PURGE", "https://h/"]
  let outcome = run(refused, no_file)
  assert_eq(outcome.status, 1)
  assert_true(outcome.output.has_prefix("error[unsupported-method]: "))
  assert_eq(run(["--plan", ..refused], no_file).status, 0)
}

///|
test "texts for cmd" {
  let text = "curl ^\"http://h/?a=1^&b=2^\" ^\n  -d ^\"x^\""
  let outcome = run(["--plan", "--shell", "cmd", "--text", text], no_file)
  assert_eq(outcome.status, 0)
  assert_true(outcome.output.contains("http://h/?a=1&b=2"))
  assert_eq(run(["--shell", "posix", "--text", text], no_file).status, 1)
}

///|
test "wrong arguments" {
  for
    arguments in [
      [],
      ["--text"],
      ["--text", "a", "b"],
      ["--file"],
      ["--json", "curl"],
      ["--plan"],
      ["--shell"],
      ["--shell", "fish", "--text", "curl h"],
      ["--shell", "cmd", "curl", "h"],
    ] {
    let outcome = run(arguments, no_file)
    assert_eq(outcome.status, 2)
    assert_true(outcome.output.has_prefix("error: "))
  }
  assert_eq(run(["--help"], no_file).status, 0)
  assert_eq(run(["wget", "x"], no_file).status, 1)
}

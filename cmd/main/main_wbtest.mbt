///|
fn no_file(_path : String) -> String raise {
  fail("no such file")
}

///|
test "accepted commands" {
  let outcome = run(["curl", "-s", "http://h/"], no_file)
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

  let outcome = run(["--file", "f"], read)
  assert_eq(outcome.status, 0)
  // Offsets do not count the byte order mark.
  assert_true(outcome.output.contains("\"start\": 15"))
  assert_eq(run(["--file", "g"], read).status, 2)
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
    ] {
    let outcome = run(arguments, no_file)
    assert_eq(outcome.status, 2)
    assert_true(outcome.output.has_prefix("error: "))
  }
  assert_eq(run(["--help"], no_file).status, 0)
  assert_eq(run(["wget", "x"], no_file).status, 1)
}

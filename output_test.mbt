///|
/// Where the plan of a command line puts the response, and how it fails.
fn output_plan(arguments : Array[String]) -> String raise {
  let words = ["curl"]
  words.append(arguments)
  let plan = @curl2mbt.parse_argv(words).plan
  let file = plan.output_file.unwrap_or("stdout")
  let dirs = if plan.create_dirs { " dirs" } else { "" }
  let fail = if plan.fail_with_body {
    " fail-with-body"
  } else if plan.fail_on_error {
    " fail"
  } else {
    ""
  }
  "\{file}\{dirs}\{fail}"
}

///|
test "output files" {
  for
    entry in [
      (["http://h/x"], "stdout"),
      (["-o", "out", "http://h/x"], "out"),
      (["-o", "-", "http://h/x"], "stdout"),
      (["-O", "http://h/x/a%20b.txt?q=1#f"], "a%20b.txt"),
      (["-O", "http://h/x/"], "x"),
      (["-O", "http://h/x/."], "x"),
      (["-O", "http://h/"], "curl_response"),
      (["-O", "http://h/x/%2e%2e"], "curl_response"),
      (["--remote-name-all", "http://h/y"], "y"),
      (["-O", "--no-remote-name", "http://h/y"], "y"),
      (["--remote-name-all", "--no-remote-name", "http://h/y"], "stdout"),
      (["--remote-name-all", "-o", "x", "http://h/y"], "x"),
      (["--remote-name-all", "-o", "-", "http://h/y"], "stdout"),
      (["--output-dir", "d", "-O", "http://h/y"], "d/y"),
      (["--output-dir", "d", "-o", "-", "http://h/y"], "stdout"),
      (["--create-dirs", "-o", "a/b", "http://h/"], "a/b dirs"),
      (["--create-dirs", "http://h/"], "stdout"),
      (["-f", "-o", "o", "http://h/"], "o fail"),
      (["--fail-with-body", "http://h/"], "stdout fail-with-body"),
      (["-f", "--fail-with-body", "http://h/"], "stdout fail-with-body"),
      (["-O", "-o", "b", "http://h/a"], "a"),
      (["-T", "f", "-O", "http://h/u/"], "f"),
    ] {
    assert_eq(output_plan(entry.0), entry.1)
  }
}

///|
test "a second output is reported" {
  let result = @curl2mbt.parse_argv(["curl", "-o", "a", "-o", "b", "http://h/"])
  assert_eq(result.plan.output_file, Some("a"))
  assert_true(result.diagnostics.iter().any(d => d.code == "ignored-output"))
}

///|
test "outputs that are rejected" {
  for
    arguments in [
      ["-o", ""],
      ["--output-dir", ""],
      ["-J", "-O"],
      ["--no-clobber", "-o", "f"],
      ["--remove-on-error", "-o", "f"],
    ] {
    let words = ["curl", "http://h/"]
    words.append(arguments)
    assert_true(
      try @curl2mbt.parse_argv(words) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
  assert_true(
    try
      @curl2mbt.parse("curl --create-dirs -o \"a\\b\" http://h/", shell=Cmd)
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
test "the program for an output file" {
  let code = @curl2mbt.parse("curl -f --create-dirs -o d/e/out http://h/").plan.emit().code
  let check = code.find("  if response.code >= 400 {").unwrap()
  let mkdir = code
    .find("  @fs.mkdir(\"d/e\", recursive=true, allow_exist=true)\n")
    .unwrap()
  let write = code
    .find("  @fs.write_file(\"d/e/out\", body, create_mode=CreateOrTruncate)\n")
    .unwrap()
  assert_true(check < mkdir && mkdir < write)
  assert_false(code.contains("@stdio.stdout.write(body)"))
  // --fail-with-body writes first.
  let code = @curl2mbt.parse("curl --fail-with-body http://h/").plan.emit().code
  assert_true(
    code.find("@stdio.stdout.write(body)").unwrap() <
    code.find("  if response.code >= 400 {").unwrap(),
  )
}

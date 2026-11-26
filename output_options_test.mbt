///|
/// The plan of a command line.
fn options_plan(arguments : Array[String]) -> @curl2mbt.Parsed raise {
  let words = ["curl"]
  words.append(arguments)
  words.push("http://h/")
  @curl2mbt.parse_argv(words)
}

///|
test "--no-clobber and --remove-on-error" {
  let plan = options_plan(["--no-clobber", "--remove-on-error", "-o", "f"]).plan
  assert_true(plan.no_clobber)
  assert_true(plan.remove_on_error)
  assert_eq(
    plan.to_curl(),
    "curl -o f --no-clobber --remove-on-error http://h/",
  )
  // --clobber and --no-remove-on-error turn them off.
  let plan = options_plan([
      "--no-clobber", "--clobber", "--remove-on-error", "--no-remove-on-error", "-o",
      "f",
    ]).plan
  assert_false(plan.no_clobber)
  assert_false(plan.remove_on_error)
  // Without a file they change nothing.
  let parsed = options_plan(["--no-clobber", "--remove-on-error"])
  assert_false(parsed.plan.no_clobber)
  assert_eq(parsed.diagnostics.map(d => d.code), ["no-effect", "no-effect"])
}

///|
test "--max-filesize" {
  let size = (text : String) => {
    options_plan(["--max-filesize", text]).plan.max_filesize
  }
  assert_eq(size("10"), Some(10L))
  assert_eq(size("099"), Some(99L))
  assert_eq(size("50b"), Some(50L))
  assert_eq(size("1k"), Some(1024L))
  assert_eq(size("2M"), Some(2L * 1024 * 1024))
  assert_eq(size("1g"), Some(1024L * 1024 * 1024))
  // Up to 2^53 bytes, which a JSON number holds exactly.
  assert_eq(size("8P"), Some(8L * 1024 * 1024 * 1024 * 1024 * 1024))
  // 0 is no limit.
  assert_eq(size("0"), None)
  assert_eq(size("0k"), None)
  assert_eq(
    options_plan(["--max-filesize", "1k"]).plan.to_curl(),
    "curl --max-filesize 1024 http://h/",
  )
}

///|
test "output options in plans" {
  let plan = options_plan([
      "--no-clobber", "--remove-on-error", "--max-filesize", "3m", "-o", "f",
    ]).plan
  assert_eq(@curl2mbt.RequestPlan::from_json(plan.to_json()), plan)
  let bad : Array[(String, Json)] = [
    ("max_filesize", 0),
    ("max_filesize", 1.5),
    ("max_filesize", 18014398509481984.0),
    ("max_filesize", "1"),
  ]
  for entry in bad {
    let json = plan.to_json()
    guard json is Object(fields) else { fail("not an object") }
    fields[entry.0] = entry.1
    assert_true(
      try @curl2mbt.RequestPlan::from_json(json) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
  // Both flags need a file.
  for name in ["no_clobber", "remove_on_error"] {
    let json = options_plan([]).plan.to_json()
    guard json is Object(fields) else { fail("not an object") }
    fields[name] = true
    assert_true(
      try @curl2mbt.RequestPlan::from_json(json) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "the program for output options" {
  let code = @curl2mbt.parse(
      "curl --no-clobber --remove-on-error --fail-with-body -o out http://h/",
    ).plan.emit().code
  assert_true(code.contains("async fn write_new_file(path : String"))
  assert_true(code.contains("  let written = write_new_file(\"out\", body)\n"))
  assert_true(code.contains("    @fs.remove(written)\n"))
  let code = @curl2mbt.parse("curl --no-clobber -o out http://h/").plan.emit().code
  assert_true(code.contains("  ignore(write_new_file(\"out\", body))\n"))
  let code = @curl2mbt.parse(
      "curl --remove-on-error --fail-with-body -o out http://h/",
    ).plan.emit().code
  assert_true(code.contains("    @fs.remove(\"out\")\n"))
  assert_false(code.contains("write_new_file"))
  let code = @curl2mbt.parse("curl --max-filesize 1k http://h/").plan.emit().code
  assert_true(code.contains("  if too_large(response, body, 1024L) {\n"))
  assert_false(code.contains("ignore(response)"))
}

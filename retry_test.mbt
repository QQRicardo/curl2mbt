///|
/// The retries of the plan of a command line.
fn retry_plan(arguments : Array[String]) -> String raise {
  let words = ["curl"]
  words.append(arguments)
  words.push("http://h/")
  match @curl2mbt.parse_argv(words).plan.retry {
    None => "none"
    Some(retry) => {
      let { count, delay_ms, max_time_ms, all_errors, } = retry
      let ms = (value : Int32?) => {
        match value {
          Some(ms) => ms.to_string()
          None => "-"
        }
      }
      "\{count} \{ms(delay_ms)} \{ms(max_time_ms)} \{all_errors}"
    }
  }
}

///|
test "retries" {
  assert_eq(retry_plan([]), "none")
  assert_eq(retry_plan(["--retry", "0"]), "none")
  assert_eq(retry_plan(["--retry", "3"]), "3 - - false")
  assert_eq(
    retry_plan([
      "--retry", "2", "--retry-delay", "1.5", "--retry-max-time", "60", "--retry-all-errors",
    ]),
    "2 1500 60000 true",
  )
  // 0 is the default, and the last value counts.
  assert_eq(
    retry_plan(["--retry-delay", "2", "--retry", "1", "--retry-delay", "0"]),
    "1 - - false",
  )
  assert_eq(
    retry_plan(["--retry", "1", "--retry-connrefused", "--retry-all-errors"]),
    "1 - - true",
  )
}

///|
test "retry options without --retry are reported" {
  let result = @curl2mbt.parse_argv(["curl", "--retry-delay", "1", "http://h/"])
  assert_eq(result.plan.retry, None)
  assert_true(result.diagnostics.iter().any(d => d.code == "no-effect"))
}

///|
test "retries that are rejected" {
  for
    arguments in [
      ["--retry", "x"],
      ["--retry", "1.5"],
      ["--retry", "1234567"],
      ["--retry-delay", "1.5x"],
      ["--retry-max-time", "-1"],
      ["--retry", "1", "--retry-connrefused"],
    ] {
    assert_true(
      try retry_plan(arguments) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "the program for retries" {
  let code = @curl2mbt.parse("curl --retry 2 -m 3 -f http://h/").plan.emit().code
  assert_true(
    code.contains(
      "  let (response, body) = send_with_retries(Retries::{ left: 2, pause: 1000 })\n",
    ),
  )
  assert_true(
    code.contains(
      "  let (response, body) = @async.with_timeout(3000, send_request) catch {\n    @async.TimeoutError if retries.next(None) is Some(pause) => {\n",
    ),
  )
  // The pause doubles.
  assert_true(code.contains("self.pause * 2"))
  // -f writes nothing before a retry.
  let retried = code.find("  if response.code is (408").unwrap()
  assert_false(
    code[retried:]
    .to_owned()
    .contains("@stdio.stdout.write(body)\n    @async.sleep"),
  )
  let code = @curl2mbt.parse(
      "curl --retry 1 --retry-delay 2 --retry-max-time 5 --retry-all-errors -f http://h/",
    ).plan.emit().code
  assert_true(code.contains("start: @env.now()"))
  assert_true(
    code.contains("    _ if retries.next(None) is Some(pause) => {\n"),
  )
  assert_true(code.contains("|| response.code >= 400) &&"))
  assert_false(code.contains("self.pause * 2"))
}

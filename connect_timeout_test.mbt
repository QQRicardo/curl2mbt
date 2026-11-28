///|
test "--connect-timeout" {
  let timeout = (text : String) => {
    @curl2mbt.parse_argv(["curl", "--connect-timeout", text, "http://h/"]).plan.connect_timeout_ms
  }
  assert_eq(timeout("2"), Some(2000))
  assert_eq(timeout("0.25"), Some(250))
  assert_eq(timeout("1.5"), Some(1500))
  // 0 is the limit of curl, which programs do not have.
  assert_eq(timeout("0"), None)
  for text in ["-1", "1.2345", "1e3", "", "1000000"] {
    let rejected = try
      @curl2mbt.parse_argv(["curl", "--connect-timeout", text, "http://h/"])
      |> ignore
    catch {
      _ => true
    } noraise {
      _ => false
    }
    assert_true(rejected, msg=text)
  }
  let plan = @curl2mbt.parse("curl --connect-timeout 1.5 http://h/").plan
  assert_eq(plan.to_curl(), "curl --connect-timeout 1.5 http://h/")
  assert_eq(@curl2mbt.RequestPlan::from_json(plan.to_json()), plan)
  guard plan.to_json() is Object(fields) else { fail("not an object") }
  fields["connect_timeout_ms"] = 0
  assert_true(
    try @curl2mbt.RequestPlan::from_json(Json::object(fields)) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
test "the program for --connect-timeout" {
  let code = @curl2mbt.parse("curl --connect-timeout 2 http://h/").plan.emit().code
  assert_true(
    code.contains(
      "  let client = @async.with_timeout(2000, () => @http.Client(\"http://h\"))\n",
    ),
  )
  // Each connection that a redirect makes has its own limit.
  let code = @curl2mbt.parse("curl -L --connect-timeout 2 http://h/").plan.emit().code
  assert_true(
    code.contains(
      "    let client = @async.with_timeout(2000, () => @http.Client(origin))\n",
    ),
  )
  // With a proxy, the CONNECT counts in.
  let code = @curl2mbt.parse(
      "curl -x http://p:3128 --connect-timeout 2 https://h/",
    ).plan.emit().code
  assert_true(
    code.contains(
      "  let client = @async.with_timeout(2000, () => {\n    let proxy = @http.Client(\"http://p:3128\")\n    @http.Client(\"https://h\", proxy~)\n  })\n",
    ),
  )
  // --retry sends the request again after the timeout.
  let code = @curl2mbt.parse("curl --retry 2 --connect-timeout 2 http://h/").plan.emit().code
  assert_true(code.contains("    @async.TimeoutError if retries.next(None)"))
}

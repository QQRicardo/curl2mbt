///|
test "--request-target" {
  let parsed = @curl2mbt.parse("curl -X OPTIONS --request-target '*' http://h/")
  assert_eq(parsed.plan.request_target, Some("*"))
  // The path and query of the URL stay in the plan, for -w.
  assert_eq(parsed.plan.url.to_string(), "http://h/")
  assert_eq(parsed.diagnostics.map(d => d.code), ["replaced-target"])
  assert_eq(
    parsed.plan.to_curl(),
    "curl -X OPTIONS --request-target '*' http://h/",
  )
  assert_eq(
    @curl2mbt.RequestPlan::from_json(parsed.plan.to_json()),
    parsed.plan,
  )
  // The same target as the URL is no news.
  let parsed = @curl2mbt.parse("curl --request-target '/a?b' 'http://h/a?b'")
  assert_eq(parsed.diagnostics, [])
  // curl sends blanks and other characters as they are.
  for target in ["", "/a b", "/\u{e9}", "/a\tb"] {
    let rejected = try
      @curl2mbt.parse_argv(["curl", "--request-target", target, "http://h/"])
      |> ignore
    catch {
      _ => true
    } noraise {
      _ => false
    }
    assert_true(rejected, msg=target)
  }
  guard parsed.plan.to_json() is Object(fields) else { fail("not an object") }
  fields["request_target"] = "/a b"
  assert_true(
    try @curl2mbt.RequestPlan::from_json(Json::object(fields)) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
test "the program for --request-target" {
  let code = @curl2mbt.parse("curl --request-target '/x?y=1' 'http://h/a?b'").plan.emit().code
  assert_true(code.contains("client.request(Get, \"/x?y=1\", extra_headers="))
  // The query that -G makes is not sent either, as in curl.
  let code = @curl2mbt.parse("curl -G -d a=1 --request-target /x http://h/").plan.emit().code
  assert_true(code.contains("client.request(Get, \"/x\", extra_headers="))
  // After a redirect curl sends the same target.
  let code = @curl2mbt.parse("curl -L --request-target /x http://h/").plan.emit().code
  assert_true(
    code.contains("    client.request(Get, \"/x\", extra_headers=headers)\n"),
  )
}

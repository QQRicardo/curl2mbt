///|
/// The plan of a command line, with its diagnostics.
fn redirect_parse(arguments : Array[String]) -> @curl2mbt.Parsed raise {
  let words = ["curl"]
  words.append(arguments)
  words.push("http://h/")
  @curl2mbt.parse_argv(words)
}

///|
test "--location-trusted" {
  let plan = redirect_parse(["--location-trusted", "-u", "a:b"]).plan
  // It turns -L on too.
  assert_true(plan.follow_redirects)
  assert_true(plan.location_trusted)
  assert_eq(plan.to_curl(), "curl -u a:b --location-trusted http://h/")
  // And off.
  let plan = redirect_parse([
      "-L", "--location-trusted", "--no-location-trusted",
    ]).plan
  assert_false(plan.follow_redirects)
  assert_false(plan.location_trusted)
  let plan = redirect_parse(["--location-trusted", "--no-location"]).plan
  assert_false(plan.follow_redirects)
  assert_false(plan.location_trusted)
  assert_false(redirect_parse(["-L"]).plan.location_trusted)
}

///|
test "--post301, --post302 and --post303" {
  let plan = redirect_parse([
      "-L", "--post303", "--post301", "--post302", "--no-post302", "-d", "x",
    ]).plan
  assert_eq(plan.keep_post, [301, 303])
  assert_eq(
    plan.to_curl(),
    "curl --data-raw x -L --post301 --post303 http://h/",
  )
  // Without -L, they change nothing.
  let parsed = redirect_parse(["--post301", "-d", "x"])
  assert_eq(parsed.plan.keep_post, [])
  assert_eq(parsed.diagnostics.map(d => d.code), ["no-effect"])
}

///|
test "redirect options in plans" {
  let plan = redirect_parse(["--location-trusted", "--post302", "-d", "x"]).plan
  assert_eq(@curl2mbt.RequestPlan::from_json(plan.to_json()), plan)
  let bad : Array[(String, Json)] = [
    ("keep_post", [302, 301]),
    ("keep_post", [304]),
    ("keep_post", []),
    ("keep_post", "301"),
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
  // Each needs follow_redirects.
  for name in ["location_trusted", "keep_post"] {
    let json = @curl2mbt.parse("curl --location-trusted --post301 http://h/").plan.to_json()
    guard json is Object(fields) else { fail("not an object") }
    fields.remove("follow_redirects")
    fields.remove(
      if name == "keep_post" {
        "location_trusted"
      } else {
        "keep_post"
      },
    )
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
test "the program for redirect options" {
  let code = @curl2mbt.parse("curl -L -u a:b -H 'Cookie: c=1' http://h/").plan.emit(
      secrets=Inline,
    ).code
  assert_true(code.contains("    if origin == first {\n"))
  // With --location-trusted the credentials go to every host.
  let code = @curl2mbt.parse(
      "curl --location-trusted -u a:b -H 'Cookie: c=1' http://h/",
    ).plan.emit(secrets=Inline).code
  assert_false(code.contains("origin == first {"))
  assert_true(code.contains("      \"Cookie\": \"c=1\",\n"))
  // The body stays after the codes of --post30x.
  let code = @curl2mbt.parse("curl -L --post302 -d x http://h/").plan.emit().code
  assert_true(code.contains("    if response.code is (301 | 303) {\n"))
  let code = @curl2mbt.parse(
      "curl -L --post301 --post302 --post303 -d x http://h/",
    ).plan.emit().code
  assert_true(code.contains("  let with_body = true\n"))
  assert_false(code.contains("with_body = false"))
  // An upload is not a POST.
  let code = @curl2mbt.parse("curl -L --post303 -T f http://h/").plan.emit().code
  assert_true(code.contains("    if response.code is (303) {\n"))
}

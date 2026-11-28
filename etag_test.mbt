///|
test "--etag-compare and --etag-save" {
  let parsed = @curl2mbt.parse(
    "curl --etag-compare tag --etag-save tag http://h/",
  )
  assert_eq(parsed.plan.etag_compare, Some("tag"))
  assert_eq(parsed.plan.etag_save, Some("tag"))
  assert_eq(parsed.diagnostics, [])
  assert_eq(
    parsed.plan.to_curl(),
    "curl --etag-compare tag --etag-save tag http://h/",
  )
  assert_eq(
    @curl2mbt.RequestPlan::from_json(parsed.plan.to_json()),
    parsed.plan,
  )
  // --create-dirs counts for the file of --etag-save too.
  let plan = @curl2mbt.parse("curl --create-dirs --etag-save d/e http://h/").plan
  assert_true(plan.create_dirs)
  assert_eq(@curl2mbt.RequestPlan::from_json(plan.to_json()), plan)
  let rejected = (text : String) => {
    try @curl2mbt.parse(text) catch {
      @curl2mbt.CurlError(diagnostics) => diagnostics.map(d => d.code)
    } noraise {
      _ => []
    }
  }
  assert_eq(rejected("curl --etag-save - http://h/"), ["unsupported-value"])
  assert_eq(rejected("curl --etag-save '' http://h/"), ["unsupported-value"])
  assert_eq(rejected("curl --etag-compare '' http://h/"), ["unsupported-value"])
  assert_eq(rejected("curl --etag-compare t -H 'If-None-Match: x' http://h/"), [
    "duplicate-header",
  ])
  for entry in [("etag_save", "-"), ("etag_compare", "")] {
    guard parsed.plan.to_json() is Object(fields) else { fail("not an object") }
    fields[entry.0] = Json::string(entry.1)
    assert_true(
      try @curl2mbt.RequestPlan::from_json(Json::object(fields)) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "the program for --etag-compare and --etag-save" {
  let code = @curl2mbt.parse(
      "curl --etag-compare tag --etag-save new http://h/",
    ).plan.emit().code
  assert_true(
    code.contains("async fn etag_to_compare(path : String) -> String? {"),
  )
  assert_true(code.contains("  let if_none_match = etag_to_compare(\"tag\")\n"))
  assert_true(
    code.contains(
      "  if if_none_match is Some(value) {\n    headers[\"If-None-Match\"] = value\n  }\n",
    ),
  )
  assert_true(code.contains("  save_etag(response, \"new\")\n"))
  assert_true(
    code.contains(
      "  @fs.write_file(\"new\", \"\", create_mode=OpenOrCreate, append=true)\n  let (response, body) = send_request()\n",
    ),
  )
  // After each redirect too.
  let code = @curl2mbt.parse("curl -L --etag-save new http://h/").plan.emit().code
  assert_true(
    code.contains(
      "    let response = client.end_request()\n    save_etag(response, \"new\")\n",
    ),
  )
  assert_false(code.contains("etag_to_compare"))
  let code = @curl2mbt.parse("curl --create-dirs --etag-save d/e http://h/").plan.emit().code
  assert_true(
    code.contains("  @fs.mkdir(\"d\", recursive=true, allow_exist=true)\n"),
  )
}

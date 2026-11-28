///|
test "dates as curl reads them" {
  let date = (text : String) => {
    @curl2mbt.parse_curl_date(text).map(@curl2mbt.http_date)
  }
  // What curl 8.22 sends for these.
  let cases = [
    ("Sun, 06 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 08:49:37 GMT"),
    ("6 Nov 1994", "Sun, 06 Nov 1994 00:00:00 GMT"),
    ("Nov 6 1994 08:49", "Sun, 06 Nov 1994 08:49:00 GMT"),
    ("19941106", "Sun, 06 Nov 1994 00:00:00 GMT"),
    ("Sun Nov  6 08:49:37 1994", "Sun, 06 Nov 1994 08:49:37 GMT"),
    ("06 Nov 1994 08:49:37 +0100", "Sun, 06 Nov 1994 07:49:37 GMT"),
    ("06 Nov 1994 08:49:37 PST", "Sun, 06 Nov 1994 16:49:37 GMT"),
    ("06 Nov 94", "Sun, 06 Nov 1994 00:00:00 GMT"),
    ("1 Jan 1970 00:00:00", "Thu, 01 Jan 1970 00:00:00 GMT"),
    ("31 Feb 2020", "Mon, 02 Mar 2020 00:00:00 GMT"),
    ("Sunday, 06-Nov-94 08:49:37 GMT", "Sun, 06 Nov 1994 08:49:37 GMT"),
    ("29 Feb 2000 23:59:59", "Tue, 29 Feb 2000 23:59:59 GMT"),
    ("31 Dec 9999 23:59:59", "Fri, 31 Dec 9999 23:59:59 GMT"),
  ]
  for entry in cases {
    assert_eq(date(entry.0), Some(entry.1), msg=entry.0)
  }
  // Not dates to curl, which then takes them for names of files.
  for
    text in [
      "1994-11-06", "1 Jan 1500", "stamp", "Nov", "12:00", "6 November 1994", "6 Nov 1994 25:00",
      "",
    ] {
    assert_eq(date(text), None, msg=text)
  }
}

///|
test "-z" {
  // The field and the time, or the file, as text.
  let describe = (condition : @curl2mbt.TimeCondition?) => {
    match condition {
      Some({ field, time: At(time), }) => "\{field} \{time}"
      Some({ field, time: FileTime(path), }) => "\{field} file \{path}"
      None => "none"
    }
  }
  let parsed = @curl2mbt.parse("curl -z '1 Jan 2000' http://h/")
  assert_eq(describe(parsed.plan.time_condition), "If-Modified-Since 946684800")
  assert_eq(parsed.diagnostics, [])
  assert_eq(
    parsed.plan.to_curl(),
    "curl -z 'Sat, 01 Jan 2000 00:00:00 GMT' http://h/",
  )
  assert_eq(
    @curl2mbt.RequestPlan::from_json(parsed.plan.to_json()),
    parsed.plan,
  )
  let condition = (text : String) => {
    describe(
      @curl2mbt.parse_argv(["curl", "-z", text, "http://h/"]).plan.time_condition,
    )
  }
  assert_eq(condition("-1 Jan 2000"), "If-Unmodified-Since 946684800")
  assert_eq(condition("=1 Jan 2000"), "Last-Modified 946684800")
  assert_eq(condition("+stamp"), "If-Modified-Since file stamp")
  let parsed = @curl2mbt.parse("curl -z -stamp http://h/")
  assert_eq(
    describe(parsed.plan.time_condition),
    "If-Unmodified-Since file stamp",
  )
  assert_eq(parsed.diagnostics.map(d => d.code), ["time-from-file"])
  assert_eq(parsed.plan.to_curl(), "curl -z -stamp http://h/")
  assert_eq(
    @curl2mbt.RequestPlan::from_json(parsed.plan.to_json()),
    parsed.plan,
  )
  let rejected = (arguments : Array[String]) => {
    try @curl2mbt.parse_argv(["curl", ..arguments, "http://h/"]) catch {
      @curl2mbt.CurlError(diagnostics) => diagnostics.map(d => d.code)
    } noraise {
      _ => []
    }
  }
  // curl fails with dates before 1970.
  assert_eq(rejected(["-z", "1 Jan 1969"]), ["unsupported-value"])
  assert_eq(rejected(["-z", ""]), ["unsupported-value"])
  assert_eq(rejected(["-z", "1 Jan 2000", "-H", "If-Modified-Since: x"]), [
    "conflicting-options",
  ])
  assert_eq(rejected(["-z", "1 Jan 2000", "-r", "0-1"]), ["conflicting-options"])
  guard parsed.plan.to_json() is Object(fields) else { fail("not an object") }
  let bad_conditions : Array[Json] = [
    { "field": "Date", "file": "stamp" },
    { "field": "If-Modified-Since", "file": "1 Jan 2000" },
    { "field": "If-Modified-Since", "time": -1 },
    { "field": "If-Modified-Since", "time": 1, "file": "x" },
  ]
  for bad in bad_conditions {
    fields["time_condition"] = bad
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
test "the program for -z" {
  let code = @curl2mbt.parse("curl -z '1 Jan 2000' -w '%{http_code}' http://h/").plan.emit().code
  assert_true(
    code.contains("\"If-Modified-Since\": \"Sat, 01 Jan 2000 00:00:00 GMT\","),
  )
  assert_true(
    code.contains(
      "  let unmet = condition_unmet(response, 946684800L, false)\n",
    ),
  )
  assert_true(
    code.contains(
      "  let response = if unmet { { ..response, code: 304 } } else { response }\n",
    ),
  )
  // No file then.
  let code = @curl2mbt.parse("curl -z -stamp -o out http://h/").plan.emit().code
  assert_true(code.contains("  let condition_time = file_time(\"stamp\")\n"))
  assert_true(
    code.contains(
      "  if condition_time is Some((_, date)) {\n    headers[\"If-Unmodified-Since\"] = date\n  }\n",
    ),
  )
  assert_true(code.contains("    condition_unmet(response, time, true)\n"))
  assert_true(code.contains("  if !unmet {\n    @fs.write_file(\"out\""))
  assert_false(code.contains("let response = if unmet"))
}

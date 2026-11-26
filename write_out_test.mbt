///|
/// The text of `-w` in the plan of a command line.
fn write_out_plan(arguments : Array[String]) -> String? raise {
  let words = ["curl"]
  words.append(arguments)
  words.push("http://h/")
  @curl2mbt.parse_argv(words).plan.write_out
}

///|
/// The codes of what is reported about a command line that is rejected.
fn write_out_errors(arguments : Array[String]) -> Array[String] {
  let words = ["curl"]
  words.append(arguments)
  words.push("http://h/")
  let found = @curl2mbt.parse_argv(words).diagnostics catch {
      CurlError(found) => found
    }
  found.map(item => item.code)
}

///|
test "the text of -w" {
  assert_eq(write_out_plan([]), None)
  assert_eq(write_out_plan(["-w", "%{http_code}\\n"]), Some("%{http_code}\\n"))
  // The last one counts, and an empty one writes nothing.
  assert_eq(write_out_plan(["-w", "a", "--write-out", "b"]), Some("b"))
  assert_eq(write_out_plan(["-w", "a", "-w", ""]), None)
  // curl writes these as they are.
  assert_eq(
    write_out_plan(["-w", "%% %x \\x %{http_code"]),
    Some("%% %x \\x %{http_code"),
  )
  assert_eq(
    write_out_plan([
      "-w", "%{response_code}%{content_type}%{size_download}%{num_redirects}%{url_effective}%{method}%{stderr}%{stdout}",
    ]),
    Some(
      "%{response_code}%{content_type}%{size_download}%{num_redirects}%{url_effective}%{method}%{stderr}%{stdout}",
    ),
  )
}

///|
test "texts of -w that are rejected" {
  assert_eq(write_out_errors(["-w", "%{time_total}"]), ["unsupported-value"])
  assert_eq(write_out_errors(["-w", "%{nope}"]), ["unsupported-value"])
  assert_eq(write_out_errors(["-w", "%{HTTP_CODE}"]), ["unsupported-value"])
  assert_eq(write_out_errors(["-w", "%header{x-a}"]), ["unsupported-value"])
  assert_eq(write_out_errors(["-w", "%output{f}"]), ["unsupported-value"])
  assert_eq(write_out_errors(["-w", "@f"]), ["file-not-supported"])
  // curl writes the fragment, which the plan leaves out.
  let fragment = (text : String) => {
    let found = @curl2mbt.parse_argv(["curl", "-w", text, "http://h/a#f"]).diagnostics catch {
        CurlError(found) => found
      }
    found.map(item => item.code)
  }
  assert_eq(fragment("%{url_effective}"), ["unsupported-value"])
  assert_eq(fragment("%{http_code}"), [])
}

///|
test "the program for -w" {
  let code = @curl2mbt.parse(
      "curl -w '%{http_code} %{content_type}\\n%%' http://h/",
    ).plan.emit().code
  assert_true(
    code.contains(
      (
        #|  @stdio.stdout.write(body)
        #|  let content_type = response.headers.get("Content-Type").unwrap_or("")
        #|  @stdio.stdout.write("\{response.code} \{content_type}\n%")
      ),
    ),
  )
  // Without -L, nothing is redirected.
  let code = @curl2mbt.parse(
      "curl -w '%{num_redirects} %{url_effective} %{method}' -d x http://h/a",
    ).plan.emit().code
  assert_true(code.contains("@stdio.stdout.write(\"0 http://h/a POST\")"))
  assert_false(code.contains("transfer"))
  // With -L, the program keeps where the request went.
  let code = @curl2mbt.parse(
      "curl -L -w '%{num_redirects}%{stderr}%{url_effective}' http://h/",
    ).plan.emit().code
  assert_true(code.contains("      transfer.redirects = redirects\n"))
  assert_true(code.contains("  @stdio.stderr.write(\"\\{transfer.url}\")\n"))
}

///|
test "-w with -f" {
  // curl writes the text before it fails, and no body.
  let code = @curl2mbt.parse(
      "curl -f -w '%{http_code} %{size_download}' http://h/",
    ).plan.emit().code
  assert_true(
    code.contains(
      (
        #|  if response.code >= 400 {
        #|    @stdio.stdout.write("\{response.code} 0")
        #|    fail("HTTP status \{response.code}")
        #|  }
      ),
    ),
  )
}

///|
test "-w in plans and commands" {
  let plan = @curl2mbt.parse("curl -w '%{http_code}' http://h/").plan
  assert_eq(plan.to_curl(), "curl -w '%{http_code}' http://h/")
  let again = @curl2mbt.RequestPlan::from_json(plan.to_json())
  assert_eq(again.write_out, Some("%{http_code}"))
  let bad = plan.to_json()
  guard bad is Object(fields) else { fail("not an object") }
  fields["write_out"] = Json::string("%{time_total}")
  assert_true(
    try @curl2mbt.RequestPlan::from_json(bad) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
/// The method, URL and body of the plan of a command line.
fn upload_plan(arguments : Array[String]) -> String raise {
  let words = ["curl"]
  words.append(arguments)
  let plan = @curl2mbt.parse_argv(words).plan
  let body = match plan.body {
    Some(Upload(path)) => " <\{path}>"
    Some(Data(value)) => " " + value.to_text().unwrap_or("?")
    _ => ""
  }
  "\{plan.http_method} \{plan.url.to_string()}\{body}"
}

///|
test "uploads" {
  for
    entry in [
      (["-T", "f", "http://h/"], "PUT http://h/f <f>"),
      (["-T", "f", "http://h"], "PUT http://h/f <f>"),
      (["-T", "f", "http://h/u"], "PUT http://h/u <f>"),
      (
        ["-T", "d/a b%é.txt", "http://h/x/"],
        "PUT http://h/x/a%20b%25%c3%a9.txt <d/a b%é.txt>",
      ),
      (["-T", "f", "http://h/d/?"], "PUT http://h/d/f <f>"),
      (["-T", "f", "http://h/d/?q=1"], "PUT http://h/d/?q=1 <f>"),
      (["-T", "f", "http://h/d/#x"], "PUT http://h/d/f <f>"),
      (["-T", "f", "-X", "POST", "http://h/"], "POST http://h/f <f>"),
      (["-T", "f", "--url-query", "a=1", "http://h/"], "PUT http://h/f?a=1 <f>"),
    ] {
    assert_eq(upload_plan(entry.0), entry.1)
  }
}

///|
test "a file of an upload is named on Windows with backslashes too" {
  let plan = @curl2mbt.parse("curl -T \"C:\\x\\f.txt\" http://h/", shell=Cmd).plan
  assert_eq(plan.url.to_string(), "http://h/f.txt")
}

///|
test "queries" {
  for
    entry in [
      (["--url-query", "a=b c&d", "http://h/"], "GET http://h/?a=b+c%26d"),
      (["--url-query", "=b c", "http://h/"], "GET http://h/?b+c"),
      (["--url-query", "é*~", "http://h/"], "GET http://h/?%c3%a9%2a~"),
      (
        ["--url-query", "+a=%41&b", "http://h/?x=1#f"],
        "GET http://h/?x=1&a=%41&b",
      ),
      (["--url-query", "", "http://h/"], "GET http://h/"),
      (["--url-query", "", "http://h/?x"], "GET http://h/?x&"),
      (
        ["--url-query", "a=1", "--url-query", "", "http://h/"],
        "GET http://h/?a=1&",
      ),
      (["--url-query", "a=1", "-d", "x", "http://h/"], "POST http://h/?a=1 x"),
    ] {
    assert_eq(upload_plan(entry.0), entry.1)
  }
}

///|
test "uploads and queries that are rejected" {
  for
    arguments in [
      ["-T", "f", "-d", "x"],
      ["-T", "f", "-I"],
      ["-T", "f", "-T", "g"],
      ["-T", "-"],
      ["-T", "d/"],
      ["-T", "{a,b}"],
      ["--url-query", "+a b"],
      ["--url-query", "n@f"],
      ["--url-query", "a=1", "-G", "-d", "b"],
      ["-T", "f", "--path-as-is"],
      ["--url-query", "a=1", "--path-as-is"],
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
}

///|
test "the program for an upload" {
  let code = @curl2mbt.parse("curl -L -T f http://h/u").plan.emit().code
  assert_true(code.contains("  let body = @fs.read_file(\"f\").binary()\n"))
  // A 301 or 302 sends the file again.
  assert_true(code.contains("    if response.code is (303) {\n"))
}

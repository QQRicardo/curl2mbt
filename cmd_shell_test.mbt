///|
/// The target and the body of a command for cmd.
fn cmd_request(text : String) -> String raise {
  let plan = @curl2mbt.parse(text, shell=Cmd).plan
  let body = match plan.body {
    Some(Data(value)) =>
      value
      .pieces()
      .iter()
      .map(piece => {
        match piece {
          Literal(bytes) => @utf8.decode(bytes) catch { _ => "?" }
          Env(name) => "{\{name}}"
          File(path~, ..) => "<\{path}>"
        }
      })
      .join("")
    _ => "-"
  }
  "\{plan.url.target()} \{body}"
}

///|
fn cmd_findings(text : String) -> String {
  let found = @curl2mbt.parse(text, shell=Cmd).diagnostics catch {
      CurlError(found) => found
    }
  found
  .map(item => {
    match item.location {
      Some(Text(start~, end~)) => "\{item.code}@\{start}-\{end}"
      _ => item.code
    }
  })
  .join(" ")
}

///|
test "a request copied for cmd" {
  let text =
    #|curl ^"https://example.com/a?b=1^&c=^%^20^" ^
    #|  -H ^"accept: text/html^" ^
    #|  -H ^"x: ^\^"q^\^" a^|b^^^" ^
    #|  --data-raw ^"^{^\^"a^\^":^\^"b \\ ^\^"^}^"
  inspect(
    cmd_request(text),
    content=(
      #|/a?b=1&c=%20 {"a":"b \\ "}
    ),
  )
  let headers = @curl2mbt.parse(text, shell=Cmd).plan.headers
  inspect(
    headers[1].value.to_text().unwrap(),
    content=(
      #|"q" a|b^
    ),
  )
  inspect(cmd_findings(text), content="")
}

///|
test "quotes, carets and backslashes of cmd" {
  for
    entry in [
      ("a^b", "ab"),
      ("\"a^b\"", "a^b"),
      ("a^^b", "a^b"),
      ("\"a & b | c > d\"", "a & b | c > d"),
      ("a^&b", "a&b"),
      ("\"a\\\"b\"", "a\"b"),
      ("\"a\\\\\"", "a\\"),
      ("\"a\\\\\\\"b\"", "a\\\"b"),
      ("a\\b\\\\c\\", "a\\b\\\\c\\"),
      ("\"\"", ""),
      ("a\"b c\"d", "ab cd"),
      ("^\n  -v --data-raw x", "x"),
      ("a^\n\nb", "a\nb"),
      ("^\"a^\r\n\r\nb^\"", "a\nb"),
      ("'a'", "'a'"),
      ("{a},(b);c=!d!", "{a},(b);c=!d!"),
    ] {
    let text = if entry.0.has_prefix("^\n") {
      "curl http://h/ \{entry.0}"
    } else {
      "curl http://h/ --data-raw \{entry.0}"
    }
    assert_eq(cmd_request(text), "/ \{entry.1}")
  }
}

///|
test "percent signs of cmd" {
  for
    entry in [
      ("\"%TOKEN%\"", "{TOKEN}"),
      ("^\"a%TOKEN%^\"", "a{TOKEN}"),
      ("\"%a b%\"", "%a b%"),
      ("\"%20%41%\"", "%20%41%"),
      ("\"%C3%A9\"", "%C3%A9"),
      ("\"%c3abc%20\"", "%c3abc%20"),
      ("\"100%\"", "100%"),
      ("\"%%\"", "%%"),
      ("^%^TOKEN^%", "%TOKEN%"),
      ("\"%1 %*\"", "%1 %*"),
    ] {
    assert_eq(
      cmd_request("curl http://h/ --data-raw \{entry.0}"),
      "/ \{entry.1}",
    )
  }
  inspect(
    cmd_findings("curl http://h/ --data-raw \"%c3abc%20 %% %A_1%\""),
    content="percent-not-variable@27-34 batch-percent@37-39 cmd-variable@40-45",
  )
}

///|
test "commands for cmd that are rejected" {
  for
    entry in [
      ("curl http://h/ | more", "shell-syntax@15-16"),
      ("curl http://h/?a&b", "shell-syntax@16-17"),
      ("curl http://h/ > x", "shell-syntax@15-16"),
      ("curl http://h/ -d \"a", "unterminated-quote@18-19"),
      ("curl http://h/ -d \"a\nb\"", "several-commands@21-22"),
      ("curl http://h/\ncurl http://h/", "several-commands@15-16"),
      ("curl http://h/ ^", "shell-syntax@15-16"),
      ("curl http://h/ ^\n", "shell-syntax@15-17"),
      ("curl http://h/ -d \"a\"\"b\"", "shell-syntax@20-22"),
      (
        "curl http://h/ --data-raw %A%", "cmd-variable@26-29 unquoted-variable@26-29",
      ),
      ("curl http://h/ --data-raw \"%A:a=b%\"", "shell-syntax@27-34"),
      ("curl http://h/ --data-raw \"%Date%\"", "shell-syntax@27-33"),
      ("curl \"http://%A%/\"", "variable-not-supported@5-18 cmd-variable@13-16"),
      ("curl http://h/ -d a\rb", "shell-syntax@19-20"),
      ("curl http://h/ -d a\u0000", "shell-syntax@19-20"),
      ("$ curl http://h/", "not-curl@0-1"),
      ("", "no-command"),
    ] {
    assert_eq(cmd_findings(entry.0), entry.1)
  }
}

///|
test "findings about cmd that are no errors" {
  for
    entry in [
      ("curl http://h/ -d '{}'", "single-quote@18-19"),
      ("curl http://h/ -d *", "unquoted-pattern@18-19"),
      ("curl http://h/ -d \"é ü\"", "code-page@19-20"),
      ("\r\n CURL.exe http://h/ \r\n", ""),
      ("C:\\x\\curl.exe http://h/", ""),
    ] {
    assert_eq(cmd_findings(entry.0), entry.1)
    ignore(cmd_request(entry.0))
  }
}

///|
/// Backslashes separate the parts of a path here.
test "files in commands for cmd" {
  let text = "curl http://h/ -F \"a=@C:\\x y\\z.png\""
  guard @curl2mbt.parse(text, shell=Cmd).plan.body is Some(Multipart([part])) else {
    fail("not a form")
  }
  assert_eq(part.filename, Some("z.png"))
  assert_eq(part.content.pieces().to_owned(), [
    File(path="C:\\x y\\z.png", read=Whole),
  ])
}

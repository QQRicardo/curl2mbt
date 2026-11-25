///|
/// The plan of a command line as compact JSON.
fn plan_of(text : String) -> String raise {
  @curl2mbt.parse(text).plan.to_json().stringify()
}

///|
/// `code@start-end` of each finding about a command.
fn findings(text : String) -> String {
  let found = @curl2mbt.parse(text).diagnostics catch {
      CurlError(found) => found
    }
  found
  .map(item => {
    match item.location {
      Some(Text(start~, end~)) => "\{item.code}@\{start}-\{end}"
      Some(Argument(index)) => "\{item.code}@\{index}"
      None => item.code
    }
  })
  .join(" ")
}

///|
/// Whether a command is rejected.
fn is_rejected(text : String) -> Bool {
  try @curl2mbt.parse(text) catch {
    _ => true
  } noraise {
    _ => false
  }
}

///|
test "a plain URL" {
  inspect(
    plan_of("curl example.com"),
    content="{\"version\":1,\"method\":\"GET\",\"url\":\"http://example.com/\",\"headers\":[{\"name\":\"Accept\",\"value\":\"*/*\",\"implied\":true}]}",
  )
  inspect(findings("curl example.com"), content="guessed-scheme@5-16")
}

///|
test "a request from API documentation" {
  let text =
    #|curl https://api.example.com/v1/chat \
    #|  -H "Content-Type: application/json" \
    #|  -H "Authorization: Bearer $API_KEY" \
    #|  -d '{"model": "m", "stream": false}'
  inspect(
    plan_of(text),
    content="{\"version\":1,\"method\":\"POST\",\"url\":\"https://api.example.com/v1/chat\",\"headers\":[{\"name\":\"Accept\",\"value\":\"*/*\",\"implied\":true},{\"name\":\"Content-Type\",\"value\":\"application/json\"},{\"name\":\"Authorization\",\"value\":[{\"text\":\"Bearer \"},{\"env\":\"API_KEY\"}]}],\"body\":{\"data\":\"{\\\"model\\\": \\\"m\\\", \\\"stream\\\": false}\"}}",
  )
  inspect(findings(text), content="")
}

///|
test "a request copied from a browser" {
  // Chrome escapes as $'...' when a value has a line break, a quote or
  // characters outside ASCII, with one \u for each UTF-16 code unit.
  let text =
    #|curl 'https://example.com/api/items?page=2' \
    #|  -H 'accept: application/json' \
    #|  -H 'accept-language: en-US,en;q=0.9' \
    #|  -b 'sid=abc; theme=dark' \
    #|  -H 'user-agent: Mozilla/5.0' \
    #|  --data-raw $'{"name":"Zo\u00eb \ud83d\ude00","note":"it\'s"}' \
    #|  --compressed
  let parsed = @curl2mbt.parse(text)
  let plan = parsed.plan
  inspect(plan.http_method, content="POST")
  inspect(plan.url.target(), content="/api/items?page=2")
  inspect(
    plan.headers.map(header => header.name).join(", "),
    content="Cookie, accept, accept-language, user-agent, Content-Type",
  )
  guard plan.body is Some(Data(body)) else { fail("no body") }
  assert_eq(
    body.to_text(),
    Some("{\"name\":\"Zo\u00eb \u{1F600}\",\"note\":\"it's\"}"),
  )
  assert_true(plan.compressed)
  inspect(
    parsed.diagnostics.map(item => item.code).join(" "),
    content="surrogate-escapes",
  )
}

///|
test "bytes that are not UTF-8" {
  let plan = @curl2mbt.parse("curl http://h/ -d $'a\\xff\"b'").plan
  guard plan.body is Some(Data(body)) else { fail("no body") }
  assert_eq(body.to_bytes(), Some(b"a\xff\"b"))
  assert_eq(body.to_text(), None)
  assert_true(
    plan_of("curl http://h/ -d $'a\\xff'").contains(
      "{\"data\":[{\"base64\":\"Yf8=\"}]}",
    ),
  )
  // Header values must be text.
  inspect(
    findings("curl http://h/ -H $'X: \\xff'"),
    content="bad-header-value@18-28",
  )
  inspect(
    findings("curl http://h/ -A $'a\\nb'"),
    content="bad-header-value@18-25",
  )
}

///|
test "variables" {
  let plan = @curl2mbt.parse(
      "curl http://h/ -u \"$USER_1:${PASS}x\" --data-raw \"$A$B\"",
    ).plan
  guard plan.auth is Some(Basic(user)) else { fail("no auth") }
  assert_eq(user.pieces().to_owned(), [
    Env("USER_1"),
    Literal(b":"),
    Env("PASS"),
    Literal(b"x"),
  ])
  assert_eq(user.env_names(), ["USER_1", "PASS"])
  assert_eq(user.to_bytes(), None)
  guard plan.body is Some(Data(body)) else { fail("no body") }
  assert_eq(body.pieces().to_owned(), [Env("A"), Env("B")])
  inspect(findings("curl http://h/ -d x$A"), content="unquoted-variable@19-21")
  inspect(
    findings("curl \"-X$M\" http://h/"),
    content="variable-not-supported@5-11",
  )
  inspect(
    findings("curl \"-s$M\" http://h/"),
    content="variable-in-option@5-11 no-effect-on-request@5-11",
  )
  inspect(
    findings("curl \"--data$M\" http://h/"),
    content="unknown-option@5-15",
  )
  inspect(
    findings("curl http://h/ --json \"$A\""),
    content="variable-may-name-file@22-26",
  )
  inspect(
    findings("curl http://h/ -b \"$A=b\""),
    content="variable-may-name-file@18-24",
  )
  inspect(
    findings("curl http://h/ -b \"$A\""),
    content="file-not-supported@18-22",
  )
  inspect(
    findings("curl http://h/ --data-urlencode \"a=$A\""),
    content="variable-not-supported@32-38",
  )
}

///|
test "all errors are reported, in order" {
  inspect(
    findings(
      "curl -F a=b --digest -X 'A B' 'http://h/a b' extra -H 'bad name: 1'",
    ),
    content="unsupported-option@5-7 unsupported-option@12-20 bad-method@24-29 bad-url@30-44 several-urls@45-50 bad-header-name@54-67",
  )
  inspect(
    findings("curl http://h/ -d @f | jq"),
    content="file-not-supported@18-20 shell-syntax@21-22",
  )
}

///|
test "errors of the command as a whole" {
  inspect(findings(""), content="no-command")
  inspect(findings("  # only a comment"), content="no-command")
  inspect(findings("wget http://h/"), content="not-curl@0-4")
  inspect(findings("curl"), content="no-url")
  inspect(findings("'' http://h/"), content="not-curl@0-2")
  inspect(findings("/usr/bin/curl http://h/"), content="")
  inspect(findings("curl.exe http://h/"), content="")
  inspect(findings("$ curl http://h/"), content="prompt@0-1")
}

///|
test "line breaks" {
  inspect(findings("curl \\\r\n  http://h/\r\n"), content="")
  inspect(findings("curl http://h/\n\n# end"), content="")
  inspect(findings("curl http://h/;\n"), content="")
  inspect(findings("curl http://h/\n-X PUT"), content="several-commands@15-16")
  inspect(findings("curl http://h/ -d x\\"), content="shell-syntax@19-20")
  inspect(
    findings("curl http://h/ -d \"$A\\\nB\""),
    content="shell-syntax@19-20",
  )
  inspect(findings("curl http://h/ -d x$\\\n!"), content="shell-syntax@19-20")
  // Both halves of a word around a continued line belong together.
  inspect(@curl2mbt.parse("curl http://h/a\\\nb").plan.url.path, content="/ab")
}

///|
test "unquoted patterns are taken literally, with a warning" {
  let parsed = @curl2mbt.parse("curl http://h/?a=*")
  inspect(parsed.plan.url.target(), content="/?a=*")
  inspect(
    findings("curl http://h/?a=*"),
    content="unquoted-pattern@14-15 unquoted-pattern@17-18",
  )
  inspect(findings("curl 'http://h/?a=*'"), content="")
}

///|
test "half of a surrogate pair is rejected" {
  let half = "\u{1F600}".code_units()[0].unsafe_to_char().to_string()
  assert_true(is_rejected("curl http://h/ -d '\{half}'"))
  assert_true(is_rejected("curl http://h/ -d $'\\udc00'"))
  assert_true(is_rejected("curl http://h/ -d $'\\ud800\\u0041'"))
  assert_true(is_rejected("curl http://h/ -d $'\\U00110000'"))
  assert_true(is_rejected("curl http://h/ -d $'\\U7fffffff'"))
  assert_true(is_rejected("curl http://h/ -d $'\\Uffffffff'"))
  assert_true(is_rejected("curl http://h/ -d 'a\u0000b'"))
}

///|
test "octal and hexadecimal escapes" {
  fn body(text : String) -> Bytes? raise {
    match @curl2mbt.parse("curl http://h/ --data-raw \{text}").plan.body {
      Some(Data(value)) => value.to_bytes()
      None => None
    }
  }

  assert_eq(body("$'\\1011'"), Some(b"A1"))
  assert_eq(body("$'\\x411'"), Some(b"A1"))
  assert_eq(body("$'\\x4g'"), Some(b"\x04g"))
  assert_eq(body("$'\\777'"), Some(b"\xff"))
  assert_eq(body("$'\\8'"), Some(b"\\8"))
  assert_eq(body("$'\\u41g'"), Some(b"Ag"))
  assert_eq(body("$'\\u00410'"), Some(b"A0"))
  assert_true(is_rejected("curl http://h/ -d $'\\400'"))
}

///|
test "times and redirects" {
  fn plan(options : String) -> @curl2mbt.RequestPlan raise {
    @curl2mbt.parse("curl http://h/ \{options}").plan
  }

  assert_eq(plan("-m 0").max_time_ms, None)
  assert_eq(plan("-m 2").max_time_ms, Some(2000))
  assert_eq(plan("-m 0.001").max_time_ms, Some(1))
  assert_eq(plan("-m 1.5 -m 2.25").max_time_ms, Some(2250))
  assert_eq(plan("-m 999999.999").max_time_ms, Some(999999999))
  for bad in ["1.", ".5", "1.2345", "1000000", "-1", "1e3", "\"\""] {
    inspect(
      findings("curl http://h/ -m \{bad}").contains("unsupported-value"),
      content="true",
    )
  }
  assert_eq(plan("").max_redirects, 50)
  assert_eq(plan("-L --max-redirs 0").max_redirects, 0)
  assert_true(is_rejected("curl http://h/ --max-redirs -1"))
  assert_true(is_rejected("curl http://h/ --max-redirs 1000000"))
  assert_true(plan("-L").follow_redirects)
  assert_false(plan("-L --no-location").follow_redirects)
  assert_true(plan("-k").insecure)
  assert_true(plan("-f").fail_on_error)
  assert_true(plan("-b a=b").cookie_engine)
}

///|
test "URLs" {
  fn url(text : String) -> String raise {
    @curl2mbt.parse("curl '\{text}'").plan.url.to_string()
  }

  inspect(url("HTTPS://Example.COM:443/A"), content="https://Example.COM/A")
  inspect(url("http://h:80"), content="http://h/")
  inspect(url("https://h:80/"), content="https://h:80/")
  inspect(url("http://h:/x"), content="http://h/x")
  inspect(url("http://h:0080/x"), content="http://h/x")
  inspect(url("http://[::1]:8080/x"), content="http://[::1]:8080/x")
  inspect(url("http://[::ffff:1.2.3.4]"), content="http://[::ffff:1.2.3.4]/")
  inspect(url("http://1.2.3.4?q"), content="http://1.2.3.4/?q")
  inspect(url("http://a.b-c_d.e2e/"), content="http://a.b-c_d.e2e/")
  inspect(url("h/?u=http://x"), content="http://h/?u=http://x")
  inspect(url("http://a:b@c@h/"), content="http://h/")
  inspect(url("http://h/a/b/../../../c"), content="http://h/c")
  for
    bad in [
      "http://", "http:///x", "http://h:x/", "http://h:99999999999/", "http://h..x/",
      "http://.h/", "http://h./", "http://1.2.3/", "http://1.2.3.256/", "http://01.2.3.4/",
      "http://0x7f.1/", "http://1.2.3.4.5/", "http://[::1", "http://[::1]x/", "http://[fe80::1%25en0]/",
      "http://[1]/", "http://h%41/", "http://é/", "http://h\u007F/", "http://h/\t",
      "mailto:/x", "file:///x",
    ] {
    if !is_rejected("curl '\{bad}'") {
      fail("accepted \{bad}")
    }
  }
}

///|
test "values never appear in messages" {
  let secret = "s3cr3t"
  for
    text in [
      "curl http://h/ -u \{secret}",
      "curl http://u:\{secret}@h/{a}",
      "curl http://h/ -H 'bad \{secret}: x'",
      "curl http://h/ -H '\{secret}'",
      "curl http://h/ -b \{secret}",
      "curl http://h/ -X '\{secret} x'",
      "curl http://h/ --oauth2-bearer $'\{secret}\\n'",
      "curl 'http://h/ \{secret}'",
      "curl http://h/ -m \{secret}",
      "curl http://h/ -d @\{secret}",
      "curl --\{secret} http://h/",
      "curl http://h/ \{secret}/",
      "\{secret} http://h/",
      "curl -d '\{secret}",
      "curl http://h/ -G -d ' \{secret}'",
    ] {
    let found = @curl2mbt.parse(text).diagnostics catch {
        CurlError(found) => found
      }
    assert_true(found.length() > 0)
    for item in found {
      if item.render(source=text).contains(secret) {
        fail("shown for \{text}")
      }
    }
  }
}

///|
test "rendering" {
  let text = "curl \\\n  --bogus http://h/"
  let found = @curl2mbt.parse(text).diagnostics catch {
      CurlError(found) => found
    }
  inspect(
    found[0].render(source=text),
    content=(
      #|error[unknown-option] at 2:3: curl has no such option
      #|  help: check the spelling; curl does not accept shortened names
    ),
  )
  inspect(
    found[0].render().split("\n").collect()[0],
    content="error[unknown-option] at offset 9: curl has no such option",
  )
  let found = @curl2mbt.parse_argv(["curl", "-d"]).diagnostics catch {
      CurlError(found) => found
    }
  inspect(
    found.map(item => item.render()).join("\n"),
    content=(
      #|error[missing-value] at argument 1: the option -d needs a value
      #|error[no-url]: the command has no URL
    ),
  )
}

///|
test "arguments are literal" {
  let plan = @curl2mbt.parse_argv(["curl", "http://h/?a=*", "-d", "$X `y` 'z'"]).plan
  guard plan.body is Some(Data(body)) else { fail("no body") }
  assert_eq(body.to_text(), Some("$X `y` 'z'"))
}

///|
test "reading is deterministic" {
  let text = "curl http://h/ -H 'b: 1' -H 'a: 2' -d x -b c=d -u e:f -k"
  let first = plan_of(text)
  for _ in 0..<20 {
    assert_eq(plan_of(text), first)
  }
}

///|
/// The body of the plan for a command, as JSON.
fn body_json(options : Array[String]) -> String raise {
  let words = ["curl", "http://h/"]
  words.append(options)
  let json = @curl2mbt.parse_argv(words).plan.to_json()
  guard json is { "body": body, .. } else { fail("no body") }
  body.stringify()
}

///|
test "parts of forms" {
  inspect(
    body_json(["-F", "a=1", "--form-string", "b=@x;type=y"]),
    content=(
      #|{"multipart":[{"name":"a","content":"1"},{"name":"b","content":"@x;type=y"}]}
    ),
  )
  inspect(
    body_json(["-F", "a=\"x;\\\"y\\\" \\z\"; type=a/b;filename=\"p;q\""]),
    content=(
      #|{"multipart":[{"name":"a","content":"x;\"y\" \\z","filename":"p;q","type":"a/b"}]}
    ),
  )
  inspect(
    body_json(["-F", "a=@d/f.PNG", "-F", "b=@f", "-F", "c=<f.txt"]),
    content=(
      #|{"multipart":[{"name":"a","content":[{"file":"d/f.PNG"}],"filename":"f.PNG","type":"image/png"},{"name":"b","content":[{"file":"f"}],"filename":"f","type":"application/octet-stream"},{"name":"c","content":[{"file":"f.txt"}]}]}
    ),
  )
}

///|
test "data from files" {
  inspect(
    body_json(["-d", "@f"]),
    content=(
      #|{"data":[{"file":"f","without_line_breaks":true}]}
    ),
  )
  inspect(
    body_json(["-d", "a", "--data-binary", "@f", "--data-urlencode", "n@g"]),
    content=(
      #|{"data":[{"text":"a&"},{"file":"f"},{"text":"&"},{"file":"g","form_encoded":"n"}]}
    ),
  )
  inspect(
    body_json(["--json", "@f", "--json", "@g"]),
    content=(
      #|{"data":[{"file":"f"},{"file":"g"}]}
    ),
  )
}

///|
test "plans with files and forms survive JSON" {
  for
    options in [
      ["-d", "@f"],
      ["-d", "x", "--data-urlencode", "n@f", "--data-urlencode", "@f"],
      ["-F", "a=1", "-F", "b=@f.png", "-F", "c=<f;type=x/y"],
      ["--form-string", "é\n=\""],
    ] {
    let words = ["curl", "http://h/"]
    words.append(options)
    let plan = @curl2mbt.parse_argv(words).plan
    let text = plan.to_json().stringify()
    assert_eq(@curl2mbt.RequestPlan::from_json(@json.parse(text)), plan)
  }
}

///|
test "JSON bodies that are no plan" {
  for
    entry in [
      ("{}", "body"),
      ("{\"data\":\"\",\"multipart\":[]}", "body"),
      ("{\"multipart\":[]}", "body.multipart"),
      (
        "{\"multipart\":[{\"name\":\"\",\"content\":\"\"}]}", "body.multipart[0].name",
      ),
      ("{\"multipart\":[{\"name\":\"a\"}]}", "body.multipart[0].content"),
      (
        "{\"multipart\":[{\"name\":\"a\",\"content\":\"\",\"type\":\"a\\r\\nb/c\"}]}",
        "body.multipart[0].type",
      ),
      (
        "{\"multipart\":[{\"name\":\"a\",\"content\":\"\",\"filename\":\"\"}]}",
        "body.multipart[0].filename",
      ),
      ("{\"data\":[{\"file\":\"\"}]}", "body.data[0].file"),
      ("{\"data\":[{\"file\":\"f\",\"text\":\"\"}]}", "body.data[0]"),
      (
        "{\"data\":[{\"file\":\"f\",\"form_encoded\":\"a=\"}]}", "body.data[0].form_encoded",
      ),
      (
        "{\"data\":[{\"file\":\"f\",\"form_encoded\":\"\",\"without_line_breaks\":true}]}",
        "body.data[0]",
      ),
    ] {
    let text = "{\"version\":1,\"method\":\"POST\",\"url\":\"http://h/\",\"headers\":[],\"body\":\{entry.0}}"
    let path = try @curl2mbt.RequestPlan::from_json(@json.parse(text)) catch {
      @curl2mbt.PlanError(path~, ..) => path
      _ => "other"
    } noraise {
      _ => "accepted"
    }
    assert_eq(path, entry.1)
  }
  // A file can only be in a body.
  let text = "{\"version\":1,\"method\":\"GET\",\"url\":\"http://h/\",\"headers\":[{\"name\":\"a\",\"value\":[{\"file\":\"f\"}]}]}"
  assert_true(
    try @curl2mbt.RequestPlan::from_json(@json.parse(text)) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
test "the program for a form" {
  let emitted = @curl2mbt.parse(
    "curl https://h/ -F 'a\"b=@x/f.png' --form-string \"c=$TOKEN\"",
  ).plan.emit()
  assert_true(
    emitted.code.contains(
      (
        #|  let (boundary, body) = form_data([
        #|    (
        #|      "Content-Disposition: form-data; name=\"a%22b\"; filename=\"f.png\"\r\nContent-Type: image/png",
        #|      @fs.read_file("x/f.png").binary(),
        #|    ),
        #|    (
        #|      "Content-Disposition: form-data; name=\"c\"",
        #|      @utf8.encode("\{env_token}"),
        #|    ),
        #|  ])
      ),
    ),
  )
  assert_true(
    emitted.code.contains(
      (
        #|    "Content-Type": "multipart/form-data; boundary=\{boundary}",
      ),
    ),
  )
  assert_true(emitted.imports.contains("moonbitlang/async/fs"))
  assert_eq(emitted.environment, ["TOKEN"])
  // Only the functions in use are there.
  assert_true(emitted.code.contains("fn form_data("))
  assert_false(emitted.code.contains("fn form_encoded("))
  assert_false(emitted.code.contains("fn without_line_breaks("))
}

///|
test "the program for data from files" {
  let code = @curl2mbt.parse("curl h -d a -d @f --data-urlencode n@g").plan.emit().code
  assert_true(
    code.contains(
      (
        #|  let body = b"a&" + without_line_breaks(@fs.read_file("f").binary()) + b"&" + form_encoded(b"n", @fs.read_file("g").binary())
      ),
    ),
  )
}

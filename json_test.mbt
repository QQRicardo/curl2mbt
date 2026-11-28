///|
test "plans survive JSON" {
  for
    text in [
      "curl h", "curl -I -k -f -L --max-redirs 3 -m 1.5 --compressed https://u:p@h:8443/a?b#c",
      "curl -X PURGE -A '' h", "curl -d '' h", "curl --json '{}' h", "curl --oauth2-bearer \"x$T\" h",
      "curl -u \"$U:$P\" --data-raw \"$A b $C\" -H \"X: $D\" h", "curl -d $'\\xff\\xfe' -b 'a=b' h",
      "curl -H 'Host: x' -H 'Accept:' -H 'E;' -H 'D: 1' -H 'd: 2' h", "curl -d 'é 😀' h",
      "curl -g 'h/{a}?[b]'", "curl --path-as-is h/../a", "curl -T f h/", "curl --create-dirs -o d/f h",
      "curl --fail-with-body -O h/x/y", "curl --retry 2 h", "curl --retry 1 --retry-delay 2 --retry-max-time 3.5 --retry-all-errors h",
    ] {
    let plan = @curl2mbt.parse(text).plan
    let json = plan.to_json().stringify()
    let read = @curl2mbt.RequestPlan::from_json(@json.parse(json))
    if read != plan {
      fail("changed: \{text}")
    }
    assert_eq(read.to_json().stringify(), json)
  }
}

///|
/// The path and message of what is wrong with a plan.
fn problem(json : String) -> String raise {
  try @curl2mbt.RequestPlan::from_json(@json.parse(json)) catch {
    @curl2mbt.PlanError(path~, message~) => "\{path}: \{message}"
    error => raise error
  } noraise {
    _ => "none"
  }
}

///|
/// A plan whose fields from `headers` on are `rest`.
fn plan_json(rest : String) -> String {
  "{\"version\":1,\"method\":\"GET\",\"url\":\"http://h/\",\"headers\":\{rest}}"
}

///|
test "JSON that is not a plan" {
  inspect(problem(plan_json("[]")), content="none")
  inspect(problem("[]"), content=": must be an object")
  inspect(problem("{}"), content="version: must be 1")
  inspect(problem("{\"version\":2}"), content="version: must be 1")
  inspect(
    problem("{\"version\":1.5}"),
    content="version: must be a whole number from 1 on",
  )
  inspect(problem("{\"version\":1}"), content="method: must be a string")
  inspect(
    problem("{\"version\":1,\"method\":\"A B\"}"),
    content="method: is not an HTTP token",
  )
  fn with_url(url : String) -> String raise {
    problem(
      "{\"version\":1,\"method\":\"GET\",\"url\":\"\{url}\",\"headers\":[]}",
    )
  }

  inspect(with_url("http://h/a/../b?c"), content="none")
  inspect(
    with_url("http://h"),
    content="url: is not written the way plans write URLs",
  )
  inspect(
    with_url("http://u@h/"),
    content="url: is not written the way plans write URLs",
  )
  inspect(
    with_url("http://h/#f"),
    content="url: is not written the way plans write URLs",
  )
  inspect(with_url("http:///"), content="url: the URL has no host name")
  inspect(problem(plan_json("{}")), content="headers: must be an array")
  inspect(problem(plan_json("[1]")), content="headers[0]: must be an object")
  inspect(
    problem(plan_json("[{\"name\":\"a b\",\"value\":\"\"}]")),
    content="headers[0].name: is not the name of a header field",
  )
  inspect(
    problem(plan_json("[{\"name\":\"Content-Length\",\"value\":\"1\"}]")),
    content="headers[0].name: is a field that plans do not hold",
  )
  inspect(
    problem(plan_json("[{\"name\":\"a\",\"value\":\"x\\r\\ny: z\"}]")),
    content="headers[0].value: is not the value of a header field",
  )
  inspect(
    problem(plan_json("[{\"name\":\"a\",\"value\":\" x\"}]")),
    content="headers[0].value: is not the value of a header field",
  )
  inspect(
    problem(plan_json("[{\"name\":\"a\",\"value\":[{\"env\":\"1A\"}]}]")),
    content="headers[0].value[0].env: is not the name of a variable",
  )
  inspect(
    problem(
      plan_json("[{\"name\":\"a\",\"value\":[{\"env\":\"A\",\"text\":\"b\"}]}]"),
    ),
    content="headers[0].value[0]: must have exactly one of text, base64, env and file",
  )
  inspect(
    problem(plan_json("[{\"name\":\"Host\",\"value\":\"\"}]")),
    content="headers: have an empty or second Host",
  )
  inspect(
    problem(
      plan_json(
        "[{\"name\":\"user-agent\",\"value\":\"x\"}],\"omit_user_agent\":true",
      ),
    ),
    content="omit_user_agent: contradicts the headers",
  )
  inspect(
    problem(plan_json("[],\"auth\":{\"basic\":\"u\"}")),
    content="auth.basic: must have a colon",
  )
  inspect(
    problem(plan_json("[],\"auth\":{\"bearer\":\"\"}")),
    content="auth.bearer: is not a token",
  )
  inspect(
    problem(plan_json("[],\"auth\":{}")),
    content="auth: must have exactly one of basic and bearer",
  )
  inspect(
    problem(
      plan_json(
        "[{\"name\":\"authorization\",\"value\":\"x\"}],\"auth\":{\"bearer\":\"t\"}",
      ),
    ),
    content="auth: contradicts the headers",
  )
  inspect(
    problem(plan_json("[],\"body\":{\"data\":[{\"base64\":\"*\"}]}")),
    content="body.data[0].base64: is not valid base64",
  )
  inspect(
    problem(plan_json("[],\"body\":{\"data\":1}")),
    content="body.data: must be a string or an array",
  )
  inspect(
    problem(plan_json("[],\"insecure\":1")),
    content="insecure: must be true or false",
  )
  inspect(
    problem(plan_json("[],\"max_time_ms\":0")),
    content="max_time_ms: must be a whole number from 1 on",
  )
  inspect(
    problem(plan_json("[],\"future\":1")),
    content=": has a field this version does not know",
  )
}

///|
test "JSON with retries and outputs that do not fit" {
  inspect(
    problem(plan_json("[],\"retry\":{}")),
    content="retry.count: must be a whole number from 1 on",
  )
  inspect(
    problem(plan_json("[],\"retry\":{\"count\":1,\"x\":1}")),
    content="retry: has a field this version does not know",
  )
  inspect(
    problem(plan_json("[],\"retry\":{\"count\":1,\"delay_ms\":0}")),
    content="retry.delay_ms: must be a whole number from 1 on",
  )
  inspect(
    problem(plan_json("[],\"fail_with_body\":true")),
    content="fail_with_body: needs fail_on_error",
  )
  inspect(
    problem(plan_json("[],\"output_file\":\"-\"")),
    content="output_file: is not the name of a file",
  )
  inspect(
    problem(plan_json("[],\"create_dirs\":true")),
    content="create_dirs: needs output_file or etag_save",
  )
}

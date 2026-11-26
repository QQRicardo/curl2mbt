///|
/// The plan without the marks of which fields curl adds on its own.
fn request_of(plan : @curl2mbt.RequestPlan) -> Json {
  let json = plan.to_json()
  guard json is Object(fields) && fields.get("headers") is Some(Array(headers)) else {
    return json
  }
  for header in headers {
    if header is Object(header) {
      header.remove("implied")
    }
  }
  json
}

///|
test "plans are written back as curl commands" {
  for
    text in [
      "curl h", "curl -I -k -f -L --max-redirs 3 -m 1.5 --compressed https://u:p@h:8443/a?b#c",
      "curl -X PURGE -A '' h", "curl -d '' h", "curl --json '{\"a\": 1}' h", "curl --oauth2-bearer \"x$T\" h",
      "curl -u \"$U:$P\" --data-raw \"$A b $C\" -H \"X: $D\" h", "curl -b 'a=b; c=d' -d x h",
      "curl -H 'Host: x' -H 'Accept:' -H 'E;' -H 'D: 1' -H 'd: 2' h", "curl -d 'é 😀' h",
      "curl -g 'h/{a}?[b]'", "curl --path-as-is h/../a", "curl -T 'f g' h/", "curl --create-dirs -o d/f h",
      "curl --fail-with-body -O h/x/y", "curl --retry 2 --retry-delay 0.25 --retry-all-errors h",
      "curl -A ua -e ref -r 0-3 -H 'X: 1' h", "curl -H 'User-Agent: a' -H 'Accept: b' h",
      "curl -d 'y&z' -d @f h", "curl -d x --data-binary @f h", "curl --data-urlencode n@g h",
      "curl -F a=1 -F 'b=@f;type=x/y' -F 'c=<g' -F 'd=\"t;x\";type=a/b' h", "curl -F 'f=@\"a b\";filename=\"x\\\"y\"' h",
      "curl -X GET -d 'a=1' h", "curl -G -d a=1 h", "curl -H 'Content-Type: a/b' -d x h",
      "curl -H 'Content-Type:' -d x h", "curl --url-query 'a=b c' h", "curl -d $'a\\nb\\x01' h",
      "curl --json @f --json @empty --json x h", "curl --json '{}' -H Content-Type: h",
      "curl -g -T '{x}' h/", "curl --json '{}' -H 'Accept: a' h",
    ] {
    let plan = @curl2mbt.parse(text).plan
    for shell in [@curl2mbt.Shell::Posix, Cmd] {
      let again = plan.to_curl(shell~) catch {
        ToCurlError(message) =>
          if shell is Cmd && text.contains("$'") {
            continue
          } else {
            fail("\{text}: \{message}")
          }
      }
      let read = @curl2mbt.parse(again, shell~).plan
      if request_of(read) != request_of(plan) {
        fail("\{text} became \{again}")
      }
    }
  }
}

///|
test "commands as written back" {
  let to_curl = (text, shell) => @curl2mbt.parse(text).plan.to_curl(shell~)
  inspect(
    to_curl("curl -sS -H 'X: a b' -d \"it's\" http://h/p", Posix),
    content="curl -H 'X: a b' --data-raw 'it'\\''s' http://h/p",
  )
  inspect(
    to_curl("curl -H 'X: a b' -d \"it's\" http://h/p", Cmd),
    content="curl -H \"X: a b\" --data-raw \"it's\" http://h/p",
  )
  inspect(
    to_curl("curl -H \"X: $T\" -d $'\\xff' http://h/", Posix),
    content="curl -H 'X: '\"${T}\" --data-raw $'\\xff' http://h/",
  )
  inspect(
    to_curl("curl -H 'X: \"a&b\"' http://h/", Cmd),
    content="curl -H \"X: \\\"a^&b\\\"\" http://h/",
  )
  inspect(
    to_curl("curl --json '{}' http://h/", Posix),
    content="curl --json '{}' http://h/",
  )
}

///|
test "plans that cannot be written back" {
  let problem = (text, shell) => {
    let plan = @curl2mbt.parse(text).plan
    try plan.to_curl(shell~) catch {
      ToCurlError(message) => message
    } noraise {
      _ => "none"
    }
  }
  inspect(
    problem("curl -d $'\\xff' h", Cmd),
    content="bytes that are not UTF-8 cannot be written for cmd",
  )
  inspect(
    problem("curl -d $'a\\nb' h", Cmd),
    content="control characters cannot be written for cmd",
  )
}

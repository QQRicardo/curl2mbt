///|
fn argv_curl(arguments : Array[String]) -> String raise {
  @curl2mbt.parse_argv(["curl", ..arguments]).plan.to_curl()
}

///|
fn argv_errors(arguments : Array[String]) -> String {
  let found = @curl2mbt.parse_argv(["curl", ..arguments]).diagnostics catch {
      CurlError(found) => found
    }
  found.map(item => item.render()).join("\n")
}

///|
test "variables and environment variables" {
  inspect(
    argv_curl([
      "--variable", "a=1", "--expand-data", "x={{a}}&y={{a}}", "http://h/",
    ]),
    content="curl --data-raw 'x=1&y=1' http://h/",
  )
  inspect(
    argv_curl([
      "--variable", "%TOKEN", "--expand-header", "Authorization: Bearer {{TOKEN}}",
      "http://h/",
    ]),
    content="curl -H 'Authorization: Bearer '\"${TOKEN}\" http://h/",
  )
  // The last value before the option counts.
  inspect(
    argv_curl([
      "--variable", "a=1", "--variable", "a=2", "--expand-url", "http://h/{{a}}",
      "--variable", "a=3",
    ]),
    content="curl http://h/2",
  )
  // Only --expand- options are expanded.
  inspect(
    argv_curl(["--variable", "a=1", "-d", "{{a}}", "http://h/"]),
    content="curl --data-raw '{{a}}' http://h/",
  )
  inspect(
    argv_curl([
      "--variable", "a=1", "--expand-variable", "b=[{{a}}]", "--expand-data", "{{b}}",
      "http://h/",
    ]),
    content="curl --data-raw '[1]' http://h/",
  )
}

///|
test "functions" {
  inspect(
    argv_curl([
      "--variable", "v=  a \"b\"\\\n\u{1}/\u{e9} ", "--expand-data", "{{v:trim:json}}",
      "http://h/",
    ]),
    content="curl --data-raw 'a \\\"b\\\"\\\\\\n\\u0001/\u{e9}' http://h/",
  )
  inspect(
    argv_curl([
      "--variable", "v=a b&c/d~e-f.g_h\u{e9}", "--expand-data", "{{v:url}}", "http://h/",
    ]),
    content="curl --data-raw 'a%20b%26c%2Fd~e-f.g_h%C3%A9' http://h/",
  )
  inspect(
    argv_curl([
      "--variable", "v=hello", "--expand-data", "{{v:b64}}|{{v:b64:64dec}}", "http://h/",
    ]),
    content="curl --data-raw 'aGVsbG8=|hello' http://h/",
  )
  inspect(
    argv_curl([
      "--variable", "v=aGVsbG8", "--variable", "w=", "--expand-data", "{{v:64dec}}[{{w:64dec}}]",
      "http://h/",
    ]),
    content="curl --data-raw '[64dec-fail][]' http://h/",
  )
}

///|
test "braces that are no variable" {
  inspect(
    argv_curl([
      "--variable", "a=1", "--expand-data", "{{a b}}{{}}{{{a}}}{{a}}}}", "http://h/",
    ]),
    content="curl --data-raw '{{a b}}{{}}{{{a}}}1}}' http://h/",
  )
}

///|
test "what is rejected" {
  inspect(
    argv_errors([
      "--expand-data", "{{nope}}", "--variable", "%A=x", "--variable", "a@f", "--variable",
      "a[1-2]=x", "--variable", "-=1", "--variable", "a=x", "--expand-data", "\\{{a}}",
      "--expand-data", "{{a", "--expand-data", "{{a:nope}}", "--variable", "v=AA==",
      "--expand-data", "{{v:64dec}}", "--variable", "%E", "--expand-data", "{{E:url}}",
      "--expand-silent", "--expand-no-silent", "http://h/",
    ]),
    content=(
      #|error[undefined-variable] at argument 2: the variable is not set by --variable before this option, and curl would put nothing in its place
      #|  help: set it with --variable before the option
      #|error[unsupported-value] at argument 4: a default for an environment variable, or one from a file, is not supported
      #|  help: write --variable %A, and set the variable
      #|error[file-not-supported] at argument 6: reading a variable from a file is not supported
      #|  help: write name=value
      #|error[unsupported-value] at argument 8: a range of bytes of a variable is not supported
      #|  help: write the part you need as name=value
      #|error[bad-variable] at argument 10: a variable needs a name of up to 127 letters, digits and _
      #|  help: write name=value, or %NAME for an environment variable
      #|error[unsupported-value] at argument 14: a backslash before {{ is not supported, because versions of curl read it differently
      #|error[unsupported-value] at argument 16: {{ without }} is not supported, because versions of curl read it differently
      #|error[unsupported-value] at argument 18: curl knows only the functions trim, json, url, b64 and 64dec
      #|error[unsupported-value] at argument 22: the expanded value has a NUL byte, which curl rejects
      #|error[variable-not-supported] at argument 26: functions on the value of an environment variable are not supported
      #|error[unknown-option] at argument 27: curl has no such option
      #|  help: check the spelling; curl does not accept shortened names
      #|error[unknown-option] at argument 28: curl has no such option
      #|  help: check the spelling; curl does not accept shortened names
    ),
  )
}

///|
test "shell text and config files" {
  let text = "curl --variable %KEY --expand-header 'X-Key: {{KEY}}' https://h/"
  inspect(
    @curl2mbt.parse(text).plan.to_curl(),
    content="curl -H 'X-Key: '\"${KEY}\" https://h/",
  )
  // What --expand- expands must be known before the program runs.
  let text = "curl --variable a=1 --expand-data \"{{a}}$X\" https://h/"
  let found = @curl2mbt.parse(text).diagnostics catch {
      CurlError(found) => found
    }
  inspect(found[0].code, content="variable-not-supported")
  let config = "url = https://h/\nvariable = %KEY\nexpand-header = \"X-Key: {{KEY}}\"\n"
  inspect(
    @curl2mbt.parse_config(config).plan.to_curl(),
    content="curl -H 'X-Key: '\"${KEY}\" https://h/",
  )
}

///|
fn config_curl(text : String) -> String raise {
  @curl2mbt.parse_config(text).plan.to_curl()
}

///|
fn config_errors(text : String) -> String {
  let found = @curl2mbt.parse_config(text).diagnostics catch {
      CurlError(found) => found
    }
  found.map(item => item.render(source=text)).join("\n")
}

///|
test "options with and without dashes" {
  let text =
    #|# A comment, and an empty line.
    #|
    #|url = "http://h/a"
    #|header: "X-A: 1"
    #|header="X-B: 2"
    #|-H "X-C: 3"
    #|--header "X-D: 4"
    #|request PUT
    #|silent
    #|-sd v1
    #|
  inspect(
    config_curl(text),
    content="curl -X PUT -H 'X-A: 1' -H 'X-B: 2' -H 'X-C: 3' -H 'X-D: 4' --data-raw v1 http://h/a",
  )
}

///|
test "values" {
  inspect(
    config_curl("url = http://h/\ndata = \"x\\ty\\\"z\\\\w\\qend\""),
    content=(
      #|curl --data-raw $'x\x09y"z\\wqend' http://h/
    ),
  )
  inspect(
    config_curl("url = http://h/\ndata = \"1\\n2\\r3\\v4\""),
    content=(
      #|curl --data-raw $'1\x0a2\x0d3\x0b4' http://h/
    ),
  )
  // Separators in a row, a comment after the value, and `#` in a value.
  inspect(
    config_curl("url :=: http://h/\ndata = x#y # comment"),
    content="curl --data-raw 'x#y' http://h/",
  )
  // Values are literal, and single quotes have no meaning.
  inspect(
    config_curl("url = http://h/\ndata = '$X'"),
    content=(
      #|curl --data-raw ''\''$X'\''' http://h/
    ),
  )
  // An empty value in quotes.
  inspect(
    config_curl("url = http://h/\nuser-agent = \"\"\nsilent = \"\""),
    content="curl -A '' http://h/",
  )
  inspect(
    config_curl("url = \"http://h/\"\r\ndata = \"\u{e9}\"\r\n"),
    content=(
      #|curl --data-raw 'é' http://h/
    ),
  )
  inspect(
    config_curl("url = http://h/\n--data=v"),
    content="curl --data-raw v http://h/",
  )
}

///|
test "what curl reads differently" {
  let text =
    #|url = http://h/
    #|  data = indented
    #|data = two words
    #|data = "quoted" not
    #|data = "open
    #|
  inspect(
    config_errors(text),
    content=(
      #|error[config-syntax] at 2:1: curl does not read an option after blanks at the start of a line
      #|  help: remove the blanks
      #|error[config-syntax] at 3:12: curl ends the value at the first blank and ignores the rest
      #|  help: put the whole value in quotes
      #|error[config-syntax] at 4:17: curl ignores what comes after the closing quote
      #|  help: put the whole value in quotes
      #|error[config-syntax] at 5:8: the quote is not closed on this line
      #|  help: end the value with "; a value cannot go on to the next line, but \n in quotes is a line break
    ),
  )
  // Versions of curl differ about these CRs.
  inspect(
    config_errors("url = http://h/\r\n \t\r\n-d=x\r\ndata = x\r\n"),
    content=(
      #|error[config-syntax] at 2:1: versions of curl differ about a line of blanks that ends with CR
      #|  help: remove the blanks
      #|error[config-syntax] at 3:1: versions of curl differ about a CR right after an option
      #|  help: put the value in quotes after a blank, or end the line with LF only
    ),
  )
}

///|
test "options and values that do not fit" {
  let text =
    #|url = http://h/
    #|silent yes
    #|-s x
    #|-H: x
    #|data
    #|data =
    #|URL = http://h/
    #|http://h/
    #|-
    #|-K other
    #|
  inspect(
    config_errors(text),
    content=(
      #|note[no-effect-on-request] at 2:1: --silent only changes what curl reports
      #|error[unexpected-value] at 2:8: curl rejects a value after an option that takes none or has one already
      #|  help: remove the value
      #|note[no-effect-on-request] at 3:1: -s only changes what curl reports
      #|error[unexpected-value] at 3:4: curl rejects a value after an option that takes none or has one already
      #|  help: remove the value
      #|error[bad-header-name] at 4:1: what is before the colon is not the name of a header field
      #|error[unexpected-value] at 4:5: curl rejects a value after an option that takes none or has one already
      #|  help: remove the value
      #|error[missing-value] at 5:1: the option --data needs a value
      #|error[missing-value] at 6:1: the option --data needs a value
      #|error[unknown-option] at 7:1: curl has no such option
      #|  help: check the spelling; curl does not accept shortened names
      #|error[unknown-option] at 8:1: curl has no such option
      #|  help: check the spelling; curl does not accept shortened names
      #|error[unknown-option] at 9:1: a single - is not an option of curl
      #|error[unsupported-option] at 10:1: -K is not supported, because the file is read when curl runs
      #|  help: read the file with parse_config, as curl2mbt --config FILE does
    ),
  )
  inspect(
    config_errors("# nothing\n"),
    content=(
      #|error[no-url]: the command has no URL
    ),
  )
  inspect(
    config_errors("url = http://h/a\nurl = http://h/b\n"),
    content=(
      #|error[several-urls] at 2:7: curl makes one request for each URL, and this is not the first one
      #|  help: convert one request at a time; quote an argument that has spaces
    ),
  )
}

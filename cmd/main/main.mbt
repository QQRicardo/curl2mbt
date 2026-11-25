// The curl2mbt command: reads a curl command and prints the request it makes.

///|
let usage : String =
  #|Usage: curl2mbt curl ARG...
  #|       curl2mbt --text COMMAND
  #|       curl2mbt --file FILE
  #|
  #|Reads a curl command and prints the request it makes as JSON. Nothing is
  #|sent. A command that cannot be represented faithfully is rejected with
  #|every reason.
  #|
  #|  curl ARG...     the command as arguments; your shell has already read
  #|                  quotes and variables
  #|  --text COMMAND  the command as the text a POSIX shell or bash reads;
  #|                  "$NAME" stays a reference to an environment variable
  #|  --file FILE     like --text, with the text in a UTF-8 file
  #|  --help          print this help
  #|
  #|Exit status: 0 if the request is printed, 1 if the command is rejected, 2
  #|if the arguments of curl2mbt itself are wrong.

///|
/// The outcome of a run: what to print, and the exit status.
priv struct Outcome {
  output : String
  status : Int32
}

///|
fn usage_error(message : String) -> Outcome {
  { output: "error: \{message}\n\n\{usage}", status: 2, }
}

///|
fn severity_name(severity : @curl2mbt.Severity) -> String {
  match severity {
    Error => "error"
    Warning => "warning"
    Note => "note"
  }
}

///|
fn diagnostic_to_json(found : @curl2mbt.Diagnostic) -> Json {
  let out : Map[String, Json] = {
    "severity": Json::string(severity_name(found.severity)),
    "code": Json::string(found.code),
    "message": Json::string(found.message),
  }
  if found.help is Some(help) {
    out["help"] = Json::string(help)
  }
  match found.location {
    Some(Text(start~, end~)) => {
      out["start"] = Json::number(start.to_double())
      out["end"] = Json::number(end.to_double())
    }
    Some(Argument(index)) => out["argument"] = Json::number(index.to_double())
    None => ()
  }
  Json::object(out)
}

///|
fn accepted(parsed : @curl2mbt.Parsed) -> Outcome {
  let json = Json::object({
    "plan": parsed.plan.to_json(),
    "diagnostics": Json::array(parsed.diagnostics.map(diagnostic_to_json)),
  })
  { output: json.stringify(indent=2) + "\n", status: 0, }
}

///|
fn rejected(
  found : Array[@curl2mbt.Diagnostic],
  source? : StringView,
) -> Outcome {
  let lines = found.map(item => item.render(source?))
  { output: lines.join("\n") + "\n", status: 1, }
}

///|
fn run_text(text : String) -> Outcome {
  accepted(@curl2mbt.parse(text)) catch {
    CurlError(found) => rejected(found, source=text)
  }
}

///|
/// Runs the command with `arguments`, without the program name.
fn run(
  arguments : ArrayView[String],
  read_file : (String) -> String raise,
) -> Outcome {
  match arguments {
    [] => usage_error("there is no curl command")
    ["--help" | "-h"] => { output: usage, status: 0, }
    ["--text", text] => run_text(text)
    ["--file", path] => {
      let text = read_file(path) catch {
        _ => return usage_error("the file cannot be read as UTF-8 text")
      }
      run_text(
        match text.strip_prefix("\u{FEFF}") {
          Some(rest) => rest.to_owned()
          None => text
        },
      )
    }
    ["--text" | "--file", ..] =>
      usage_error("--text and --file take one argument")
    [first, ..] if first.has_prefix("-") =>
      usage_error("unknown option; options of curl come after the word curl")
    _ =>
      accepted(@curl2mbt.parse_argv(arguments)) catch {
        CurlError(found) => rejected(found)
      }
  }
}

///|
/// How many of the first arguments are the program: Node counts itself too.
#cfg(target="js")
let program_arguments : Int32 = 2

///|
#cfg(not(target="js"))
let program_arguments : Int32 = 1

///|
fn main {
  let arguments = @env.args()
  let skipped = arguments.length().min(program_arguments)
  let outcome = run(arguments[skipped:], path => @fs.read_file_to_string(path))
  println(outcome.output)
  if outcome.status != 0 {
    @env.exit(outcome.status)
  }
}

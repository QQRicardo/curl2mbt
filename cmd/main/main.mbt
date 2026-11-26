// The curl2mbt command: reads a curl command and prints a MoonBit program that
// makes the same request.

///|
let usage : String =
  #|Usage: curl2mbt [OPTIONS] curl ARG...
  #|       curl2mbt [OPTIONS] --text COMMAND
  #|       curl2mbt [OPTIONS] --file FILE
  #|
  #|Reads a curl command and prints a MoonBit program that makes the same
  #|request with moonbitlang/async. Nothing is sent. A command that cannot be
  #|reproduced faithfully is rejected with every reason.
  #|
  #|  curl ARG...       the command as arguments; your shell has already read
  #|                    quotes and variables
  #|  --text COMMAND    the command as the text a shell reads; "$NAME" stays a
  #|                    reference to an environment variable
  #|  --file FILE       like --text, with the text in a UTF-8 file
  #|  --shell SHELL     what reads the text: posix, a POSIX shell or bash, which
  #|                    is the default, or cmd, the prompt of Windows
  #|  --plan            print the request as JSON instead of a program
  #|  --to-curl SHELL   print the request as a curl command for SHELL, posix or
  #|                    cmd, instead of a program
  #|  --inline-secrets  write passwords, tokens and cookies into the program
  #|                    instead of reading them from environment variables
  #|  --help            print this help
  #|
  #|Exit status: 0 if there is a result, 1 if the command is rejected, 2 if the
  #|arguments of curl2mbt itself are wrong.

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
/// What to print for a command that was read.
priv struct Settings {
  plan : Bool
  to_curl : @curl2mbt.Shell?
  secrets : @curl2mbt.Secrets
  shell : @curl2mbt.Shell
}

///|
fn plan_output(parsed : @curl2mbt.Parsed) -> Outcome {
  let json = Json::object({
    "plan": parsed.plan.to_json(),
    "diagnostics": Json::array(parsed.diagnostics.map(diagnostic_to_json)),
  })
  { output: json.stringify(indent=2), status: 0, }
}

///|
fn rejected(
  found : Array[@curl2mbt.Diagnostic],
  source? : StringView,
) -> Outcome {
  let lines = found.map(item => item.render(source?))
  { output: lines.join("\n"), status: 1, }
}

///|
/// The program, after comments that say what it needs and what was noticed.
fn program_output(
  parsed : @curl2mbt.Parsed,
  secrets : @curl2mbt.Secrets,
  source? : StringView,
) -> Outcome {
  let emitted = parsed.plan.emit(secrets~) catch {
    EmitError(found) => return rejected(found)
  }
  let lines = [
    "// Needs moonbitlang/async 0.22: moon add moonbitlang/async", "// Imports for moon.pkg, with pkgtype(kind: \"executable\"):",
    "//   import {",
  ]
  for name in emitted.imports {
    lines.push("//     \"\{name}\",")
  }
  lines.push("//   }")
  if !emitted.environment.is_empty() {
    lines.push("// Environment variables: \{emitted.environment.join(", ")}")
  }
  let notes = parsed.diagnostics.map(item => item.render(source?)) +
    emitted.diagnostics.map(item => item.render())
  if !notes.is_empty() {
    lines.push("//")
    for note in notes {
      for line in note.split("\n") {
        lines.push("// \{line}")
      }
    }
  }
  lines.push("")
  lines.push(emitted.code.trim_end().to_owned())
  { output: lines.join("\n"), status: 0, }
}

///|
fn output(
  parsed : @curl2mbt.Parsed,
  settings : Settings,
  source? : StringView,
) -> Outcome {
  if settings.plan {
    plan_output(parsed)
  } else if settings.to_curl is Some(shell) {
    let text = parsed.plan.to_curl(shell~) catch {
      ToCurlError(message) =>
        return { output: "error[not-expressible]: \{message}", status: 1, }
    }
    { output: text, status: 0, }
  } else {
    program_output(parsed, settings.secrets, source?)
  }
}

///|
fn run_text(text : String, settings : Settings) -> Outcome {
  let parsed = @curl2mbt.parse(text, shell=settings.shell) catch {
    CurlError(found) => return rejected(found, source=text)
  }
  output(parsed, settings, source=text)
}

///|
/// Runs the command with `arguments`, without the program name.
fn run(
  arguments : ArrayView[String],
  read_file : (String) -> String raise,
) -> Outcome {
  let mut plan = false
  let mut to_curl : @curl2mbt.Shell? = None
  let mut secrets : @curl2mbt.Secrets = FromEnv
  let mut shell : @curl2mbt.Shell? = None
  let mut rest = arguments
  for ;; {
    match rest {
      ["--plan", .. more] => {
        plan = true
        rest = more
      }
      ["--inline-secrets", .. more] => {
        secrets = Inline
        rest = more
      }
      ["--shell", "posix", .. more] => {
        shell = Some(Posix)
        rest = more
      }
      ["--shell", "cmd", .. more] => {
        shell = Some(Cmd)
        rest = more
      }
      ["--shell", ..] => return usage_error("--shell takes posix or cmd")
      ["--to-curl", "posix", .. more] => {
        to_curl = Some(Posix)
        rest = more
      }
      ["--to-curl", "cmd", .. more] => {
        to_curl = Some(Cmd)
        rest = more
      }
      ["--to-curl", ..] => return usage_error("--to-curl takes posix or cmd")
      _ => break
    }
  }
  if plan && to_curl is Some(_) {
    return usage_error("--plan and --to-curl print different things")
  }
  let settings = Settings::{
    plan,
    to_curl,
    secrets,
    shell: shell.unwrap_or(Posix),
  }
  match rest {
    [] => usage_error("there is no curl command")
    ["--help" | "-h"] => { output: usage, status: 0, }
    ["--text", text] => run_text(text, settings)
    ["--file", path] => {
      let text = read_file(path) catch {
        _ => return usage_error("the file cannot be read as UTF-8 text")
      }
      let text = match text.strip_prefix("\u{FEFF}") {
        Some(rest) => rest.to_owned()
        None => text
      }
      run_text(text, settings)
    }
    ["--text" | "--file", ..] =>
      usage_error("--text and --file take one argument, the last one")
    [first, ..] if first.has_prefix("-") =>
      usage_error("unknown option; options of curl come after the word curl")
    _ if shell is Some(_) =>
      usage_error(
        "--shell is for --text and --file; arguments have been read by your shell",
      )
    words => {
      let parsed = @curl2mbt.parse_argv(words) catch {
        CurlError(found) => return rejected(found)
      }
      output(parsed, settings)
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

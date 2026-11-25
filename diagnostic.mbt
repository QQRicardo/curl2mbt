///|
/// How serious a `Diagnostic` is.
#derive(Eq, Debug)
pub(all) enum Severity {
  /// The command cannot be represented faithfully, so there is no plan.
  Error
  /// The plan is usable, but the command probably does not do what it seems.
  Warning
  /// Something in the command does not change the request.
  Note
}

///|
/// Where in the input a `Diagnostic` applies.
#derive(Eq, Debug)
pub(all) enum Location {
  /// UTF-16 offsets into the text given to `parse`, end excluded.
  Text(start~ : Int32, end~ : Int32)
  /// The index of an argument given to `parse_argv`.
  Argument(Int32)
}

///|
/// One finding about a command. The message never repeats the value of an
/// option, because values hold passwords and tokens.
#derive(Eq, Debug)
pub struct Diagnostic {
  severity : Severity
  /// A stable identifier of the kind of finding, such as `unknown-option`.
  code : String
  message : String
  /// What to do about it, if anything.
  help : String?
  /// `None` if the finding is about the command as a whole.
  location : Location?
}

///|
/// The command was rejected. Holds every finding, errors and others, in the
/// order of the input; at least one is an error.
#derive(Debug)
pub suberror CurlError {
  CurlError(Array[Diagnostic])
}

///|
impl Show for Severity with fn output(self, logger) {
  logger.write_string(
    match self {
      Error => "error"
      Warning => "warning"
      Note => "note"
    },
  )
}

///|
/// The line and column of `offset` in `text`, both counted from 1. Columns
/// count UTF-16 code units.
fn line_and_column(text : StringView, offset : Int32) -> (Int32, Int32) {
  let mut line = 1
  let mut column = 1
  for i in 0..<offset.min(text.length()) {
    if text[i] == '\n' {
      line += 1
      column = 1
    } else {
      column += 1
    }
  }
  (line, column)
}

///|
/// The finding as one line, or two with help. `source` is the text given to
/// `parse`: with it the place is shown as `line:column`, else as an offset.
pub fn Diagnostic::render(self : Diagnostic, source? : StringView) -> String {
  let buf = StringBuilder()
  buf.write_string("\{self.severity}[\{self.code}]")
  match (self.location, source) {
    (Some(Text(start~, ..)), Some(source)) => {
      let (line, column) = line_and_column(source, start)
      buf.write_string(" at \{line}:\{column}")
    }
    (Some(Text(start~, ..)), None) => buf.write_string(" at offset \{start}")
    (Some(Argument(index)), _) => buf.write_string(" at argument \{index}")
    (None, _) => ()
  }
  buf.write_string(": \{self.message}")
  if self.help is Some(help) {
    buf.write_string("\n  help: \{help}")
  }
  buf.to_string()
}

///|
/// Collects the findings about one command.
priv struct Report {
  found : Array[Diagnostic]
}

///|
fn Report::add(
  self : Report,
  severity : Severity,
  code : String,
  message : String,
  help? : String,
  location? : Location,
) -> Unit {
  self.found.push({ severity, code, message, help, location, })
}

///|
fn Report::error(
  self : Report,
  code : String,
  message : String,
  help? : String,
  location? : Location,
) -> Unit {
  self.add(Error, code, message, help?, location?)
}

///|
fn Report::has_errors(self : Report) -> Bool {
  self.found.iter().any(found => found.severity is Error)
}

///|
/// The findings in the order of the input, those about the whole command
/// last.
fn Report::sorted(self : Report) -> Array[Diagnostic] {
  fn key(found : Diagnostic) -> Int32 {
    match found.location {
      Some(Text(start~, ..)) => start
      Some(Argument(index)) => index
      None => 0x7FFFFFFF
    }
  }

  let keyed = self.found.mapi((i, found) => (key(found), i, found))
  keyed.sort_by((a, b) => {
    if a.0 == b.0 {
      a.1.compare(b.1)
    } else {
      a.0.compare(b.0)
    }
  })
  keyed.map(entry => entry.2)
}

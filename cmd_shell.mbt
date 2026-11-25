///|
/// What cmd.exe passes on: a character or a variable, and where it starts and
/// ends in the text.
priv struct CmdItem {
  what : CmdWhat
  start : Int32
  end : Int32
}

///|
priv enum CmdWhat {
  Plain(Char)
  Variable(String)
}

///|
/// Reads one command the way it works at the prompt of cmd.exe: variables are
/// replaced first, then cmd.exe handles carets and its own quotes, and at last
/// curl.exe splits what is left into arguments as programs for Windows do.
priv struct CmdReader {
  text : StringView
  mut pos : Int32
  report : Report
  items : Array[CmdItem]
  /// Whether cmd.exe is between quotes.
  mut quoted : Bool
  mut warned_percent : Bool
  mut warned_variable : Bool
}

///|
fn cmd_words(text : StringView, report : Report) -> Array[Word] {
  let reader = CmdReader::{
    text,
    pos: 0,
    report,
    items: [],
    quoted: false,
    warned_percent: false,
    warned_variable: false,
  }
  if reader.read_line() {
    split_cmd_items(reader.items, report)
  } else {
    []
  }
}

///|
fn CmdReader::peek(self : CmdReader, ahead~ : Int32 = 0) -> UInt16? {
  self.text.get(self.pos + ahead)
}

///|
/// The length of the line break `ahead` of the position, or 0.
fn CmdReader::line_break(self : CmdReader, ahead~ : Int32 = 0) -> Int32 {
  match (self.peek(ahead~), self.peek(ahead=ahead + 1)) {
    (Some('\n'), _) => 1
    (Some('\r'), Some('\n')) => 2
    _ => 0
  }
}

///|
fn CmdReader::fail(
  self : CmdReader,
  message : String,
  help? : String,
  start~ : Int32,
  end~ : Int32,
) -> Unit {
  self.report.error("shell-syntax", message, help?, location=Text(start~, end~))
}

///|
/// Adds the character at the position, whatever it is.
fn CmdReader::take(self : CmdReader) -> Unit {
  let start = self.pos
  match self.text.get_char(start) {
    Some(char) => {
      self.pos += char.utf16_len()
      self.items.push({ what: Plain(char), start, end: self.pos, })
    }
    None => {
      self.pos += 1
      self.fail(
        "half of a surrogate pair is not a character",
        start~,
        end=self.pos,
      )
    }
  }
}

///|
/// Reads the command, up to the end of its line. Returns whether there is one
/// that can be split.
fn CmdReader::read_line(self : CmdReader) -> Bool {
  // Blank lines may come before the command.
  while self.peek() is Some(' ' | '\t' | '\r' | '\n') {
    self.pos += 1
  }
  for ;; {
    guard self.peek() is Some(unit) else { break }
    if self.line_break() > 0 {
      break
    }
    if unit is ('\u0000' | '\r' | '\u001A') {
      self.fail(
        "a control character of this kind is not supported in a command for cmd",
        start=self.pos,
        end=self.pos + 1,
      )
      return false
    }
    match unit {
      '%' => self.read_percent()
      '"' => {
        self.quoted = !self.quoted
        self.take()
      }
      '^' if !self.quoted => if !self.read_caret() { return false }
      '&' | '|' | '<' | '>' if !self.quoted => {
        self.fail(
          match unit {
            '|' =>
              "a pipe or another command after it is not part of the request"
            '&' => "another command after & is not part of the request"
            _ => "a redirection is not part of the request"
          },
          help="keep only the curl command; in an argument, quote the character or put a ^ before it",
          start=self.pos,
          end=self.pos + 1,
        )
        return false
      }
      _ => self.take()
    }
  }
  // Only blank lines may come after it.
  while self.peek() is Some(' ' | '\t' | '\r' | '\n') {
    self.pos += 1
  }
  if self.peek() is Some(_) {
    self.report.error(
      "several-commands",
      "there is a second command after the first one",
      help="convert one command at a time; a command that goes on in the next line needs a ^ at the end of the line, outside quotes",
      location=Text(start=self.pos, end=self.pos + 1),
    )
    return false
  }
  true
}

///|
/// Reads a `^` outside quotes: what comes next is taken as it is. At the end
/// of a line that is the first character of the next one.
fn CmdReader::read_caret(self : CmdReader) -> Bool {
  let start = self.pos
  self.pos += 1
  let skipped = self.line_break()
  self.pos += skipped
  match self.peek() {
    None => {
      self.fail(
        "a ^ at the end makes the command go on, but there is nothing more",
        help="remove it",
        start~,
        end=self.pos,
      )
      false
    }
    Some('%') => {
      // Variables have been replaced before carets have a meaning.
      self.read_percent()
      true
    }
    Some(_) => {
      let length = self.line_break()
      if length > 0 {
        self.items.push({
          what: Plain('\n'),
          start: self.pos,
          end: self.pos + length,
        })
        self.pos += length
      } else {
        if self.peek() is Some('\u0000' | '\r' | '\u001A') {
          self.fail(
            "a control character of this kind is not supported in a command for cmd",
            start=self.pos,
            end=self.pos + 1,
          )
          return false
        }
        self.take()
      }
      true
    }
  }
}

///|
/// Variables that cmd.exe computes.
let cmd_computed : Array[String] = [
  "cd", "cmdcmdline", "cmdextversion", "date", "errorlevel", "highestnumanodenumber",
  "random", "time",
]

///|
/// Reads the `%` at the position: the start of `%NAME%`, or a character like
/// others. At the prompt, what is not the name of a variable stays as it is.
fn CmdReader::read_percent(self : CmdReader) -> Unit {
  let start = self.pos
  let mut end = start + 1
  while self.text.get(end) is Some(unit) && !(unit is ('%' | '\n' | '\r')) {
    end += 1
  }
  guard self.text.get(end) is Some('%') else {
    self.take()
    return
  }
  let inside = self.text[start + 1:end].to_owned()
  let name = match inside.find(":") {
    Some(at) => inside[:at].to_owned()
    None => inside
  }
  if inside == "" {
    if !self.warned_percent {
      self.warned_percent = true
      self.report.add(
        Warning,
        "batch-percent",
        "%% is taken literally, as at the prompt; in a batch file it means one %",
        location=Text(start~, end=start + 2),
      )
    }
    self.take()
    return
  }
  let units = name.code_units()
  if cmd_computed.contains(name.to_lower()) {
    self.fail(
      "the value of %\{name}% is computed by cmd and not known here",
      start~,
      end=end + 1,
    )
    self.pos = end + 1
    return
  }
  if units.is_empty() ||
    !is_name_start(units[0]) ||
    !units.iter().all(is_name_part) {
    self.take()
    return
  }
  // %C3%A9 in a URL is no variable.
  if units is [first, second, ..] &&
    hex_digit(first) is Some(_) &&
    hex_digit(second) is Some(_) {
    if units.length() > 2 {
      self.report.add(
        Warning,
        "percent-not-variable",
        "this is taken for percent-encoding and not for the variable \{name}",
        location=Text(start~, end=end + 1),
      )
    }
    self.take()
    return
  }
  if name != inside {
    self.fail(
      "only the plain form %NAME% of a variable is supported",
      start~,
      end=end + 1,
    )
    self.pos = end + 1
    return
  }
  if !self.warned_variable {
    self.warned_variable = true
    self.report.add(
      Warning,
      "cmd-variable",
      "the value of a variable is used as it is, while cmd would give a meaning to quotes, & and other characters in it",
      location=Text(start~, end=end + 1),
    )
  }
  self.items.push({ what: Variable(name), start, end: end + 1, })
  self.pos = end + 1
}

///|
/// Splits what cmd.exe passes on into arguments, by the rules of the C
/// runtime of Microsoft.
fn split_cmd_items(items : Array[CmdItem], report : Report) -> Array[Word] {
  let words : Array[Word] = []
  let mut i = 0
  let mut warned_encoding = false
  fn plain(at : Int32) -> Char? {
    match items.get(at) {
      Some({ what: Plain(char), .. }) => Some(char)
      _ => None
    }
  }

  for ;; {
    while plain(i) is Some(' ' | '\t') {
      i += 1
    }
    guard items.get(i) is Some(first) else { return words }
    let is_program = words.is_empty()
    let pieces : Array[Piece] = []
    let literal = StringBuilder()
    fn flush() {
      let text = literal.to_string()
      if text != "" {
        pieces.push(Literal(@utf8.encode(text)))
        literal.reset()
      }
    }

    let mut open : CmdItem? = None
    let mut last = first
    if first.what is Plain('\'') {
      report.add(
        Warning,
        "single-quote",
        "' is a character like others to cmd, so this does not start a quoted argument",
        help="if the command is for bash, read it as such",
        location=Text(start=first.start, end=first.end),
      )
    }
    while items.get(i) is Some(item) {
      if item.what is Plain(' ' | '\t') && open is None {
        break
      }
      last = item
      match item.what {
        Plain('\\') if !is_program => {
          let mut count = 0
          while plain(i) is Some('\\') {
            last = items[i]
            count += 1
            i += 1
          }
          if plain(i) is Some('"') {
            literal.write_string("\\".repeat(count / 2))
            if count % 2 == 1 {
              literal.write_char('"')
              last = items[i]
              i += 1
            }
          } else {
            literal.write_string("\\".repeat(count))
          }
          continue
        }
        Plain('"') =>
          match open {
            None => open = Some(item)
            Some(_) => {
              if plain(i + 1) is Some('"') {
                report.error(
                  "shell-syntax",
                  "programs for Windows disagree about two quotes in a row inside quotes",
                  help="write \\\" for a quote in an argument",
                  location=Text(start=item.start, end=items[i + 1].end),
                )
              }
              open = None
            }
          }
        Plain(char) => {
          if char is ('*' | '?') && open is None {
            report.add(
              Warning,
              "unquoted-pattern",
              "unquoted \{char} is a file name pattern to some builds of curl; it is taken literally here",
              help="quote the argument",
              location=Text(start=item.start, end=item.end),
            )
          }
          if char > '\u007F' && !warned_encoding {
            warned_encoding = true
            report.add(
              Warning,
              "code-page",
              "curl for Windows may send characters outside ASCII in the code page of the system; here they are UTF-8",
              location=Text(start=item.start, end=item.end),
            )
          }
          literal.write_char(char)
        }
        Variable(name) => {
          if open is None {
            report.error(
              "unquoted-variable",
              "an unquoted variable can become several arguments",
              help="write \"%\{name}%\" inside double quotes",
              location=Text(start=item.start, end=item.end),
            )
          }
          flush()
          pieces.push(Env(name))
        }
      }
      i += 1
    }
    if open is Some(item) {
      report.error(
        "unterminated-quote",
        "the double quote that starts here is not closed",
        location=Text(start=item.start, end=item.end),
      )
    }
    flush()
    words.push({
      value: Value::from_pieces(pieces),
      location: Text(start=first.start, end=last.end),
    })
  }
}

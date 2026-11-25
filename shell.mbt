///|
/// A word of a command line: one argument of the program.
priv struct Word {
  value : Value
  location : Location
}

///|
/// Reads one simple command as a POSIX shell or bash splits it into words.
/// Whatever the shell would compute (substitutions, unquoted variables,
/// pipelines, ...) is reported instead.
priv struct PosixReader {
  text : StringView
  mut pos : Int32
  report : Report
  words : Array[Word]
  /// The word being read, and where it starts.
  pieces : Array[Piece]
  literal : StringBuilder
  /// Whether the rest cannot be read.
  mut stopped : Bool
}

///|
fn posix_words(text : StringView, report : Report) -> Array[Word] {
  let reader = PosixReader::{
    text,
    pos: 0,
    report,
    words: [],
    pieces: [],
    literal: StringBuilder(),
    stopped: false,
  }
  reader.read()
  reader.words
}

///|
/// The code unit `ahead` of the position.
fn PosixReader::peek(self : PosixReader, ahead~ : Int32 = 0) -> UInt16? {
  self.text.get(self.pos + ahead)
}

///|
/// The length of the line break `ahead` of the position, or 0. CR LF counts
/// as one, because commands get copied through Windows editors.
fn PosixReader::line_break(self : PosixReader, ahead~ : Int32 = 0) -> Int32 {
  match (self.peek(ahead~), self.peek(ahead=ahead + 1)) {
    (Some('\n'), _) => 1
    (Some('\r'), Some('\n')) => 2
    _ => 0
  }
}

///|
fn PosixReader::fail(
  self : PosixReader,
  code : String,
  message : String,
  help? : String,
  start~ : Int32,
  end~ : Int32 = self.pos,
) -> Unit {
  self.report.error(code, message, help?, location=Text(start~, end~))
}

///|
/// Adds what has been read of the current literal to the word.
fn PosixReader::flush(self : PosixReader) -> Unit {
  let text = self.literal.to_string()
  if text != "" {
    self.pieces.push(Literal(@utf8.encode(text)))
    self.literal.reset()
  }
}

///|
fn PosixReader::push_bytes(self : PosixReader, bytes : Bytes) -> Unit {
  self.flush()
  self.pieces.push(Literal(bytes))
}

///|
/// Adds the character at the position to the word.
fn PosixReader::take(self : PosixReader) -> Unit {
  match self.text.get_char(self.pos) {
    Some(char) => {
      self.literal.write_char(char)
      self.pos += char.utf16_len()
    }
    None => {
      self.fail(
        "shell-syntax",
        "half of a surrogate pair is not a character",
        start=self.pos,
        end=self.pos + 1,
      )
      self.pos += 1
    }
  }
}

///|
fn is_name_start(unit : UInt16) -> Bool {
  unit is ('A'..<='Z' | 'a'..<='z' | '_')
}

///|
fn is_name_part(unit : UInt16) -> Bool {
  is_name_start(unit) || unit is ('0'..<='9')
}

///|
/// Skips blanks, continued lines and a comment. Returns whether a line break
/// that ends the command, or the end of the text, comes next.
fn PosixReader::skip_blanks(self : PosixReader) -> Bool {
  for ;; {
    match self.peek() {
      None => return true
      Some(' ' | '\t') => self.pos += 1
      Some('\\') if self.line_break(ahead=1) > 0 =>
        self.pos += 1 + self.line_break(ahead=1)
      Some('#') => {
        while self.peek() is Some(_) && self.line_break() == 0 {
          self.pos += 1
        }
        return true
      }
      _ => return self.line_break() > 0
    }
  }
}

///|
fn PosixReader::read(self : PosixReader) -> Unit {
  // Blank lines and comments may come before the command.
  while self.skip_blanks() {
    let length = self.line_break()
    if length == 0 {
      return
    }
    self.pos += length
  }
  while !self.stopped && !self.skip_blanks() {
    self.read_word()
  }
  if self.stopped {
    return
  }
  // Only blank lines and comments may come after it.
  for ;; {
    let length = self.line_break()
    if length > 0 {
      self.pos += length
    } else if self.peek() is None {
      return
    }
    if !self.skip_blanks() {
      let start = self.pos
      self.fail(
        "several-commands",
        "there is a second command after the first one",
        help="convert one command at a time; a command that goes on in the next line needs a \\ at the end of the line",
        start~,
        end=start + 1,
      )
      return
    }
  }
}

///|
/// The operators that end a word, with what they do.
fn operator_at(reader : PosixReader) -> (Int32, String)? {
  match (reader.peek(), reader.peek(ahead=1)) {
    (Some('|'), Some('|')) => Some((2, "another command after ||"))
    (Some('|'), _) => Some((1, "a pipeline"))
    (Some('&'), Some('&')) => Some((2, "another command after &&"))
    (Some('&'), _) => Some((1, "a background command"))
    (Some(';'), _) => Some((1, "another command after ;"))
    (Some('<'), _) => Some((1, "an input redirection"))
    (Some('>'), _) => Some((1, "an output redirection"))
    (Some('('), _) => Some((1, "a subshell"))
    (Some(')'), _) => Some((1, "a subshell"))
    _ => None
  }
}

///|
/// Whether only blanks, line breaks and comments follow the position.
fn PosixReader::only_blanks_follow(self : PosixReader) -> Bool {
  let saved = self.pos
  let mut result = false
  while self.skip_blanks() {
    let length = self.line_break()
    if length == 0 {
      result = true
      break
    }
    self.pos += length
  }
  self.pos = saved
  result
}

///|
fn PosixReader::read_word(self : PosixReader) -> Unit {
  let start = self.pos
  self.pieces.clear()
  let mut is_word = false
  for ;; {
    guard self.peek() is Some(unit) else { break }
    if unit is (' ' | '\t') || self.line_break() > 0 {
      break
    }
    if operator_at(self) is Some((length, what)) {
      let at = self.pos
      self.pos += length
      if unit is ';' && self.only_blanks_follow() {
        break
      }
      self.fail(
        "shell-syntax",
        "\{what} is not part of the request",
        help="keep only the curl command",
        start=at,
      )
      self.stopped = true
      break
    }
    is_word = true
    match unit {
      '\'' => self.read_single_quoted()
      '"' => self.read_double_quoted()
      '\\' =>
        if self.line_break(ahead=1) > 0 {
          self.pos += 1 + self.line_break(ahead=1)
        } else if self.peek(ahead=1) is Some(_) {
          self.pos += 1
          self.take()
        } else {
          self.pos += 1
          self.fail(
            "shell-syntax",
            "a backslash at the end does not escape anything",
            start=self.pos - 1,
          )
        }
      '$' =>
        match self.peek(ahead=1) {
          Some('\'') => self.read_ansi_c_quoted()
          Some('"') => {
            self.fail(
              "shell-syntax",
              "a string that bash translates ($\"...\") is not supported",
              help="remove the $ before the quote",
              start=self.pos,
              end=self.pos + 2,
            )
            self.pos += 1
          }
          _ => self.read_dollar(quoted=false)
        }
      '`' => self.read_substitution()
      '~' if self.pos == start || self.text[self.pos - 1] is ('=' | ':') => {
        self.fail(
          "shell-syntax",
          "the shell replaces ~ with a home directory",
          help="write the path out, or quote the ~",
          start=self.pos,
          end=self.pos + 1,
        )
        self.pos += 1
      }
      '*' | '?' | '[' => {
        self.report.add(
          Warning,
          "unquoted-pattern",
          "unquoted \{unit.unsafe_to_char()} is a file name pattern to the shell; it is taken literally here",
          help="quote the argument",
          location=Text(start=self.pos, end=self.pos + 1),
        )
        self.take()
      }
      '{' if self.is_brace_expansion() => {
        self.fail(
          "shell-syntax",
          "bash expands unquoted braces into several arguments",
          help="quote the argument",
          start=self.pos,
          end=self.pos + 1,
        )
        self.pos += 1
      }
      _ => self.take()
    }
    if self.stopped {
      break
    }
  }
  self.flush()
  if is_word {
    self.words.push({
      value: Value::from_pieces(self.pieces.copy()),
      location: Text(start~, end=self.pos),
    })
  }
}

///|
/// Whether the `{` at the position starts a bash brace expansion.
fn PosixReader::is_brace_expansion(self : PosixReader) -> Bool {
  for i = 1; ; i = i + 1 {
    match self.peek(ahead=i) {
      None | Some(' ' | '\t' | '\n' | '\r' | '}') => return false
      Some(',') => return true
      Some('.') if self.peek(ahead=i + 1) is Some('.') => return true
      _ => ()
    }
  }
}

///|
fn PosixReader::unterminated(
  self : PosixReader,
  what : String,
  start : Int32,
) -> Unit {
  self.fail(
    "unterminated-quote",
    "the \{what} that starts here is not closed",
    start~,
    end=start + 1,
  )
  self.stopped = true
}

///|
fn PosixReader::reject_nul(self : PosixReader) -> Unit {
  self.fail(
    "shell-syntax",
    "a NUL character cannot be part of an argument",
    start=self.pos,
    end=self.pos + 1,
  )
  self.pos += 1
}

///|
fn PosixReader::read_single_quoted(self : PosixReader) -> Unit {
  let start = self.pos
  self.pos += 1
  for ;; {
    match self.peek() {
      None => {
        self.unterminated("single quote", start)
        return
      }
      Some('\'') => {
        self.pos += 1
        return
      }
      Some('\u0000') => self.reject_nul()
      _ => self.take()
    }
  }
}

///|
fn PosixReader::read_double_quoted(self : PosixReader) -> Unit {
  let start = self.pos
  self.pos += 1
  while !self.stopped {
    match self.peek() {
      None => {
        self.unterminated("double quote", start)
        return
      }
      Some('"') => {
        self.pos += 1
        return
      }
      Some('\\') =>
        if self.line_break(ahead=1) > 0 {
          self.pos += 1 + self.line_break(ahead=1)
        } else if self.peek(ahead=1) is Some('$' | '`' | '"' | '\\') {
          self.pos += 1
          self.take()
        } else {
          self.take()
        }
      Some('$') => self.read_dollar(quoted=true)
      Some('`') => self.read_substitution()
      Some('\u0000') => self.reject_nul()
      _ => self.take()
    }
  }
}

///|
/// A command substitution can contain anything, so reading stops.
fn PosixReader::read_substitution(self : PosixReader) -> Unit {
  let start = self.pos
  self.pos += 1
  self.fail(
    "shell-syntax",
    "the output of a command is not known here",
    help="put the value in an environment variable and write \"$NAME\"",
    start~,
  )
  self.stopped = true
}

///|
/// A shell joins continued lines before it looks at what follows a `$`.
fn PosixReader::continued_variable(self : PosixReader, start : Int32) -> Unit {
  self.fail(
    "shell-syntax",
    "a line that is continued inside a variable is not supported",
    help="write the variable on one line",
    start~,
    end=start + 1,
  )
  self.stopped = true
}

///|
/// Reads what starts with the `$` at the position, outside or inside double
/// quotes. Only `$NAME` and `${NAME}` inside double quotes are kept.
fn PosixReader::read_dollar(self : PosixReader, quoted~ : Bool) -> Unit {
  let start = self.pos
  match self.peek(ahead=1) {
    Some('\\') if self.line_break(ahead=2) > 0 => {
      self.continued_variable(start)
      return
    }
    Some('(') => {
      self.read_substitution()
      return
    }
    Some('{') => self.pos += 2
    Some(unit) if is_name_start(unit) => self.pos += 1
    Some('0'..<='9' | '@' | '*' | '#' | '?' | '$' | '!' | '-') => {
      self.pos += 2
      self.fail(
        "shell-syntax",
        "a special parameter of the shell is not known here",
        help="write the value out, or quote the $ with single quotes",
        start~,
      )
      return
    }
    _ => {
      self.take()
      return
    }
  }
  let braced = self.pos == start + 2
  let name_start = self.pos
  while self.peek() is Some(unit) && is_name_part(unit) {
    self.pos += 1
  }
  let name = self.text[name_start:self.pos].to_owned()
  if self.peek() is Some('\\') && self.line_break(ahead=1) > 0 {
    self.continued_variable(start)
    return
  }
  if braced {
    if self.peek() is Some('}') &&
      name != "" &&
      self.text[name_start] is unit &&
      is_name_start(unit) {
      self.pos += 1
    } else {
      self.fail(
        "shell-syntax",
        "only the plain form ${NAME} of a parameter expansion is supported",
        start~,
      )
      self.stopped = true
      return
    }
  }
  if quoted {
    self.flush()
    self.pieces.push(Env(name))
  } else {
    self.fail(
      "unquoted-variable",
      "the shell splits an unquoted variable into several arguments",
      help="write \"$\{name}\" inside double quotes",
      start~,
    )
  }
}

///|
fn hex_digit(unit : UInt16) -> Int32? {
  match unit {
    '0'..<='9' => Some(unit.to_int() - '0')
    'a'..<='f' => Some(unit.to_int() - 'a' + 10)
    'A'..<='F' => Some(unit.to_int() - 'A' + 10)
    _ => None
  }
}

///|
/// Reads up to `max` digits in `base` at the position.
fn PosixReader::digits(self : PosixReader, base : Int32, max : Int32) -> Int64? {
  let mut value = 0L
  let start = self.pos
  while self.pos < start + max &&
        self.peek() is Some(unit) &&
        hex_digit(unit) is Some(digit) &&
        digit < base {
    value = value * base.to_int64() + digit.to_int64()
    self.pos += 1
  }
  if self.pos > start {
    Some(value)
  } else {
    None
  }
}

///|
/// Reads a `$'...'` string. Its escapes are those of bash.
fn PosixReader::read_ansi_c_quoted(self : PosixReader) -> Unit {
  let start = self.pos
  self.pos += 2
  for ;; {
    match self.peek() {
      None => {
        self.unterminated("quote", start)
        return
      }
      Some('\'') => {
        self.pos += 1
        return
      }
      Some('\\') => self.read_ansi_c_escape()
      Some('\u0000') => self.reject_nul()
      _ => self.take()
    }
  }
}

///|
/// Adds the byte `value`, which must not be NUL: bash ends the string there.
fn PosixReader::push_byte(
  self : PosixReader,
  value : Int64,
  start : Int32,
) -> Unit {
  let byte = (value & 0xFFL).to_int().to_byte()
  if byte == 0 {
    self.fail(
      "shell-syntax",
      "a NUL character cannot be part of an argument",
      start~,
    )
  } else {
    self.push_bytes([byte])
  }
}

///|
fn PosixReader::read_ansi_c_escape(self : PosixReader) -> Unit {
  let start = self.pos
  self.pos += 1
  guard self.peek() is Some(unit) else { return self.literal.write_char('\\') }
  fn simple(value : Int32) -> Unit {
    self.pos += 1
    self.push_bytes([value.to_byte()])
  }

  match unit {
    'a' => simple(0x07)
    'b' => simple(0x08)
    'e' | 'E' => simple(0x1B)
    'f' => simple(0x0C)
    'n' => simple(0x0A)
    'r' => simple(0x0D)
    't' => simple(0x09)
    'v' => simple(0x0B)
    '\\' | '\'' | '"' | '?' => self.take()
    '0'..<='7' => self.push_byte(self.digits(8, 3).unwrap_or(0), start)
    'x' => {
      self.pos += 1
      match self.digits(16, 2) {
        Some(value) => self.push_byte(value, start)
        None => self.literal.write_string("\\x")
      }
    }
    'u' | 'U' => {
      self.pos += 1
      match self.digits(16, if unit is 'u' { 4 } else { 8 }) {
        Some(value) => self.push_code_point(value, start)
        None => {
          self.literal.write_char('\\')
          self.literal.write_char(unit.unsafe_to_char())
        }
      }
    }
    'c' => {
      self.fail(
        "shell-syntax",
        "the escape \\c is not supported",
        help="write the control character as \\xHH",
        start~,
        end=start + 2,
      )
      self.pos += 1
    }
    _ => self.literal.write_char('\\')
  }
}

///|
/// Adds the character of a `\u` or `\U` escape that ends at the position.
/// Browsers write characters outside the BMP as two escapes, one for each
/// UTF-16 code unit.
fn PosixReader::push_code_point(
  self : PosixReader,
  value : Int64,
  start : Int32,
) -> Unit {
  if value == 0L {
    self.push_byte(0L, start)
    return
  }
  let code = if value is (0xD800L..<=0xDBFFL) &&
    self.peek() is Some('\\') &&
    self.peek(ahead=1) is Some('u') {
    let saved = self.pos
    self.pos += 2
    match self.digits(16, 4) {
      Some(low) if low is (0xDC00L..<=0xDFFFL) => {
        self.report.add(
          Warning,
          "surrogate-escapes",
          "bash would not join these two escapes; they are read as the one character a browser means by them",
          location=Text(start~, end=self.pos),
        )
        0x10000L + (value - 0xD800L) * 0x400L + (low - 0xDC00L)
      }
      _ => {
        self.pos = saved
        value
      }
    }
  } else {
    value
  }
  if code.to_int().to_char() is Some(char) && code <= 0x10FFFFL {
    self.literal.write_char(char)
  } else {
    self.fail(
      "shell-syntax",
      "the escape does not stand for a character",
      start~,
    )
  }
}

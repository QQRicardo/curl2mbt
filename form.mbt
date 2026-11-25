///|
/// A part of a multipart form.
#derive(Eq, Debug)
pub struct Part {
  name : String
  content : Value
  /// The file name the part gives.
  filename : String?
  /// The type the part gives.
  content_type : String?
}

///|
/// The type curl gives a file of this name.
fn type_of_file(name : String) -> String? {
  let name = name.to_lower()
  let types = [
    (".gif", "image/gif"),
    (".jpg", "image/jpeg"),
    (".jpeg", "image/jpeg"),
    (".png", "image/png"),
    (".svg", "image/svg+xml"),
    (".txt", "text/plain"),
    (".htm", "text/html"),
    (".html", "text/html"),
    (".pdf", "application/pdf"),
    (".xml", "application/xml"),
  ]
  for entry in types {
    if name.has_suffix(entry.0) {
      return Some(entry.1)
    }
  }
  None
}

///|
/// A type such as `text/plain`, without parameters.
fn is_media_type(text : String) -> Bool {
  match text.find("/") {
    Some(at) => is_token(text[:at]) && is_token(text[at + 1:])
    None => false
  }
}

///|
/// What curl strips from around words of a form.
fn is_form_space(char : Char) -> Bool {
  char is (' ' | '\t' | '\n' | '\r' | '\u000B' | '\u000C')
}

///|
/// The `-F` argument being read.
priv struct FormReader {
  text : String
  mut pos : Int32
}

///|
/// Reads a word up to a `;`, quoted or not. Fails for what curl would read
/// in a way that surprises.
fn FormReader::word(self : FormReader) -> String raise FormError {
  let start = self.pos
  if self.text.get(start) is Some('"') {
    let out = StringBuilder()
    self.pos += 1
    for ;; {
      match self.text.get_char(self.pos) {
        None =>
          raise FormError(
            message="a quoted word of the form is not closed",
            help="close it, or use --form-string for text that is taken as it is",
          )
        Some('"') => break
        Some('\\') if self.text.get(self.pos + 1) is Some('"' | '\\') => {
          out.write_char(self.text.get_char(self.pos + 1).unwrap())
          self.pos += 2
        }
        Some(char) => {
          out.write_char(char)
          self.pos += char.utf16_len()
        }
      }
    }
    self.pos += 1
    if !(self.text.get(self.pos) is (None | Some(';'))) {
      raise FormError(
        message="curl ignores what follows a quoted word of a form",
        help="use --form-string for text that is taken as it is",
      )
    }
    return out.to_string()
  }
  while self.text.get(self.pos) is Some(unit) && unit != ';' {
    self.pos += 1
  }
  let word = self.text[start:self.pos].to_owned()
  let chars = word.to_array()
  if chars is [first, ..] &&
    (is_form_space(first) || is_form_space(chars[chars.length() - 1])) {
    raise FormError(
      message="curl removes blanks around a word of a form",
      help="quote the word as \"...\" to keep the blanks, or remove them",
    )
  }
  word
}

///|
/// Why a `-F` argument is not supported.
priv suberror FormError {
  FormError(message~ : String, help~ : String)
}

///|
/// The part that the `-F` argument `text` stands for, without its name.
/// `windows` is whether `\` separates the parts of a path.
fn read_form_part(
  name : String,
  text : String,
  windows~ : Bool,
) -> Part raise FormError {
  let reader = FormReader::{ text, pos: 0, }
  let kind = match text.get(0) {
    Some('@' | '<' as unit) => {
      reader.pos = 1
      Some(unit)
    }
    _ => None
  }
  if text.get(0) is Some('(' | ')') || text == "=)" {
    raise FormError(
      message="parts inside parts are not supported",
      help="use --form-string for text that is taken as it is",
    )
  }
  let quoted = text.get(reader.pos) is Some('"')
  let word = reader.word()
  if kind is Some(_) {
    if word == "" {
      raise FormError(
        message="there is no name of a file",
        help="write name=@FILE",
      )
    }
    if base_name(word, windows~) is ("" | "." | "..") {
      raise FormError(
        message="what the part names is a directory",
        help="name a file",
      )
    }
    if word == "-" {
      raise FormError(
        message="reading the standard input is not supported",
        help="name a file",
      )
    }
    if word.contains("\u0000") {
      raise FormError(
        message="the name of the file has a NUL",
        help="remove it",
      )
    }
    if !quoted && word.contains(",") {
      raise FormError(
        message="several files in one part are not supported",
        help="use -F once for each file; quote a name that has a comma",
      )
    }
  }
  let mut filename : String? = None
  let mut content_type : String? = None
  while reader.text.get(reader.pos) is Some(';') {
    reader.pos += 1
    while reader.text.get(reader.pos) is Some(' ') {
      reader.pos += 1
    }
    let rest = reader.text[reader.pos:]
    if rest.has_prefix("type=") && content_type is None {
      reader.pos += 5
      let word = reader.word()
      if !is_media_type(word) {
        raise FormError(
          message="the type of a part must be like text/plain",
          help="write ;type=TYPE/SUBTYPE, unquoted and without parameters",
        )
      }
      content_type = Some(word)
    } else if rest.has_prefix("filename=") && filename is None {
      reader.pos += 9
      let word = reader.word()
      if word == "" {
        raise FormError(
          message="an empty file name is not supported",
          help="leave ;filename= out",
        )
      }
      filename = Some(word)
    } else {
      raise FormError(
        message="only ;type= and ;filename= are supported after the content, each once",
        help="curl gives ; a meaning; quote content as \"...\" or use --form-string for text that is taken as it is",
      )
    }
  }
  match kind {
    None => {
      if content_type is None && filename is Some(filename) {
        content_type = type_of_file(filename)
      }
      { name, content: Value::literal(word), filename, content_type, }
    }
    Some(unit) => {
      let content = Value::from_pieces([File(path=word, read=Whole)])
      if unit == '<' {
        if filename is Some(_) {
          raise FormError(
            message="curl ignores the file name of a part that is made with <",
            help="use @ instead of <, or remove ;filename=",
          )
        }
        if content_type is None {
          content_type = match type_of_file(word) {
            Some("text/plain") => None
            found => found
          }
        }
        return { name, content, filename: None, content_type, }
      }
      let filename = match filename {
        Some(filename) => filename
        None => {
          if !windows && word.contains("\\") {
            raise FormError(
              message="whether \\ separates the parts of a path depends on the system",
              help="write ;filename=NAME after the path",
            )
          }
          base_name(word, windows~)
        }
      }
      if content_type is None {
        content_type = match type_of_file(filename) {
          Some(found) => Some(found)
          None =>
            match type_of_file(word) {
              Some(found) => Some(found)
              None => Some("application/octet-stream")
            }
        }
      }
      { name, content, filename: Some(filename), content_type, }
    }
  }
}

///|
/// The last part of a path.
fn base_name(path : String, windows~ : Bool) -> String {
  let units = path.code_units()
  let mut start = 0
  for i in 0..<units.length() {
    if units[i] == '/' || (windows && units[i] == '\\') {
      start = i + 1
    }
  }
  path[start:].to_owned()
}

///|
/// The header fields of the part, as curl writes them: line breaks and quotes
/// in names are percent-encoded.
fn Part::header_text(self : Part) -> String {
  fn escape(text : String) -> String {
    text
    .replace_all(old="\r", new="%0D")
    .replace_all(old="\n", new="%0A")
    .replace_all(old="\"", new="%22")
  }

  let buf = StringBuilder()
  buf.write_string(
    "Content-Disposition: form-data; name=\"\{escape(self.name)}\"",
  )
  if self.filename is Some(filename) {
    buf.write_string("; filename=\"\{escape(filename)}\"")
  }
  if self.content_type is Some(content_type) {
    buf.write_string("\r\nContent-Type: \{content_type}")
  }
  buf.to_string()
}

///|
fn Settings::apply_form(self : Settings, option : Occurrence) -> Unit {
  self.form_location = Some(option.location)
  let bad = (message, help) => {
    self.fail_at(option, "form-syntax", message, help~)
  }
  guard option.value.split_once(b'=') is Some((name, content)) else {
    bad(
      "a part of a form is written as name=content", "write name=content, or name=@FILE for a file",
    )
    return
  }
  guard name.to_text() is Some(name) else {
    self.fail_at(
      option, "variable-not-supported", "the name of a part must be known text",
    )
    return
  }
  if name == "" {
    bad("a part without a name is not supported", "write name=content")
    return
  }
  if option.name == "form-string" {
    self.parts.push({ name, content, filename: None, content_type: None, })
    return
  }
  guard content.to_text() is Some(text) else {
    self.fail_at(
      option,
      "variable-not-supported",
      "the content of -F must be known text, because some characters have a meaning",
      help="use --form-string, where a variable is taken as it is",
    )
    return
  }
  let part = read_form_part(name, text, windows=self.windows) catch {
    FormError(message~, help~) => {
      bad(message, help)
      return
    }
  }
  self.parts.push(part)
}

///|
/// Checks a form against the other options. curl puts the boundary after the
/// Content-Type of the command, so only the usual one is left.
fn Settings::check_form(self : Settings) -> Unit {
  guard self.form_location is Some(location) else { return }
  if self.data is Some(_) || self.json {
    self.report.error(
      "conflicting-options",
      "curl refuses a form together with other data",
      location~,
    )
  }
  if self.head is Some(_) {
    self.report.error(
      "conflicting-options",
      "curl refuses -I together with a form",
      location~,
    )
  }
  if self.get {
    self.report.error(
      "conflicting-options",
      "-G has no effect on a form",
      help="remove -G, or use --data-urlencode",
      location~,
    )
  }
  for line in self.header_lines {
    if !same_name(line.name, "Content-Type") {
      continue
    }
    if line.kind is Set(value) &&
      value.to_text() is Some("multipart/form-data") &&
      !self.follow {
      continue
    }
    self.report.error(
      "framing-header",
      "another Content-Type of a form is not supported",
      help="remove it; curl adds the one that fits",
      location=line.location,
    )
  }
}

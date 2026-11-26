///|
/// Whether `byte` may be part of the name of a variable of `--variable`.
fn is_variable_name_byte(byte : Byte) -> Bool {
  is_alpha(byte.to_char()) || is_digit(byte.to_char()) || byte == b'_'
}

///|
/// The longest name curl takes for a variable.
let max_variable_name : Int32 = 127

///|
/// `--variable`: `name=content` or `%NAME` for an environment variable.
fn Settings::apply_variable(self : Settings, option : Occurrence) -> Unit {
  let bytes = option.value.prefix()
  let import_env = bytes is [b'%', ..]
  let skip = if import_env { 1 } else { 0 }
  let mut end = skip
  while end < bytes.length() && is_variable_name_byte(bytes[end]) {
    end += 1
  }
  let name_length = end - skip
  if name_length == 0 || name_length > max_variable_name {
    self.fail_at(
      option,
      "bad-variable",
      "a variable needs a name of up to 127 letters, digits and _",
      help="write name=value, or %NAME for an environment variable",
    )
    return
  }
  let name = ascii_text(bytes[skip:end])
  let rest = option.value.drop_bytes(end)
  if import_env {
    if !rest.is_empty() {
      self.fail_at(
        option,
        "unsupported-value",
        "a default for an environment variable, or one from a file, is not supported",
        help="write --variable %\{name}, and set the variable",
      )
      return
    }
    self.variables[name] = Value::from_pieces([Env(name)])
    return
  }
  match rest.prefix() {
    [b'=', ..] => self.variables[name] = rest.drop_bytes(1)
    [b'@', ..] =>
      self.fail_at(
        option,
        "file-not-supported",
        "reading a variable from a file is not supported",
        help="write name=value",
      )
    [b'[', ..] =>
      self.fail_at(
        option,
        "unsupported-value",
        "a range of bytes of a variable is not supported",
        help="write the part you need as name=value",
      )
    _ =>
      self.fail_at(
        option,
        "bad-variable",
        "the name of a variable is followed by =, or by @ and a file",
        help="write name=value, or %NAME for an environment variable",
      )
  }
}

///|
/// The functions of `{{name:function}}`.
fn apply_variable_function(name : StringView, bytes : Bytes) -> Bytes? {
  match name {
    "trim" => {
      let is_space = (b : Byte) => {
        b is (b' ' | b'\t' | b'\n' | b'\x0B' | b'\x0C' | b'\r')
      }
      let mut start = 0
      let mut end = bytes.length()
      while start < end && is_space(bytes[start]) {
        start += 1
      }
      while end > start && is_space(bytes[end - 1]) {
        end -= 1
      }
      Some(bytes[start:end].to_owned())
    }
    "json" => Some(json_escape(bytes))
    "url" => Some(url_escape(bytes))
    "b64" => Some(@utf8.encode(@base64.encode(bytes)))
    "64dec" =>
      Some(base64_decode(bytes).unwrap_or(@utf8.encode("[64dec-fail]")))
    _ => None
  }
}

///|
/// `{{name:function}}` as curl's json: the inside of a JSON string.
fn json_escape(bytes : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for byte in bytes {
    match byte {
      b'"' => out.append(b"\\\"".to_array())
      b'\\' => out.append(b"\\\\".to_array())
      b'\x08' => out.append(b"\\b".to_array())
      b'\x0C' => out.append(b"\\f".to_array())
      b'\n' => out.append(b"\\n".to_array())
      b'\r' => out.append(b"\\r".to_array())
      b'\t' => out.append(b"\\t".to_array())
      _ if byte < b' ' => {
        out.append(b"\\u00".to_array())
        out.push(hex_digit_lower(byte.to_int() >> 4))
        out.push(hex_digit_lower(byte.to_int() & 15))
      }
      _ => out.push(byte)
    }
  }
  Bytes::from_array(out)
}

///|
fn hex_digit_lower(value : Int32) -> Byte {
  b"0123456789abcdef"[value]
}

///|
/// `{{name:url}}`: everything but letters, digits and `-._~` percent-encoded.
fn url_escape(bytes : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for byte in bytes {
    if is_alpha(byte.to_char()) ||
      is_digit(byte.to_char()) ||
      byte is (b'-' | b'.' | b'_' | b'~') {
      out.push(byte)
    } else {
      out.push(b'%')
      out.push(b"0123456789ABCDEF"[byte.to_int() >> 4])
      out.push(b"0123456789ABCDEF"[byte.to_int() & 15])
    }
  }
  Bytes::from_array(out)
}

///|
let base64_alphabet : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// `{{name:64dec}}`: the bytes of base64 in groups of four with at most two
/// `=` at the end, or `None`.
fn base64_decode(bytes : Bytes) -> Bytes? {
  if bytes.length() % 4 != 0 {
    return None
  }
  let mut padding = 0
  while padding < 2 &&
        bytes.length() - padding > 0 &&
        bytes[bytes.length() - padding - 1] == b'=' {
    padding += 1
  }
  let digits = bytes.length() - padding
  let out : Array[Byte] = []
  let mut bits = 0
  let mut count = 0
  for i in 0..<digits {
    let value = match base64_alphabet.find(bytes[i].to_char().to_string()) {
      Some(at) => at
      None => return None
    }
    bits = ((bits << 6) | value) & 0xFFFF
    count += 6
    if count >= 8 {
      count -= 8
      out.push(((bits >> count) & 255).to_byte())
    }
  }
  Some(Bytes::from_array(out))
}

///|
/// The text of bytes that are ASCII.
fn ascii_text(bytes : BytesView) -> String {
  String::from_array(bytes.iter().map(b => b.to_char()).collect())
}

///|
/// The index of the first `}}` at or after `from`.
fn closing_braces(bytes : Bytes, from : Int32) -> Int32? {
  for i = from; i + 1 < bytes.length(); i = i + 1 {
    if bytes[i] == b'}' && bytes[i + 1] == b'}' {
      return Some(i)
    }
  }
  None
}

///|
/// The value of an `--expand-` option with `{{name}}` and
/// `{{name:function:...}}` replaced as curl does, or `None` after an error.
fn Settings::expand(self : Settings, option : Occurrence) -> Value? {
  guard option.value.to_bytes() is Some(bytes) else {
    self.fail_at(
      option,
      "variable-not-supported",
      "what \{option.written} expands must be known text",
      help="import the environment variable with --variable %NAME and write {{NAME}}",
    )
    return None
  }
  let pieces : Array[Piece] = []
  let mut copied = 0
  let mut i = 0
  while i + 1 < bytes.length() {
    if !(bytes[i] == b'{' && bytes[i + 1] == b'{') {
      i += 1
      continue
    }
    if i > 0 && bytes[i - 1] == b'\\' {
      self.fail_at(
        option, "unsupported-value", "a backslash before {{ is not supported, because versions of curl read it differently",
      )
      return None
    }
    guard closing_braces(bytes, i + 2) is Some(close) else {
      self.fail_at(
        option, "unsupported-value", "{{ without }} is not supported, because versions of curl read it differently",
      )
      return None
    }
    let inner = bytes[i + 2:close]
    let colon = index_of(inner.to_owned(), b => b == b':')
    let name = inner[:colon.unwrap_or(inner.length())]
    if name.length() == 0 ||
      name.length() > max_variable_name ||
      !name.iter().all(is_variable_name_byte) {
      self.report.add(
        Warning,
        "not-a-variable",
        "curl leaves {{...}} as it is when what is inside does not start with the name of a variable",
        location=option.value_location,
      )
      i = close + 2
      continue
    }
    guard self.variables.get(ascii_text(name)) is Some(value) else {
      self.fail_at(
        option,
        "undefined-variable",
        "the variable is not set by --variable before this option, and curl would put nothing in its place",
        help="set it with --variable before the option",
      )
      return None
    }
    pieces.push(Literal(bytes[copied:i].to_owned()))
    match colon {
      None => pieces.append(value.pieces().to_owned())
      Some(at) => {
        guard value.to_bytes() is Some(content) else {
          self.fail_at(
            option, "variable-not-supported", "functions on the value of an environment variable are not supported",
          )
          return None
        }
        let mut content = content
        for function in ascii_text(inner[at + 1:]).split(":") {
          guard apply_variable_function(function, content) is Some(result) else {
            self.fail_at(
              option, "unsupported-value", "curl knows only the functions trim, json, url, b64 and 64dec",
            )
            return None
          }
          content = result
        }
        pieces.push(Literal(content))
      }
    }
    i = close + 2
    copied = i
  }
  pieces.push(Literal(bytes[copied:].to_owned()))
  let value = Value::from_pieces(pieces)
  if value.any_byte(b => b == b'\x00') {
    self.fail_at(
      option, "unsupported-value", "the expanded value has a NUL byte, which curl rejects",
    )
    return None
  }
  Some(value)
}

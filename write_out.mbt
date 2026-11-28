///|
/// A part of the text of `-w`.
priv enum WriteOutPart {
  /// Text to write as it is.
  Text(String)
  /// What `%{name}` stands for.
  Variable(String)
  /// `%header{name}`: the value of that field of the last response.
  Header(String)
  /// `%{stderr}` and `%{stdout}`: where what follows goes.
  ToStderr
  ToStdout
}

///|
/// The variables of `-w` that programs write, which do not depend on how
/// the connection went.
let write_out_variables : Array[String] = [
  "http_code", "response_code", "content_type", "size_download", "num_redirects",
  "url_effective", "method", "scheme", "urlnum", "filename_effective", "redirect_url",
]

///|
/// The function, `header` or `output`, whose `{` follows at `at`.
fn function_at(chars : Array[Char], at : Int32) -> String? {
  let end = (at + 7).min(chars.length())
  match String::from_array(chars[at:end]) {
    "header{" => Some("header")
    "output{" => Some("output")
    _ => None
  }
}

///|
/// The parts of the text of `-w`, read as curl reads it, or why programs
/// cannot write it.
fn parse_write_out(text : String) -> Result[Array[WriteOutPart], String] {
  let chars = text.to_array()
  let parts : Array[WriteOutPart] = []
  let pending = StringBuilder()
  let flush = () => {
    let text = pending.to_string()
    if text != "" {
      parts.push(Text(text))
      pending.reset()
    }
  }
  let mut i = 0
  while i < chars.length() {
    let char = chars[i]
    let next = chars.get(i + 1)
    match (char, next) {
      ('%', Some('%')) => {
        pending.write_char('%')
        i += 2
      }
      ('%', Some('{')) => {
        let close = for j = i + 2; j < chars.length(); j = j + 1 {
          if chars[j] == '}' {
            break Some(j)
          }
        } nobreak {
          None
        }
        guard close is Some(close) else {
          // curl writes the rest as it is.
          pending.write_string("%{")
          i += 2
          continue
        }
        let name = String::from_array(chars[i + 2:close])
        match name {
          "stderr" => {
            flush()
            parts.push(ToStderr)
          }
          "stdout" => {
            flush()
            parts.push(ToStdout)
          }
          _ if write_out_variables.contains(name) => {
            flush()
            parts.push(Variable(name))
          }
          _ =>
            return Err(
              "a %{...} of -w that programs do not write, or that curl does not know",
            )
        }
        i = close + 1
      }
      ('%', Some(_)) if function_at(chars, i + 1) is Some(function) => {
        let close = for j = i + 8; j < chars.length(); j = j + 1 {
          if chars[j] == '}' {
            break Some(j)
          }
        } nobreak {
          None
        }
        guard function == "header" && close is Some(close) else {
          return Err(
            "%output{...} of -w, and %header{ without }, are not supported",
          )
        }
        let name = String::from_array(chars[i + 8:close])
        guard is_token(name) else {
          return Err("%header{...} of -w must name a header field")
        }
        flush()
        parts.push(Header(name))
        i = close + 1
      }
      ('%' | '\\', Some(other)) => {
        if char == '\\' && other is ('n' | 'r' | 't') {
          pending.write_char(
            match other {
              'n' => '\n'
              'r' => '\r'
              _ => '\t'
            },
          )
        } else {
          pending.write_char(char)
          pending.write_char(other)
        }
        i += 2
      }
      _ => {
        pending.write_char(char)
        i += 1
      }
    }
  }
  flush()
  Ok(parts)
}

///|
fn Settings::apply_write_out(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(text) else { return }
  if text.has_prefix("@") {
    self.fail_at(
      option,
      "file-not-supported",
      "reading the text of -w from a file is not supported",
      help="write the text out",
    )
    return
  }
  match parse_write_out(text) {
    Ok(_) => self.write_out = if text == "" { None } else { Some(text) }
    Err(message) =>
      self.fail_at(
        option,
        "unsupported-value",
        message,
        help="programs write %{http_code}, %{response_code}, %{content_type}, %{size_download}, %{num_redirects}, %{url_effective}, %{method}, %{scheme}, %{urlnum}, %{filename_effective}, %{redirect_url}, %header{name}, %{stderr} and %{stdout}",
      )
  }
}

///|
/// Whether the text of `-w` writes `%{name}`.
fn writes_variable(text : String, name : String) -> Bool {
  parse_write_out(text) is Ok(parts) &&
  parts.iter().any(part => part is Variable(found) && found == name)
}

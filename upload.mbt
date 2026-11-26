///|
/// `bytes` percent-encoded as curl encodes for URLs: letters, digits and
/// `-._~` stay, the rest becomes `%xx` in lower case. With `plus`, a space
/// becomes `+`.
fn url_encode(bytes : Bytes, plus~ : Bool) -> String {
  let out = StringBuilder()
  let digits = "0123456789abcdef"
  for byte in bytes {
    match byte {
      b'A'..<=b'Z' | b'a'..<=b'z' | b'0'..<=b'9' | b'-' | b'.' | b'_' | b'~' =>
        out.write_char(byte.to_char())
      b' ' if plus => out.write_char('+')
      _ => {
        out.write_char('%')
        out.write_char(digits[byte.to_int() / 16].unsafe_to_char())
        out.write_char(digits[byte.to_int() % 16].unsafe_to_char())
      }
    }
  }
  out.to_string()
}

///|
/// Whether `text` can be put into a query as it is.
fn is_raw_query(text : String) -> Bool {
  text.iter().all(c => c > ' ' && c < '\u007F' && !(c is ('#' | '\\')))
}

///|
fn Settings::apply_upload(self : Settings, option : Occurrence) -> Unit {
  if self.upload is Some(_) {
    self.fail_at(
      option,
      "several-uploads",
      "curl uploads one file for each URL, and this is not the first one",
      help="convert one upload at a time",
    )
    return
  }
  guard option.value.to_text() is Some(path) && !path.contains("\u0000") else {
    self.fail_at(
      option,
      "variable-not-supported",
      "the name of the file must be known text",
      help="write the name out",
    )
    return
  }
  let windows = self.windows
  let problem = if path == "" {
    Some("there is no name of a file")
  } else if path == "-" || path == "." {
    Some("reading the standard input is not supported")
  } else if base_name(path, windows~) is ("" | "." | "..") {
    Some("what -T names is a directory")
  } else if !self.globoff && path.iter().any(is_glob_char) {
    Some("curl expands {} and [] in the name into several uploads")
  } else {
    None
  }
  match problem {
    Some(message) =>
      self.fail_at(option, "unsupported-value", message, help="name one file")
    None => self.upload = Some((path, option.location))
  }
}

///|
fn Settings::apply_url_query(self : Settings, option : Occurrence) -> Unit {
  guard option.value.to_text() is Some(text) else {
    self.fail_at(
      option,
      "variable-not-supported",
      "the value of \{option.written} must be known text, because it becomes part of the URL",
      help="write the value out",
    )
    return
  }
  let bad = message => {
    self.fail_at(
      option,
      "bad-query-data",
      message,
      help="leave out the + to have the value encoded, or percent-encode it",
    )
  }
  if text.strip_prefix("+") is Some(raw) {
    if is_raw_query(raw.to_owned()) {
      self.url_queries.push((raw.to_owned(), option.location))
    } else {
      bad(
        "what follows + goes into the URL as it is, and has a space, a # or a character that is not printable ASCII",
      )
    }
    return
  }
  // The name ends at the first `=` or, if there is none, at the first `@`.
  let (name, content) = match text.find("=") {
    Some(at) => (text[:at].to_owned(), text[at + 1:].to_owned())
    None =>
      match text.find("@") {
        Some(_) => {
          self.fail_at(
            option,
            "file-not-supported",
            "a URL with the content of a file is not supported",
            help="put the value in the command",
          )
          return
        }
        None => ("", text)
      }
  }
  if !is_raw_query(name) {
    bad(
      "the name before = goes into the URL as it is, and has a space, a # or a character that is not printable ASCII",
    )
    return
  }
  let encoded = url_encode(@utf8.encode(content), plus=true)
  let item = if name == "" { encoded } else { "\{name}=\{encoded}" }
  self.url_queries.push((item, option.location))
}

///|
/// The URL after the name of the uploaded file and the items of `--url-query`
/// are added, as curl does in this order.
fn Settings::complete_url(self : Settings, url : Url) -> Url {
  let mut url = url
  if self.path_as_is && (self.upload is Some(_) || !self.url_queries.is_empty()) {
    self.report.error(
      "conflicting-options",
      "curl removes ./ and ../ from the path anyway when -T or --url-query changes the URL",
      help="remove --path-as-is, or write the URL out",
      location=match self.upload {
        Some((_, location)) => location
        None => self.url_queries[0].1
      },
    )
  }
  if self.upload is Some((path, _)) &&
    url.query is None &&
    url.path.has_suffix("/") {
    let name = base_name(path, windows=self.windows)
    url = {
      ..url,
      path: url.path + url_encode(@utf8.encode(name), plus=false),
    }
  }
  if !self.url_queries.is_empty() && self.get && self.data is Some(_) {
    self.report.error(
      "conflicting-options",
      "curl leaves out what --url-query adds when -G puts data in the URL",
      help="put all of it in --url-query",
      location=self.url_queries[0].1,
    )
  }
  let mut query = url.query.unwrap_or("")
  for item in self.url_queries {
    if query == "" {
      query = item.0
    } else {
      query = "\{query}&\{item.0}"
    }
  }
  { ..url, query: if query == "" { None } else { Some(query) }, }
}

///|
/// Checks an upload against the other options.
fn Settings::check_upload(self : Settings) -> Unit {
  guard self.upload is Some((_, location)) else { return }
  if self.data is Some(_) || self.json || !self.parts.is_empty() {
    self.report.error(
      "conflicting-options",
      "curl refuses -T together with data or a form",
      location~,
    )
  }
  if self.head is Some(_) {
    self.report.error(
      "conflicting-options",
      "curl refuses -I together with -T",
      location~,
    )
  }
  if self.get {
    self.report.error(
      "conflicting-options",
      "-G has no effect on an upload",
      help="remove -G",
      location~,
    )
  }
}

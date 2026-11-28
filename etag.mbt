///|
/// `--etag-compare` and `--etag-save`: the name of a file, which must not
/// be empty, as curl requires.
fn Settings::apply_etag(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(path) else { return }
  if path.is_empty() || path.contains("\u0000") {
    self.fail_at(
      option, "unsupported-value", "the name of a file must not be empty",
    )
    return
  }
  if option.name == "etag-save" {
    if path == "-" {
      self.fail_at(
        option,
        "unsupported-value",
        "--etag-save - writes the ETag to the standard output, which programs do not do",
        help="name a file",
      )
      return
    }
    self.etag_save = Some((path, option.value_location))
  } else {
    self.etag_compare = Some((path, option.value_location))
  }
}

///|
/// Reports what curl would do otherwise with `--etag-compare` and
/// `--etag-save`.
fn Settings::check_etag(self : Settings) -> Unit {
  if self.etag_compare is Some((_, location)) && self.has_line("If-None-Match") {
    self.report.error(
      "duplicate-header",
      "curl sends If-None-Match from --etag-compare as well as the one of -H",
      help="leave out one of them",
      location~,
    )
  }
  if self.etag_save is Some((path, location)) &&
    self.create_dirs &&
    self.windows &&
    path.contains("\\") {
    self.report.error(
      "unsupported-value",
      "--create-dirs is only supported for a file named with /",
      help="write / between the directories",
      location~,
    )
  }
}

///|
/// How a program reads the file of `--etag-compare`, as curl does.
let etag_compare_code : String =
  #|
  #|///|
  #|/// The If-None-Match that --etag-compare sends: the text of the file
  #|/// without line breaks, "" if there is no such file or it is empty, and
  #|/// none if it has only line breaks and blanks.
  #|async fn etag_to_compare(path : String) -> String? {
  #|  let data = @fs.read_file(path) catch {
  #|    _ => return Some("\"\"")
  #|  }
  #|  let text = data.text()
  #|  if text.is_empty() {
  #|    return Some("\"\"")
  #|  }
  #|  let value = StringBuilder()
  #|  for char in text {
  #|    match char {
  #|      '\r' | '\n' => ()
  #|      '\u{00}'..='\u{1F}' | '\u{7F}' if char != '\t' =>
  #|        fail("the file \{path} has a control character")
  #|      _ => value.write_char(char)
  #|    }
  #|  }
  #|  let value = value.to_string()
  #|  if value.trim(chars=" \t").is_empty() {
  #|    None
  #|  } else {
  #|    Some(value)
  #|  }
  #|}

///|
/// How a program writes the file of `--etag-save`, as curl does.
let etag_save_code : String =
  #|
  #|///|
  #|/// Writes the ETag of `response` to `path` as --etag-save does: for a
  #|/// status from 200 to 399, without the blanks around it.
  #|async fn save_etag(response : @http.Response, path : String) -> Unit {
  #|  guard response.code is (200..<400) else { return }
  #|  guard response.headers.get("ETag") is Some(etag) else { return }
  #|  let etag = etag.trim(chars=" \t")
  #|  if etag.is_empty() {
  #|    return
  #|  }
  #|  @fs.write_file(path, "\{etag}\n", create_mode=CreateOrTruncate)
  #|}

///|
/// The statements at the start of `main` that make the file of
/// `--etag-save`, before the request, as curl does.
fn Emitter::etag_save_statements(self : Emitter) -> Array[String] {
  guard self.plan.etag_save is Some(path) else { return [] }
  let out = ["  // curl makes the file of --etag-save before the request."]
  if self.plan.create_dirs && parent_directory(path) is Some(directory) {
    out.push(
      "  @fs.mkdir(\"\{escape_text(directory)}\", recursive=true, allow_exist=true)",
    )
  }
  out.push(
    "  @fs.write_file(\"\{escape_text(path)}\", \"\", create_mode=OpenOrCreate, append=true)",
  )
  out
}

///|
/// The statement after a response arrives that saves its ETag.
fn Emitter::etag_saved(self : Emitter, indent : String) -> Array[String] {
  match self.plan.etag_save {
    Some(path) => ["\{indent}save_etag(response, \"\{escape_text(path)}\")"]
    None => []
  }
}

///|
/// The statements that add If-None-Match to `headers`, after the other
/// fields, as curl does.
fn Emitter::etag_header(self : Emitter, indent : String) -> Array[String] {
  guard self.plan.etag_compare is Some(_) else { return [] }
  [
    "\{indent}if if_none_match is Some(value) {",
    "\{indent}  headers[\"If-None-Match\"] = value",
    "\{indent}}",
  ]
}

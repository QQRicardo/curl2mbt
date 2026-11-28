///|
/// Why a plan cannot be written as a curl command.
#derive(Debug)
pub suberror ToCurlError {
  ToCurlError(String)
}

///|
/// An argument of curl: bytes and references to environment variables.
priv struct Argument(Array[Piece])

///|
fn Argument::text(text : String) -> Argument {
  if text == "" {
    Argument([])
  } else {
    Argument([Literal(@utf8.encode(text))])
  }
}

///|
fn Argument::value(value : Value) -> Argument raise ToCurlError {
  let pieces = []
  for piece in value.pieces() {
    if piece is File(..) {
      raise ToCurlError("the content of a file cannot be part of this value")
    }
    pieces.push(piece)
  }
  Argument(pieces)
}

///|
fn Argument::concat(self : Argument, other : Argument) -> Argument {
  let Argument(pieces) = self
  let all = pieces.copy()
  let Argument(more) = other
  for piece in more {
    match (all.last(), piece) {
      (Some(Literal(before)), Literal(bytes)) =>
        all[all.length() - 1] = Literal(before + bytes)
      _ => all.push(piece)
    }
  }
  Argument(all)
}

///|
/// The text of the plan as a curl command for `shell`, which reads back as
/// the same request. Header fields curl adds on its own become options or
/// stay implied, so the plan read back may differ in `implied` only.
pub fn RequestPlan::to_curl(
  self : RequestPlan,
  shell~ : Shell = Posix,
) -> String raise ToCurlError {
  let words = ["curl"]
  for argument in self.curl_arguments() {
    words.push(
      match shell {
        Posix => posix_quote(argument)
        Cmd => cmd_quote(argument)
      },
    )
  }
  let text = words.join(" ")
  let read = parse(text, shell~) catch {
    CurlError(found) => {
      let first = found.iter().find_first(d => d.severity is Error)
      let message = match first {
        Some(diagnostic) => diagnostic.message
        None => "it is rejected"
      }
      raise ToCurlError(
        "the command for \{shell_name(shell)} would not be read back: \{message}",
      )
    }
  }
  if without_implied(read.plan) != without_implied(self) {
    raise ToCurlError(
      "no command for \{shell_name(shell)} makes curl send this request",
    )
  }
  text
}

///|
fn shell_name(shell : Shell) -> String {
  match shell {
    Posix => "a POSIX shell"
    Cmd => "cmd"
  }
}

///|
fn without_implied(plan : RequestPlan) -> RequestPlan {
  {
    ..plan,
    headers: plan.headers.map(header => { ..header, implied: false, }),
  }
}

///|
/// The arguments after `curl`.
fn RequestPlan::curl_arguments(
  self : RequestPlan,
) -> Array[Argument] raise ToCurlError {
  let out : Array[Argument] = []
  let flag = name => out.push(Argument::text(name))
  let option = (name, argument) => {
    out.push(Argument::text(name))
    out.push(argument)
  }
  let implied_method = match self.body {
    None => "GET"
    Some(Data(_) | Multipart(_)) => "POST"
    Some(Upload(_)) => "PUT"
  }
  if self.explicit_method {
    option("-X", Argument::text(self.http_method))
  } else if self.http_method == "HEAD" && self.body is None {
    flag("-I")
  } else if self.http_method != implied_method {
    raise ToCurlError(
      "curl does not send \{self.http_method} for this body without -X",
    )
  }
  match self.auth {
    Some(Basic(value)) => option("-u", Argument::value(value))
    Some(Bearer(value)) => option("--oauth2-bearer", Argument::value(value))
    None => ()
  }
  if self.omit_user_agent {
    option("-A", Argument::text(""))
  }
  // The fields curl adds for its own options come first, in this order.
  let headers = self.headers
  let mut i = 0
  let at = name => i < headers.length() && same_name(headers[i].name, name)
  if at("Range") &&
    !headers[i].implied &&
    headers[i].value.to_text() is Some(text) &&
    text.strip_prefix("bytes=") is Some(range) {
    option("-r", Argument::text(range.to_owned()))
    i += 1
  }
  if at("User-Agent") && !headers[i].implied {
    option("-A", Argument::value(headers[i].value))
    i += 1
  }
  if at("Accept") && headers[i].implied {
    i += 1
  } else if !headers.iter().any(header => same_name(header.name, "Accept")) {
    option("-H", Argument::text("Accept:"))
  }
  if at("Referer") {
    option("-e", Argument::value(headers[i].value))
    i += 1
  }
  if at("Cookie") && self.cookie_engine {
    option("-b", Argument::value(headers[i].value))
    i += 1
  }
  // --json adds its own fields, at the end.
  let json_type = "application/json"
  let json = self.body is Some(Data(_)) &&
    headers
    .iter()
    .any(header => {
      header.implied &&
      header.value.to_text() == Some(json_type) &&
      (
        same_name(header.name, "Content-Type") ||
        same_name(header.name, "Accept")
      )
    })
  let form_type = if json {
    json_type
  } else {
    "application/x-www-form-urlencoded"
  }
  for header in headers[i:] {
    if header.implied &&
      self.body is Some(Data(_)) &&
      (
        same_name(header.name, "Content-Type") ||
        (json && same_name(header.name, "Accept"))
      ) &&
      header.value.to_text() == Some(form_type) {
      continue
    }
    let line = if header.value.is_empty() {
      Argument::text("\{header.name};")
    } else {
      Argument::text("\{header.name}: ").concat(Argument::value(header.value))
    }
    option("-H", line)
  }
  if self.body is Some(Data(_)) &&
    !headers.iter().any(header => same_name(header.name, "Content-Type")) {
    option("-H", Argument::text("Content-Type:"))
  }
  // -g comes before -T, which it changes.
  if self.url.to_string().iter().any(is_glob_char) ||
    (self.body is Some(Upload(path)) && path.iter().any(is_glob_char)) {
    flag("-g")
  }
  match self.body {
    Some(Data(value)) if json => json_arguments(value, option)
    Some(Data(value)) => data_arguments(value, option)
    Some(Multipart(parts)) =>
      for part in parts {
        form_argument(part, option)
      }
    Some(Upload(path)) => option("-T", Argument::text(path))
    None => ()
  }
  if self.compressed {
    flag("--compressed")
  }
  if self.location_trusted {
    flag("--location-trusted")
  } else if self.follow_redirects {
    flag("-L")
  }
  for code in self.keep_post {
    flag("--post\{code}")
  }
  if self.max_redirects != default_max_redirects {
    option("--max-redirs", Argument::text(self.max_redirects.to_string()))
  }
  if self.insecure {
    flag("-k")
  }
  if self.proxy is Some(proxy) {
    option("-x", Argument::text(proxy.to_string()))
    if proxy.user is Some(user) {
      option("-U", Argument::value(user))
    }
    flag("-p")
  }
  if self.fail_with_body {
    flag("--fail-with-body")
  } else if self.fail_on_error {
    flag("-f")
  }
  if self.output_file is Some(path) {
    option("-o", Argument::text(path))
  }
  if self.create_dirs {
    flag("--create-dirs")
  }
  if self.no_clobber {
    flag("--no-clobber")
  }
  if self.remove_on_error {
    flag("--remove-on-error")
  }
  if self.max_filesize is Some(size) {
    option("--max-filesize", Argument::text(size.to_string()))
  }
  if self.write_out is Some(text) {
    option("-w", Argument::text(text))
  }
  if self.max_time_ms is Some(ms) {
    option("-m", Argument::text(seconds_text(ms)))
  }
  if self.time_condition is Some(condition) {
    let prefix = match condition.field {
      "If-Unmodified-Since" => "-"
      "Last-Modified" => "="
      _ => ""
    }
    let text = match condition.time {
      At(time) => http_date(time)
      FileTime(path) => path
    }
    option("-z", Argument::text(prefix + text))
  }
  if self.etag_compare is Some(path) {
    option("--etag-compare", Argument::text(path))
  }
  if self.etag_save is Some(path) {
    option("--etag-save", Argument::text(path))
  }
  if self.request_target is Some(target) {
    option("--request-target", Argument::text(target))
  }
  if self.connect_timeout_ms is Some(ms) {
    option("--connect-timeout", Argument::text(seconds_text(ms)))
  }
  if self.retry is Some(retry) {
    option("--retry", Argument::text(retry.count.to_string()))
    if retry.delay_ms is Some(ms) {
      option("--retry-delay", Argument::text(seconds_text(ms)))
    }
    if retry.max_time_ms is Some(ms) {
      option("--retry-max-time", Argument::text(seconds_text(ms)))
    }
    if retry.all_errors {
      flag("--retry-all-errors")
    }
  }
  if has_dot_segment(self.url.path) {
    flag("--path-as-is")
  }
  out.push(Argument::text(self.url.to_string()))
  out
}

///|
/// Milliseconds as seconds, such as `1.5`.
fn seconds_text(ms : Int32) -> String {
  let whole = ms / 1000
  let mut fraction = (ms % 1000 + 1000).to_string()[1:].to_owned()
  while fraction.has_suffix("0") {
    fraction = fraction[:fraction.length() - 1].to_owned()
  }
  if fraction == "" {
    whole.to_string()
  } else {
    "\{whole}.\{fraction}"
  }
}

///|
fn has_dot_segment(path : String) -> Bool {
  path.split("/").any(segment => segment is ("." | ".."))
}

///|
/// The `--json` options whose values curl joins into `value`.
fn json_arguments(
  value : Value,
  option : (String, Argument) -> Unit,
) -> Unit raise ToCurlError {
  let pieces = value.pieces()
  if pieces.is_empty() {
    option("--json", Argument::text(""))
    return
  }
  let mut text : Array[Piece] = []
  let flush = () => {
    if text is [Literal([b'@', ..]), ..] {
      raise ToCurlError("--json takes data that starts with @ for a file")
    }
    if !text.is_empty() {
      option("--json", Argument(text))
    }
    text = []
  }
  for piece in pieces {
    match piece {
      File(path~, read=Whole) => {
        flush()
        option("--json", Argument::text("@" + path))
      }
      File(..) =>
        raise ToCurlError("--json reads files as they are, and nothing else")
      _ => text.push(piece)
    }
  }
  flush()
}

///|
/// The data options whose values curl joins with `&` into `value`.
fn data_arguments(
  value : Value,
  option : (String, Argument) -> Unit,
) -> Unit raise ToCurlError {
  let pieces = value.pieces()
  if pieces.is_empty() {
    option("--data-raw", Argument::text(""))
    return
  }
  // The text between files, which must be joined to them with `&`.
  let mut text : Array[Piece] = []
  let mut after_file = false
  let flush = (before_file : Bool) => {
    let mut segment = text
    text = []
    if after_file {
      guard segment is [Literal(bytes), ..] && bytes is [b'&', ..] else {
        raise ToCurlError("curl puts & after the content of a file")
      }
      segment = trim_literal(segment, front=true)
    }
    if before_file {
      if segment is [] && after_file {
        return
      }
      guard segment is [.., Literal(bytes)] && bytes is [.., b'&'] else {
        raise ToCurlError("curl puts & before the content of a file")
      }
      segment = trim_literal(segment, front=false)
    }
    option("--data-raw", Argument(segment))
  }
  for piece in pieces {
    match piece {
      File(path~, read~) => {
        if !text.is_empty() || after_file {
          flush(true)
        }
        let (name, prefix) = match read {
          Whole => ("--data-binary", "@")
          WithoutLineBreaks => ("-d", "@")
          FormEncoded(field) => ("--data-urlencode", "\{field}@")
        }
        option(name, Argument::text(prefix + path))
        after_file = true
      }
      _ => text.push(piece)
    }
  }
  if !text.is_empty() {
    flush(false)
  }
}

///|
/// `pieces` without the first byte of the first or the last byte of the last
/// one, which are literal.
fn trim_literal(pieces : Array[Piece], front~ : Bool) -> Array[Piece] {
  let out = pieces.copy()
  let index = if front { 0 } else { out.length() - 1 }
  guard out[index] is Literal(bytes) else { return out }
  let rest = if front {
    bytes[1:].to_owned()
  } else {
    bytes[:bytes.length() - 1].to_owned()
  }
  if rest.is_empty() {
    out.remove(index) |> ignore
  } else {
    out[index] = Literal(rest)
  }
  out
}

///|
/// The `-F` or `--form-string` option for a part.
fn form_argument(
  part : Part,
  option : (String, Argument) -> Unit,
) -> Unit raise ToCurlError {
  let quoted = (text : String) => {
    let out = StringBuilder()
    out.write_char('"')
    for char in text {
      if char is ('"' | '\\') {
        out.write_char('\\')
      }
      out.write_char(char)
    }
    out.write_char('"')
    out.to_string()
  }
  let attributes = StringBuilder()
  if part.content_type is Some(content_type) {
    attributes.write_string(";type=\{content_type}")
  }
  let name = Argument::text("\{part.name}=")
  match part.content.pieces() {
    [File(path~, read=Whole)] => {
      let source = match part.filename {
        Some(filename) => {
          attributes.write_string(";filename=\{quoted(filename)}")
          "@"
        }
        None => "<"
      }
      option(
        "-F",
        name.concat(
          Argument::text("\{source}\{quoted(path)}\{attributes.to_string()}"),
        ),
      )
    }
    _ => {
      let content = Argument::value(part.content)
      if part.filename is None && part.content_type is None {
        option("--form-string", name.concat(content))
      } else {
        guard part.content.to_text() is Some(text) else {
          raise ToCurlError(
            "a part with a type or file name must have known text",
          )
        }
        if part.filename is Some(filename) {
          attributes.write_string(";filename=\{quoted(filename)}")
        }
        option(
          "-F",
          name.concat(
            Argument::text("\{quoted(text)}\{attributes.to_string()}"),
          ),
        )
      }
    }
  }
}

///|
/// The argument for a POSIX shell.
fn posix_quote(argument : Argument) -> String {
  let Argument(pieces) = argument
  if pieces.is_empty() {
    return "''"
  }
  let out = StringBuilder()
  for piece in pieces {
    match piece {
      Literal(bytes) => out.write_string(posix_literal(bytes))
      Env(name) => out.write_string("\"${\{name}}\"")
      File(..) => ()
    }
  }
  out.to_string()
}

///|
fn posix_literal(bytes : Bytes) -> String {
  let text = Some(@utf8.decode(bytes)) catch { _ => None }
  match text {
    Some(text) if text.iter().all(is_plain_posix) => text
    Some(text) if !text.iter().any(char => char < ' ' || char == '\u{7F}') =>
      "'" + text.replace_all(old="'", new="'\\''") + "'"
    _ => {
      let out = StringBuilder()
      out.write_string("$'")
      let digits = "0123456789abcdef"
      for byte in bytes {
        match byte {
          b'\\' | b'\'' => {
            out.write_char('\\')
            out.write_char(byte.to_char())
          }
          b' '..<=b'~' => out.write_char(byte.to_char())
          _ => {
            out.write_string("\\x")
            out.write_char(digits[byte.to_int() / 16].unsafe_to_char())
            out.write_char(digits[byte.to_int() % 16].unsafe_to_char())
          }
        }
      }
      out.write_char('\'')
      out.to_string()
    }
  }
}

///|
/// Whether a POSIX shell takes `char` as it is outside quotes.
fn is_plain_posix(char : Char) -> Bool {
  is_alpha(char) ||
  is_digit(char) ||
  char is ('-' | '_' | '.' | '/' | ':' | '=' | '@' | '%' | '+' | ',')
}

///|
/// The argument for the prompt of cmd.exe: between quotes, with backslashes
/// before quotes as programs for Windows read them, and carets where cmd.exe
/// is outside its own quotes.
fn cmd_quote(argument : Argument) -> String raise ToCurlError {
  let Argument(pieces) = argument
  if pieces is [Literal(bytes)] &&
    bytes.iter().all(byte => byte < 0x80 && is_plain_cmd(byte.to_char())) {
    return @utf8.decode_lossy(bytes)
  }
  let out = StringBuilder()
  out.write_char('"')
  let mut quoted = true
  let mut backslashes = 0
  let flush = (before_quote : Bool) => {
    let count = if before_quote { backslashes * 2 } else { backslashes }
    for _ in 0..<count {
      out.write_char('\\')
    }
    backslashes = 0
  }
  for piece in pieces {
    match piece {
      Literal(bytes) => {
        let text = @utf8.decode(bytes) catch {
          _ =>
            raise ToCurlError(
              "bytes that are not UTF-8 cannot be written for cmd",
            )
        }
        for char in text {
          match char {
            '\\' => backslashes += 1
            '"' => {
              flush(true)
              out.write_string("\\\"")
              quoted = !quoted
            }
            _ if char < ' ' || char == '\u{7F}' =>
              raise ToCurlError("control characters cannot be written for cmd")
            _ => {
              flush(false)
              if !quoted && char is ('&' | '|' | '<' | '>' | '^' | '(' | ')') {
                out.write_char('^')
              }
              out.write_char(char)
            }
          }
        }
      }
      Env(name) => {
        flush(false)
        out.write_string("%\{name}%")
      }
      File(..) => ()
    }
  }
  flush(true)
  out.write_char('"')
  out.to_string()
}

///|
/// Whether cmd.exe and curl.exe take `char` as it is outside quotes.
fn is_plain_cmd(char : Char) -> Bool {
  is_alpha(char) ||
  is_digit(char) ||
  char is ('-' | '_' | '.' | '/' | ':' | '=' | '@' | '+' | ',' | '\\')
}

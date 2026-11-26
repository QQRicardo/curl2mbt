///|
/// Whether a custom header line, also one that removes the field, replaces
/// what curl would send for `name`.
fn Settings::has_line(self : Settings, name : String) -> Bool {
  self.header_lines.iter().any(line => same_name(line.name, name))
}

///|
/// The header fields, in the order curl sends them.
fn Settings::headers(
  self : Settings,
  body : Body?,
  range : String?,
) -> Array[Header] {
  let headers : Array[Header] = []
  let implied = (name, text) => {
    headers.push({ name, value: Value::literal(text), implied: true, })
  }
  let set = (name, value) => headers.push({ name, value, implied: false, })
  if range is Some(range) && !self.has_line("Range") {
    set("Range", Value::literal("bytes=\{range}"))
  }
  if self.user_agent is Some((value, _)) &&
    !value.is_empty() &&
    !self.has_line("User-Agent") {
    set("User-Agent", value)
  }
  if !self.has_line("Accept") && !self.json {
    implied("Accept", "*/*")
  }
  if self.referer is Some(value) && !self.has_line("Referer") {
    set("Referer", value)
  }
  if !self.cookies.is_empty() && !self.has_line("Cookie") {
    let mut value = self.cookies[0]
    for cookie in self.cookies[1:] {
      value = value.append(Value::literal("; ")).append(cookie)
    }
    set("Cookie", value)
  }
  for line in self.header_lines {
    // The body of a form brings its own.
    if body is Some(Multipart(_)) && same_name(line.name, "Content-Type") {
      continue
    }
    if line.kind is Set(value) {
      set(line.name, value)
    }
  }
  if self.json {
    if !self.has_line("Content-Type") {
      implied("Content-Type", "application/json")
    }
    if !self.has_line("Accept") {
      implied("Accept", "application/json")
    }
  } else if body is Some(Data(_)) && !self.has_line("Content-Type") {
    implied("Content-Type", "application/x-www-form-urlencoded")
  }
  headers
}

///|
/// The URL with the data of `-G` in its query.
fn Settings::url_with_data(self : Settings, text : String) -> String {
  guard self.get && self.data is Some(data) else { return text }
  guard data.to_text() is Some(query) &&
    query.iter().all(c => c > ' ' && c < '\u007F' && c != '#') else {
    self.report.error(
      "bad-query-data",
      "the data that -G puts in the URL has a variable, a file, a space, a # or a character that is not printable ASCII",
      help="use --data-urlencode",
      location?=self.data_location,
    )
    return text
  }
  // Before the fragment, as curl does.
  let (base, fragment) = match text.find("#") {
    Some(at) => (text[:at].to_owned(), text[at:].to_owned())
    None => (text, "")
  }
  let separator = match base.find("?") {
    Some(at) => if at + 1 == base.length() { "" } else { "&" }
    None => "?"
  }
  "\{base}\{separator}\{query}\{fragment}"
}

///|
fn Settings::parse_the_url(self : Settings) -> ParsedUrl? {
  guard self.urls is [(value, location), .. more] else {
    self.report.error("no-url", "the command has no URL")
    return None
  }
  for entry in more {
    self.report.error(
      "several-urls",
      "curl makes one request for each URL, and this is not the first one",
      help="convert one request at a time; quote an argument that has spaces",
      location=entry.1,
    )
  }
  guard value.to_text() is Some(text) else {
    self.report.error(
      "variable-not-supported",
      "a URL with a variable is not supported, because the variable could change any part of it",
      help="write the URL out",
      location~,
    )
    return None
  }
  let parsed = parse_url(
    self.url_with_data(text),
    globbing=!self.globoff,
    path_as_is=self.path_as_is,
  ) catch {
    UrlError({ code, message, help, }) => {
      self.report.error(code, message, help?, location~)
      return None
    }
  }
  if parsed.guessed_scheme {
    self.report.add(
      Note,
      "guessed-scheme",
      "the URL has no scheme, so curl uses http",
      location~,
    )
  }
  Some(parsed)
}

///|
fn Settings::build_auth(self : Settings, parsed : ParsedUrl) -> Auth? {
  let user = match (self.user, parsed.user_info) {
    (Some(user), _) => Some(user)
    (None, Some((user, password))) => {
      let bytes = percent_decode(user) + b":" + percent_decode(password)
      if bytes.iter().any(b => b < 0x20) {
        self.report.error(
          "bad-url",
          "the user name or password in the URL has a control character",
          location=self.urls[0].1,
        )
      }
      Some(Value::from_pieces([Literal(bytes)]))
    }
    (None, None) => None
  }
  if self.has_line("Authorization") {
    return None
  }
  match (self.bearer, user) {
    (Some(token), _) => Some(Bearer(token))
    (None, Some(user)) => Some(Basic(user))
    (None, None) => None
  }
}

///|
/// Checks the options against each other and makes the plan. `None` if
/// something was reported that leaves nothing to make it from.
fn Settings::build(self : Settings) -> RequestPlan? {
  if self.head is Some(location) && self.data is Some(_) && !self.get {
    self.report.error(
      "conflicting-options",
      "curl refuses -I together with data",
      help="use -G to put the data in the URL",
      location~,
    )
  }
  self.check_form()
  self.check_upload()
  let body = match self.data {
    _ if self.upload is Some((path, _)) => Some(Upload(path))
    _ if !self.parts.is_empty() => Some(Multipart(self.parts))
    Some(data) if !self.get => Some(Data(data))
    _ => None
  }
  let range = match self.range {
    Some((_, location)) if body is Some(_) => {
      self.report.error(
        "conflicting-options",
        "a range of a request that has a body is not supported",
        location~,
      )
      None
    }
    Some((range, _)) => Some(range)
    None => None
  }
  let http_method = match self.request {
    Some((name, _)) => name
    None =>
      if self.head is Some(_) {
        "HEAD"
      } else if body is Some(Upload(_)) {
        "PUT"
      } else if body is Some(_) {
        "POST"
      } else {
        "GET"
      }
  }
  if self.request is Some((name, location)) {
    if name.to_upper() != name &&
      ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"].contains(
        name.to_upper(),
      ) {
      self.report.add(
        Warning,
        "lowercase-method",
        "methods are case-sensitive, and curl sends this one as written",
        location~,
      )
    }
    if name == "HEAD" && self.head is None {
      self.report.add(
        Warning,
        "head-without-option",
        "with -X HEAD, curl waits for a body that does not come",
        help="use -I",
        location~,
      )
    }
  }
  for line in self.header_lines {
    if line.kind is Remove && !self.curl_would_send(line.name, body) {
      self.report.add(
        Note,
        "nothing-to-remove",
        "a header without a value removes the field, and curl would not send this one",
        help="\"Name;\" sends the field with an empty value",
        location=line.location,
      )
    }
  }
  let parsed = self.parse_the_url()
  guard parsed is Some(parsed) else { return None }
  let auth = self.build_auth(parsed)
  let url = self.complete_url(parsed.url)
  let output_file = self.output_file(url)
  Some({
    http_method,
    explicit_method: self.request is Some(_),
    url,
    headers: self.headers(body, range),
    omit_user_agent: if self.has_line("User-Agent") {
      !self.header_lines
      .iter()
      .any(line => same_name(line.name, "User-Agent") && line.kind is Set(_))
    } else {
      self.user_agent is Some((value, _)) && value.is_empty()
    },
    auth,
    body,
    compressed: self.compressed,
    follow_redirects: self.follow,
    max_redirects: self.max_redirects,
    cookie_engine: self.cookie_engine,
    insecure: self.insecure,
    fail_on_error: self.fail || self.fail_with_body,
    fail_with_body: self.fail_with_body,
    output_file,
    create_dirs: self.create_dirs && output_file is Some(_),
    max_time_ms: self.max_time_ms,
  })
}

///|
/// Whether curl sends the field `name` without a header line for it.
fn Settings::curl_would_send(
  self : Settings,
  name : String,
  body : Body?,
) -> Bool {
  match name.to_lower() {
    "accept" | "user-agent" => true
    "content-type" => body is Some(_) || self.json
    "authorization" => self.user is Some(_) || self.bearer is Some(_)
    "cookie" => !self.cookies.is_empty()
    "referer" => self.referer is Some(_)
    "range" => self.range is Some(_)
    "accept-encoding" => self.compressed
    // curl adds it to large bodies.
    "expect" => body is Some(_)
    _ => false
  }
}

///|
/// Whether `value` is how a program called curl is started.
fn is_curl(value : Value, windows~ : Bool) -> Bool {
  guard value.to_text() is Some(text) else { return false }
  let name = base_name(text, windows~)
  let name = if windows { name.to_lower() } else { name }
  name is ("curl" | "curl.exe")
}

///|
fn parse_words(
  words : Array[Word],
  report : Report,
  windows~ : Bool,
) -> Parsed raise CurlError {
  let words = if !windows &&
    words is [{ value, location, }, _, ..] &&
    value.to_text() is Some("$") {
    report.add(
      Note,
      "prompt",
      "the $ at the start is taken for the prompt of a shell",
      location~,
    )
    words[1:]
  } else {
    words[:]
  }
  match words {
    [] =>
      if !report.has_errors() {
        report.error("no-command", "there is no command")
      }
    [{ value, location, }, .. rest] =>
      if is_curl(value, windows~) {
        let (options, urls) = split_options(rest, report)
        let settings = Settings::new(report, windows~)
        for option in options {
          settings.apply(option)
        }
        settings.urls.append(urls)
        let plan = settings.build()
        if plan is Some(plan) && !report.has_errors() {
          return { plan, diagnostics: report.sorted(), }
        }
      } else {
        report.error(
          "not-curl",
          "the command does not start with curl",
          help="remove what is before curl, such as sudo or variable assignments",
          location~,
        )
      }
  }
  raise CurlError(report.sorted())
}

///|
/// The syntax of the text that holds a command.
#derive(Eq, Debug)
pub(all) enum Shell {
  /// A POSIX shell or bash, also in what browsers call "Copy as cURL (bash)".
  Posix
  /// The prompt of Windows cmd.exe, "Copy as cURL (cmd)". Not a batch file,
  /// where % has other meanings.
  Cmd
}

///|
/// Reads the curl command in `text`, which is in the syntax of `shell`.
pub fn parse(
  text : StringView,
  shell~ : Shell = Posix,
) -> Parsed raise CurlError {
  let report = Report::{ found: [], }
  let words = match shell {
    Posix => posix_words(text, report)
    Cmd => cmd_words(text, report)
  }
  parse_words(words, report, windows=shell is Cmd)
}

///|
/// Reads a curl command that has been split into arguments already; the
/// first one is the program name. The arguments are taken literally, so
/// there are no variables.
pub fn parse_argv(arguments : ArrayView[String]) -> Parsed raise CurlError {
  let report = Report::{ found: [], }
  let words = arguments.mapi((i, text) => Word::{
    value: Value::literal(text),
    location: Argument(i),
  })
  parse_words(words, report, windows=false)
}

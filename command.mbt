///|
/// An option as it occurs on a command line.
priv struct Occurrence {
  /// The long name.
  name : String
  /// How it is written, such as `-X`.
  written : String
  value : Value
  /// `false` for `--no-NAME`.
  on : Bool
  /// Whether `--expand-NAME` asks to replace `{{name}}` in the value.
  expand : Bool
  /// Where the option is.
  location : Location
  /// Where its value is; that of the option if it has none.
  value_location : Location
}

///|
/// What an option of curl is called, and whether it takes a value.
priv struct OptionInfo {
  name : String
  takes_value : Bool
}

///|
let long_options : Map[String, OptionInfo] = Map([])

///|
let short_options : Map[Char, OptionInfo] = Map([])

///|
fn init {
  for line in option_data.split("\n") {
    let fields = line.split(" ").collect()
    let info = OptionInfo::{
      name: fields[0].to_owned(),
      takes_value: fields.length() == 3,
    }
    long_options[info.name] = info
    let letter = fields[1].get_char(0).unwrap()
    if letter != '.' {
      short_options[letter] = info
    }
  }
}

///|
/// What a custom header line does.
priv enum LineKind {
  /// Adds the field.
  Set(Value)
  /// Keeps curl from adding a field of this name.
  Remove
}

///|
/// A `-H` argument.
priv struct HeaderLine {
  name : String
  kind : LineKind
  location : Location
}

///|
/// What the options of a command add up to.
priv struct Settings {
  report : Report
  urls : Array[(Value, Location)]
  mut request : (String, Location)?
  mut head : Location?
  mut get : Bool
  header_lines : Array[HeaderLine]
  mut user_agent : (Value, Location)?
  mut referer : Value?
  cookies : Array[Value]
  mut cookie_engine : Bool
  mut user : Value?
  mut bearer : Value?
  mut range : (String, Location)?
  mut data : Value?
  mut data_location : Location?
  parts : Array[Part]
  mut upload : (String, Location)?
  url_queries : Array[(String, Location)]
  mut form_location : Location?
  /// Whether `\\` separates the parts of a path.
  windows : Bool
  mut json : Bool
  mut compressed : Bool
  mut follow : Bool
  mut location_trusted : Bool
  /// The codes of `--post301`, `--post302` and `--post303`.
  keep_post : Map[Int32, Location]
  mut max_redirects : Int32
  mut insecure : Bool
  mut proxy : (String, Location)?
  mut proxy_user : (Value, Location)?
  mut proxy_tunnel : Bool
  mut fail : Bool
  mut max_time_ms : Int32?
  mut retry_count : (Int32, Location)?
  mut retry_delay_ms : Int32?
  mut retry_max_time_ms : Int32?
  mut retry_all_errors : Bool
  mut retry_connrefused : Location?
  mut retry_details : Location?
  mut output : (OutputName, Location)?
  mut remote_name_all : Bool
  mut output_dir : String?
  mut create_dirs : Bool
  /// `--no-clobber`, where it is.
  mut no_clobber : Location?
  /// `--remove-on-error`, where it is.
  mut remove_on_error : Location?
  mut max_filesize : Int64?
  mut write_out : String?
  mut fail_with_body : Bool
  mut globoff : Bool
  mut path_as_is : Bool
  /// What `--variable` has set so far.
  variables : Map[String, Value]
}

///|
/// Options that only change what curl prints, saves or asks for, with what
/// they are about.
fn output_only(name : String) -> String? {
  match name {
    "silent"
    | "show-error"
    | "verbose"
    | "progress-bar"
    | "progress-meter"
    | "styled-output"
    | "stderr"
    | "trace"
    | "trace-ascii"
    | "trace-config"
    | "trace-ids"
    | "trace-time" => Some("what curl reports")
    "remote-time"
    | "create-file-mode"
    | "xattr"
    | "out-null"
    | "include"
    | "show-headers"
    | "dump-header"
    | "buffer"
    | "fail-early" => Some("where curl puts the response")
    "disable" => Some("which configuration files curl reads")
    "tcp-nodelay" | "keepalive" | "keepalive-time" | "keepalive-cnt" =>
      Some("how the connection is kept")
    "http1.1" | "http2" => Some("which version of HTTP is preferred")
    _ => None
  }
}

///|
/// Splits the arguments after the program name into options and URLs.
fn split_options(
  words : ArrayView[Word],
  report : Report,
) -> (Array[Occurrence], Array[(Value, Location)]) {
  let options : Array[Occurrence] = []
  let urls : Array[(Value, Location)] = []
  let mut only_urls = false
  for i = 0; i < words.length(); {
    let word = words[i]
    let prefix = word.value.prefix()
    if only_urls || prefix.length() == 0 || prefix[0] != b'-' {
      urls.push((word.value, word.location))
      continue i + 1
    }
    if word.value.to_text() is Some("--") {
      only_urls = true
      continue i + 1
    }
    let next = if prefix.length() > 1 && prefix[1] == b'-' {
      split_long(words, i, options, report)
    } else {
      split_short(words, i, options, report)
    }
    continue next
  }
  (options, urls)
}

///|
/// The value of an option whose word is `words[at]`, from the next word.
fn next_value(
  words : ArrayView[Word],
  at : Int32,
  written : String,
  report : Report,
) -> Word? {
  match words.get(at + 1) {
    Some(word) => Some(word)
    None => {
      report.error(
        "missing-value",
        "the option \{written} needs a value",
        location=words[at].location,
      )
      None
    }
  }
}

///|
/// Reads the long option `words[at]`. Returns the index after it.
fn split_long(
  words : ArrayView[Word],
  at : Int32,
  options : Array[Occurrence],
  report : Report,
) -> Int32 {
  let { value, location, } = words[at]
  // The name must be literal; a value after `=` may have variables.
  let (head, attached) = match value.split_once(b'=') {
    Some((head, rest)) => (head, Some(rest))
    None => (value, None)
  }
  let unknown = () => {
    report.error(
      "unknown-option",
      "curl has no such option",
      help="check the spelling; curl does not accept shortened names",
      location~,
    )
    at + 1
  }
  guard head.to_text() is Some(written) else { return unknown() }
  let name = written[2:].to_owned()
  let (info, on, expand) = match long_options.get(name) {
    Some(info) => (info, true, false)
    None =>
      match name.strip_prefix("no-") {
        Some(rest) =>
          match long_options.get(rest.to_owned()) {
            Some(info) if !info.takes_value => (info, false, false)
            _ => return unknown()
          }
        None =>
          match name.strip_prefix("expand-") {
            Some(rest) =>
              match long_options.get(rest.to_owned()) {
                Some(info) if info.takes_value => (info, true, true)
                _ => return unknown()
              }
            None => return unknown()
          }
      }
  }
  if !info.takes_value {
    if attached is Some(_) {
      report.error(
        "unexpected-value",
        "the option \{written} takes no value",
        location~,
      )
      return at + 1
    }
    options.push({
      name: info.name,
      written,
      value: Value::literal(""),
      on,
      expand,
      location,
      value_location: location,
    })
    return at + 1
  }
  if attached is Some(value) {
    options.push({
      name: info.name,
      written,
      value,
      on,
      expand,
      location,
      value_location: location,
    })
    return at + 1
  }
  guard next_value(words, at, written, report) is Some(word) else {
    return at + 1
  }
  options.push({
    name: info.name,
    written,
    value: word.value,
    on,
    expand,
    location,
    value_location: word.location,
  })
  at + 2
}

///|
/// Reads the letters of `words[at]`. Returns the index after the options.
fn split_short(
  words : ArrayView[Word],
  at : Int32,
  options : Array[Occurrence],
  report : Report,
) -> Int32 {
  let { value, location, } = words[at]
  let letters = value.prefix()
  if letters.length() == 1 {
    report.error(
      "unknown-option",
      "a single - is not an option of curl",
      location~,
    )
    return at + 1
  }
  for i in 1..<letters.length() {
    guard letters[i].to_int().to_char() is Some(letter) &&
      short_options.get(letter) is Some(info) else {
      report.error(
        "unknown-option",
        "curl has no option for a letter in this argument",
        location~,
      )
      return at + 1
    }
    let written = "-\{letter}"
    if !info.takes_value {
      options.push({
        name: info.name,
        written,
        value: Value::literal(""),
        on: true,
        expand: false,
        location,
        value_location: location,
      })
      continue
    }
    let rest = value.drop_bytes(i + 1)
    if !rest.is_empty() {
      options.push({
        name: info.name,
        written,
        value: rest,
        on: true,
        expand: false,
        location,
        value_location: location,
      })
      return at + 1
    }
    guard next_value(words, at, written, report) is Some(word) else {
      return at + 1
    }
    options.push({
      name: info.name,
      written,
      value: word.value,
      on: true,
      expand: false,
      location,
      value_location: word.location,
    })
    return at + 2
  }
  if value.env_names() is [_, ..] {
    report.error(
      "variable-in-option",
      "a variable cannot decide which options are used",
      location~,
    )
  }
  at + 1
}

///|
fn Settings::new(report : Report, windows~ : Bool) -> Settings {
  {
    report,
    urls: [],
    request: None,
    head: None,
    get: false,
    header_lines: [],
    user_agent: None,
    referer: None,
    cookies: [],
    cookie_engine: false,
    user: None,
    bearer: None,
    range: None,
    data: None,
    data_location: None,
    parts: [],
    upload: None,
    url_queries: [],
    form_location: None,
    windows,
    json: false,
    compressed: false,
    follow: false,
    location_trusted: false,
    keep_post: Map([]),
    max_redirects: default_max_redirects,
    insecure: false,
    proxy: None,
    proxy_user: None,
    proxy_tunnel: false,
    fail: false,
    max_time_ms: None,
    retry_count: None,
    retry_delay_ms: None,
    retry_max_time_ms: None,
    retry_all_errors: false,
    retry_connrefused: None,
    retry_details: None,
    output: None,
    remote_name_all: false,
    output_dir: None,
    create_dirs: false,
    no_clobber: None,
    remove_on_error: None,
    max_filesize: None,
    write_out: None,
    fail_with_body: false,
    globoff: false,
    path_as_is: false,
    variables: Map([]),
  }
}

///|
fn Settings::fail_at(
  self : Settings,
  option : Occurrence,
  code : String,
  message : String,
  help? : String,
) -> Unit {
  self.report.error(code, message, help?, location=option.value_location)
}

///|
/// The value of `option` as text; a variable is an error.
fn Settings::text(self : Settings, option : Occurrence) -> String? {
  match option.value.to_text() {
    Some(text) => Some(text)
    None => {
      self.fail_at(
        option,
        "variable-not-supported",
        "the value of \{option.written} must be known text",
        help="write the value out",
      )
      None
    }
  }
}

///|
/// The value of `option` as the value of a header field, or an error.
fn Settings::field_value(self : Settings, option : Occurrence) -> Value? {
  if option.value.is_field_value() {
    Some(option.value)
  } else {
    self.fail_at(
      option,
      "bad-header-value",
      "the value of \{option.written} has a control character or is not valid UTF-8",
      help="a header value is one line of text",
    )
    None
  }
}

///|
fn Settings::apply(self : Settings, option : Occurrence) -> Unit {
  if option.expand {
    if self.expand(option) is Some(value) {
      self.apply({ ..option, value, expand: false, })
    }
    return
  }
  if output_only(option.name) is Some(what) {
    self.report.add(
      Note,
      "no-effect-on-request",
      "\{option.written} only changes \{what}",
      location=option.location,
    )
    return
  }
  match option.name {
    "url" => self.urls.push((option.value, option.value_location))
    "request" => self.apply_request(option)
    "head" if option.on => self.head = Some(option.location)
    "get" => self.get = option.on
    "header" => self.apply_header(option)
    "user-agent" =>
      if self.field_value(option) is Some(value) {
        self.user_agent = Some((value, option.location))
      }
    "referer" =>
      if option.value.any_byte(b => b == b';') {
        self.fail_at(
          option, "unsupported-value", "a referer with ; is not supported, because ;auto has a meaning of its own to curl",
        )
      } else if self.field_value(option) is Some(value) {
        self.referer = if value.is_empty() { None } else { Some(value) }
      }
    "cookie" => self.apply_cookie(option)
    "user" => self.apply_user(option)
    "oauth2-bearer" =>
      if self.field_value(option) is Some(value) {
        if value.is_empty() {
          self.fail_at(option, "unsupported-value", "the token is empty")
        } else {
          self.bearer = Some(value)
        }
      }
    "basic" => ()
    "range" => self.apply_range(option)
    "data" | "data-ascii" | "data-binary" =>
      if option.value.prefix() is [b'@', ..] {
        let read = if option.name == "data-binary" {
          Whole
        } else {
          WithoutLineBreaks
        }
        self.add_file(option, option.value.drop_bytes(1), read, b"&")
      } else if option.value.pieces() is [Env(_), ..] {
        self.fail_at(
          option,
          "variable-may-name-file",
          "curl reads a file if the variable starts with @",
          help="use --data-raw instead of \{option.written}",
        )
      } else {
        self.add_data(option, option.value, b"&")
      }
    "data-raw" => self.add_data(option, option.value, b"&")
    "json" =>
      if option.value.prefix() is [b'@', ..] {
        self.json = true
        self.add_file(option, option.value.drop_bytes(1), Whole, b"")
      } else if option.value.pieces() is [Env(_), ..] {
        self.fail_at(
          option, "variable-may-name-file", "curl reads a file if the variable starts with @",
        )
      } else {
        self.json = true
        self.add_data(option, option.value, b"")
      }
    "data-urlencode" => self.apply_urlencode(option)
    "form" | "form-string" => self.apply_form(option)
    "upload-file" => self.apply_upload(option)
    "url-query" => self.apply_url_query(option)
    "compressed" => self.compressed = option.on
    "location" => self.follow = option.on
    // It turns -L on and off too.
    "location-trusted" => {
      self.follow = option.on
      self.location_trusted = option.on
    }
    "post301" | "post302" | "post303" => {
      let code = if option.name == "post301" {
        301
      } else if option.name == "post302" {
        302
      } else {
        303
      }
      if option.on {
        self.keep_post[code] = option.location
      } else {
        self.keep_post.remove(code)
      }
    }
    "max-redirs" => self.apply_max_redirs(option)
    "insecure" => self.insecure = option.on
    "proxy" =>
      if self.text(option) is Some(text) {
        self.proxy = Some((text, option.value_location))
      }
    "proxy-user" => self.apply_proxy_user(option)
    "proxytunnel" => self.proxy_tunnel = option.on
    // The default of curl, and the only kind of proxy authentication here.
    "proxy-basic" => ()
    "fail" => self.fail = option.on
    "fail-with-body" => self.fail_with_body = option.on
    "output" => self.apply_output(option)
    "remote-name" if option.on => self.apply_output(option)
    // --no-remote-name turns off --remote-name-all.
    "remote-name" | "remote-name-all" => self.remote_name_all = option.on
    "output-dir" =>
      if self.text(option) is Some(text) {
        if text == "" {
          self.fail_at(option, "unsupported-value", "the directory is empty")
        } else {
          self.output_dir = Some(text)
        }
      }
    "create-dirs" => self.create_dirs = option.on
    // --no-clobber turns it off.
    "clobber" =>
      self.no_clobber = if option.on { None } else { Some(option.location) }
    "remove-on-error" =>
      self.remove_on_error = if option.on {
        Some(option.location)
      } else {
        None
      }
    "max-filesize" => self.apply_max_filesize(option)
    "write-out" => self.apply_write_out(option)
    "max-time" => self.apply_max_time(option)
    "retry" | "retry-delay" | "retry-max-time" => self.apply_retry(option)
    "retry-all-errors" => {
      self.retry_all_errors = option.on
      self.retry_details = Some(option.location)
    }
    "retry-connrefused" =>
      self.retry_connrefused = if option.on {
        Some(option.location)
      } else {
        None
      }
    "variable" => self.apply_variable(option)
    "globoff" => self.globoff = option.on
    "path-as-is" => self.path_as_is = option.on
    "config" =>
      self.report.error(
        "unsupported-option",
        "\{option.written} is not supported, because the file is read when curl runs",
        help="read the file with parse_config, as curl2mbt --config FILE does",
        location=option.location,
      )
    _ =>
      self.report.error(
        "unsupported-option",
        "\{option.written} is not supported",
        location=option.location,
      )
  }
}

///|
fn Settings::reject_file(self : Settings, option : Occurrence) -> Unit {
  self.fail_at(
    option,
    "file-not-supported",
    "reading header fields from a file is not supported",
    help="put them in the command",
  )
}

///|
/// Adds the data of the file that `path` names.
fn Settings::add_file(
  self : Settings,
  option : Occurrence,
  path : Value,
  read : FileRead,
  separator : Bytes,
) -> Unit {
  guard path.to_text() is Some(path) && !path.contains("\u0000") else {
    self.fail_at(
      option,
      "variable-not-supported",
      "the name of the file must be known text",
      help="write the name out; with --data-raw a leading @ is data",
    )
    return
  }
  if path is ("" | "-") {
    self.fail_at(
      option,
      "file-not-supported",
      if path == "" {
        "there is no name of a file after the @"
      } else {
        "reading the standard input is not supported"
      },
      help="name a file; with --data-raw a leading @ is data",
    )
    return
  }
  let value = Value::from_pieces([File(path~, read~)])
  self.add_data(option, value, separator)
}

///|
fn Settings::add_data(
  self : Settings,
  option : Occurrence,
  value : Value,
  separator : Bytes,
) -> Unit {
  self.data_location = Some(option.location)
  self.data = match self.data {
    None => Some(value)
    // curl adds no separator to data that is still empty.
    Some(before) if before.is_empty() => Some(value)
    Some(before) if separator.length() > 0 && !before.any_byte(_ => true) => {
      self.fail_at(
        option,
        "data-may-be-empty",
        "curl adds & before this unless the variable or file before it is empty, which is not known here",
        help="put data that is never empty first",
      )
      self.data
    }
    Some(before) =>
      Some(
        before.append(Value::from_pieces([Literal(separator)])).append(value),
      )
  }
}

///|
fn Settings::apply_request(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(text) else { return }
  if is_token(text) {
    self.request = Some((text, option.value_location))
  } else {
    self.fail_at(option, "bad-method", "the method is not an HTTP token")
  }
}

///|
fn Settings::apply_header(self : Settings, option : Occurrence) -> Unit {
  if option.value.prefix() is [b'@', ..] {
    self.reject_file(option)
    return
  }
  let ignored = () => {
    self.report.add(
      Warning,
      "ignored-header",
      "curl ignores a header without a colon and a value",
      help="write \"Name: value\"; \"Name;\" sends the field with an empty value",
      location=option.value_location,
    )
  }
  match option.value.split_once(b':') {
    Some((name, rest)) => {
      guard name.to_text() is Some(name) && is_token(name) else {
        self.fail_at(
          option, "bad-header-name", "what is before the colon is not the name of a header field",
        )
        return
      }
      guard rest.is_field_value() else {
        self.fail_at(
          option,
          "bad-header-value",
          "the value of the header field has a control character or is not valid UTF-8",
          help="a header value is one line of text",
        )
        return
      }
      let value = rest.trim()
      let kind = if value.is_empty() { Remove } else { Set(value) }
      self.add_header_line(name, kind, option)
    }
    None => {
      // `Name;` sends an empty field.
      guard option.value.to_text() is Some(text) else {
        self.fail_at(
          option,
          "variable-not-supported",
          "a variable cannot hold a whole header field",
          help="write \"Name: $VALUE\"",
        )
        return
      }
      if text.strip_suffix(";") is Some(name) && is_token(name) {
        self.add_header_line(name.to_owned(), Set(Value::literal("")), option)
      } else {
        ignored()
      }
    }
  }
}

///|
/// Adds a header line, unless it changes how the message is framed.
fn Settings::add_header_line(
  self : Settings,
  name : String,
  kind : LineKind,
  option : Occurrence,
) -> Unit {
  match (name.to_lower(), kind) {
    ("content-length", _) =>
      self.fail_at(
        option,
        "framing-header",
        "setting Content-Length by hand is not supported",
        help="remove it; the length of the body is sent anyway",
      )
    ("transfer-encoding", _) =>
      self.fail_at(
        option, "framing-header", "setting Transfer-Encoding is not supported",
      )
    ("host", Remove) =>
      self.fail_at(
        option, "framing-header", "a request without a Host field is not supported",
      )
    ("host", Set(value)) if value.is_empty() ||
      self.header_lines.iter().any(line => same_name(line.name, name)) =>
      self.fail_at(
        option, "framing-header", "an empty or second Host field is not supported",
      )
    _ =>
      self.header_lines.push({ name, kind, location: option.value_location, })
  }
}

///|
fn Settings::apply_cookie(self : Settings, option : Occurrence) -> Unit {
  let has_equals = option.value.any_byte(b => b == b'=')
  if option.value.prefix() is [b'@', ..] ||
    (!has_equals && !option.value.is_empty()) {
    self.fail_at(
      option,
      "file-not-supported",
      "curl reads cookies from a file here, which is not supported",
      help="write the cookies as \"name=value; other=value\"",
    )
    return
  }
  if option.value.pieces() is [Env(_), ..] {
    self.fail_at(
      option,
      "variable-may-name-file",
      "curl reads a file if the variable starts with @",
      help="use -H \"Cookie: ...\"",
    )
    return
  }
  self.cookie_engine = true
  if self.field_value(option) is Some(value) && !value.is_empty() {
    self.cookies.push(value)
  }
}

///|
fn Settings::apply_user(self : Settings, option : Occurrence) -> Unit {
  if option.value.split_once(b':') is None {
    self.fail_at(
      option,
      "password-prompt",
      "curl asks for the password, because the value has no colon",
      help="write \"user:password\"; \"user:\" for an empty password",
    )
    return
  }
  self.user = Some(option.value)
}

///|
fn Settings::apply_range(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(text) else { return }
  if text != "" &&
    text.iter().all(c => is_digit(c) || c is ('-' | ',')) &&
    text.iter().any(is_digit) {
    // curl reads a lone number as the first byte to get.
    let range = if text.iter().all(is_digit) { "\{text}-" } else { text }
    self.range = Some((range, option.value_location))
  } else {
    self.fail_at(
      option, "unsupported-value", "a range is made of numbers, - and ,",
    )
  }
}

///|
fn Settings::apply_urlencode(self : Settings, option : Occurrence) -> Unit {
  if option.value.env_names() is [_, ..] {
    self.fail_at(
      option,
      "variable-not-supported",
      "the value of \{option.written} must be known text to be encoded",
      help="write the value out",
    )
    return
  }
  // The name ends at the first `=` or, if there is none, at the first `@`.
  let bytes = option.value.to_bytes().unwrap_or(b"")
  let encoded = match index_of(bytes, b => b == b'=') {
    Some(0) => form_encode(bytes[1:].to_owned())
    Some(at) =>
      bytes[:at + 1].to_owned() + form_encode(bytes[at + 1:].to_owned())
    None =>
      match option.value.split_once(b'@') {
        Some((name, path)) => {
          guard name.to_text() is Some(name) else {
            self.fail_at(
              option, "unsupported-value", "the name before the @ is not valid UTF-8",
            )
            return
          }
          self.add_file(option, path, FormEncoded(name), b"&")
          return
        }
        None => form_encode(bytes)
      }
  }
  self.add_data(option, Value::from_pieces([Literal(encoded)]), b"&")
}

///|
fn Settings::apply_max_redirs(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(text) else { return }
  if text != "" && text.length() <= 6 && text.iter().all(is_digit) {
    self.max_redirects = text
      .iter()
      .fold(init=0, (n, c) => n * 10 + (c.to_int() - '0'))
  } else {
    self.fail_at(
      option, "unsupported-value", "the number of redirects must be between 0 and 999999",
    )
  }
}

///|
fn Settings::apply_max_time(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(text) else { return }
  match parse_milliseconds(text) {
    Some(0) => self.max_time_ms = None
    Some(ms) => self.max_time_ms = Some(ms)
    None =>
      self.fail_at(
        option, "unsupported-value", "the time must be a number of seconds with at most three decimals, up to 999999",
      )
  }
}

///|
/// Seconds such as `1.5` as milliseconds.
fn parse_milliseconds(text : String) -> Int32? {
  let (whole, fraction) = match text.find(".") {
    Some(at) => (text[:at], text[at + 1:])
    None => (text[:], text[:0])
  }
  if whole.is_empty() ||
    whole.length() > 6 ||
    fraction.length() > 3 ||
    (text.contains(".") && fraction.is_empty()) ||
    !whole.iter().all(is_digit) ||
    !fraction.iter().all(is_digit) {
    return None
  }
  let padded = whole.to_owned() +
    fraction.to_owned() +
    "0".repeat(3 - fraction.length())
  Some(padded.iter().fold(init=0, (n, c) => n * 10 + (c.to_int() - '0')))
}

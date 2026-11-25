///|
/// The URL of a request, as curl uses it: without user information, fragment
/// and default port, and with `.` and `..` segments resolved.
#derive(Eq, Debug)
pub struct Url {
  /// `http` or `https`.
  scheme : String
  /// A name, an IPv4 address or an IPv6 address in brackets, as written.
  host : String
  /// `None` for the default port of the scheme.
  port : Int32?
  /// Starts with `/`.
  path : String
  /// Without the `?`. Never empty.
  query : String?
}

///|
/// The URL as text.
pub fn Url::to_string(self : Url) -> String {
  "\{self.scheme}://\{self.authority()}\{self.target()}"
}

///|
/// The host and port, as in the Host header field.
pub fn Url::authority(self : Url) -> String {
  match self.port {
    Some(port) => "\{self.host}:\{port}"
    None => self.host
  }
}

///|
/// The path and query, as in the request line.
pub fn Url::target(self : Url) -> String {
  match self.query {
    Some(query) => "\{self.path}?\{query}"
    None => self.path
  }
}

///|
/// Why a URL was rejected.
priv struct UrlProblem {
  code : String
  message : String
  help : String?
}

///|
priv suberror UrlError {
  UrlError(UrlProblem)
}

///|
fn[T] bad_url(
  message : String,
  help? : String,
  code~ : String = "bad-url",
) -> T raise UrlError {
  raise UrlError({ code, message, help, })
}

///|
/// A URL as given on the command line.
priv struct ParsedUrl {
  url : Url
  /// `user` and `password` of `user:password@`, still percent-encoded.
  user_info : (String, String)?
  /// Whether the scheme was left out.
  guessed_scheme : Bool
}

///|
fn parse_url(
  text : String,
  globbing~ : Bool,
  path_as_is~ : Bool,
) -> ParsedUrl raise UrlError {
  if text == "" {
    bad_url("the URL is empty")
  }
  for char in text {
    if char <= ' ' || char == '\u007F' {
      bad_url(
        "curl rejects a URL with a space or a control character",
        help="percent-encode it: a space is %20",
      )
    }
    if char > '\u007F' {
      bad_url(
        "what curl sends for a character outside ASCII in a URL depends on the system",
        help="percent-encode the character; write an internationalized host name in its xn-- form",
      )
    }
    if char == '\\' {
      bad_url(
        "clients disagree about a backslash in a URL",
        help="write / or %5C",
      )
    }
  }
  let (scheme, rest, guessed_scheme) = split_scheme(text)
  let authority_end = rest
    .find_by(c => c is ('/' | '?' | '#'))
    .unwrap_or(rest.length())
  let authority = rest[:authority_end]
  let tail = rest[authority_end:]
  let (user_info, host_port) = match authority.rev_find("@") {
    Some(at) => {
      let info = authority[:at]
      let pair = match info.find(":") {
        Some(colon) => (info[:colon].to_owned(), info[colon + 1:].to_owned())
        None => (info.to_owned(), "")
      }
      (Some(pair), authority[at + 1:])
    }
    None => (None, authority)
  }
  let (host, port) = parse_host(host_port)
  if globbing &&
    (
      tail.iter().any(is_glob_char) ||
      (
        user_info is Some((user, password)) &&
        (user + password).iter().any(is_glob_char)
      )
    ) {
    bad_url(
      "curl expands {} and [] in a URL into several requests",
      help="replace placeholders by values; for literal braces or brackets use -g or percent-encode them",
      code="url-globbing",
    )
  }
  let tail = match tail.find("#") {
    Some(at) => tail[:at]
    None => tail
  }
  let (path, query) = match tail.find("?") {
    Some(at) =>
      (
        tail[:at],
        if at + 1 < tail.length() {
          Some(tail[at + 1:].to_owned())
        } else {
          None
        },
      )
    None => (tail, None)
  }
  let path = if path.is_empty() {
    "/"
  } else if path_as_is {
    path.to_owned()
  } else {
    remove_dot_segments(path)
  }
  let default_port = if scheme == "https" { 443 } else { 80 }
  let port = if port == Some(default_port) { None } else { port }
  { url: { scheme, host, port, path, query, }, user_info, guessed_scheme, }
}

///|
fn is_glob_char(char : Char) -> Bool {
  char is ('{' | '}' | '[' | ']')
}

///|
fn is_alpha(char : Char) -> Bool {
  char is ('a'..<='z' | 'A'..<='Z')
}

///|
fn is_digit(char : Char) -> Bool {
  char is ('0'..<='9')
}

///|
/// The scheme, what follows it, and whether the scheme is a guess.
fn split_scheme(text : String) -> (String, StringView, Bool) raise UrlError {
  if text.find(":/") is Some(at) && at > 0 {
    let scheme = text[:at].to_owned()
    if scheme
      .iter()
      .all(c => is_alpha(c) || is_digit(c) || c is ('+' | '-' | '.')) &&
      is_alpha(scheme.iter().head().unwrap()) {
      let scheme = scheme.to_lower()
      if !(scheme is ("http" | "https")) {
        bad_url(
          "only http and https URLs are supported",
          code="unsupported-protocol",
        )
      }
      let rest = text[at + 1:]
      guard rest.strip_prefix("//") is Some(rest) else {
        bad_url("the scheme is not followed by //")
      }
      if rest.has_prefix("/") {
        bad_url("the URL has no host name")
      }
      return (scheme, rest, false)
    }
  }
  let lower = text.to_lower()
  for prefix in ["ftp.", "dict.", "ldap.", "imap.", "smtp.", "pop3."] {
    if lower.has_prefix(prefix) {
      bad_url(
        "without a scheme, curl guesses the protocol from a host name that starts with \{prefix}",
        help="write the URL with https://",
        code="unsupported-protocol",
      )
    }
  }
  ("http", text[:], true)
}

///|
fn parse_host(text : StringView) -> (String, Int32?) raise UrlError {
  let (host, port) = if text.has_prefix("[") {
    guard text.find("]") is Some(close) else {
      bad_url("the bracket of an IPv6 address is not closed")
    }
    let address = text[1:close]
    if !address.contains(":") ||
      !address
      .iter()
      .all(c => is_digit(c) || c is ('a'..<='f' | 'A'..<='F' | ':' | '.')) {
      bad_url("the brackets do not hold an IPv6 address without a zone")
    }
    let rest = text[close + 1:]
    if rest.is_empty() {
      (text[:close + 1], text[:0])
    } else if rest.has_prefix(":") {
      (text[:close + 1], rest[1:])
    } else {
      bad_url("an IPv6 address is followed by something other than a port")
    }
  } else {
    let (host, port) = match text.find(":") {
      Some(colon) => (text[:colon], text[colon + 1:])
      None => (text, text[:0])
    }
    check_host(host)
    (host, port)
  }
  if port.is_empty() {
    return (host.to_owned(), None)
  }
  if !port.iter().all(is_digit) || port.length() > 9 {
    bad_url("the port is not a number")
  }
  let number = port.iter().fold(init=0, (n, c) => n * 10 + (c.to_int() - '0'))
  if number < 1 || number > 65535 {
    bad_url("the port is not between 1 and 65535")
  }
  (host.to_owned(), Some(number))
}

///|
fn check_host(host : StringView) -> Unit raise UrlError {
  if host.is_empty() {
    bad_url("the URL has no host name")
  }
  if !host.iter().all(c => is_alpha(c) || is_digit(c) || c is ('.' | '-' | '_')) {
    bad_url(
      "the host name has a character other than letters, digits, '.', '-' and '_'",
    )
  }
  let labels = host.split(".").collect()
  if labels.iter().any(label => label.is_empty()) {
    bad_url("the host name has an empty label")
  }
  // curl reads names like these as IPv4 addresses in unusual notations.
  let last = labels[labels.length() - 1]
  let numeric = last.iter().all(is_digit) ||
    last.to_owned().to_lower().has_prefix("0x")
  if numeric {
    let strict = labels.length() == 4 &&
      labels
      .iter()
      .all(label => {
        label.length() <= 3 &&
        label.iter().all(is_digit) &&
        (label.length() == 1 || !label.has_prefix("0")) &&
        label.iter().fold(init=0, (n, c) => n * 10 + (c.to_int() - '0')) <= 255
      })
    if !strict {
      bad_url(
        "the host is an IPv4 address in an unusual notation",
        help="write the address as four decimal numbers",
      )
    }
  }
}

///|
/// `.` and `..`, also percent-encoded, in the way curl resolves them.
fn remove_dot_segments(path : StringView) -> String {
  let out : Array[String] = []
  let segments = path.split("/").collect()
  // The path starts with "/", so the first segment is empty.
  for i in 1..<segments.length() {
    let segment = segments[i].to_owned()
    let last = i + 1 == segments.length()
    match segment.to_lower().replace_all(old="%2e", new=".") {
      "." => if last { out.push("") }
      ".." => {
        ignore(out.pop())
        if last {
          out.push("")
        }
      }
      _ => out.push(segment)
    }
  }
  "/" + out.join("/")
}

///|
/// The bytes of `text` with each `%HH` decoded.
fn percent_decode(text : String) -> Bytes {
  let bytes = @utf8.encode(text)
  let out : Array[Byte] = []
  for i = 0; i < bytes.length(); {
    if bytes[i] == b'%' &&
      i + 2 < bytes.length() &&
      hex_digit(bytes[i + 1].to_uint16()) is Some(high) &&
      hex_digit(bytes[i + 2].to_uint16()) is Some(low) {
      out.push((high * 16 + low).to_byte())
      continue i + 3
    }
    out.push(bytes[i])
    continue i + 1
  }
  Bytes::from_array(out)
}

///|
/// `bytes` encoded as `--data-urlencode` does: a space becomes `+`, and
/// everything but letters, digits and `-._~` becomes `%HH`.
fn form_encode(bytes : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let digits = b"0123456789ABCDEF"
  for byte in bytes {
    match byte {
      b'A'..<=b'Z' | b'a'..<=b'z' | b'0'..<=b'9' | b'-' | b'.' | b'_' | b'~' =>
        out.push(byte)
      b' ' => out.push(b'+')
      _ => {
        out.push(b'%')
        out.push(digits[byte.to_int() / 16])
        out.push(digits[byte.to_int() % 16])
      }
    }
  }
  Bytes::from_array(out)
}

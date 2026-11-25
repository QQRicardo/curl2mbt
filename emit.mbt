///|
/// The library that the emitted program makes the request with.
#derive(Eq, Debug)
pub(all) enum Target {
  /// `moonbitlang/async/http` of moonbitlang/async 0.22, on native and wasm.
  Async
}

///|
/// What becomes of passwords, tokens and cookies that the command holds.
#derive(Eq, Debug)
pub(all) enum Secrets {
  /// The emitted program reads them from environment variables.
  FromEnv
  /// They are written into the emitted program.
  Inline
}

///|
/// A MoonBit program that makes a request.
#derive(Eq, Debug)
pub struct Emitted {
  /// The source of a main package.
  code : String
  /// The packages the source uses, to be imported in its `moon.pkg`.
  imports : Array[String]
  /// The environment variables the program reads, in order.
  environment : Array[String]
  /// Warnings and notes about the program.
  diagnostics : Array[Diagnostic]
}

///|
/// The library of the target cannot make the request. Holds every reason.
#derive(Debug)
pub suberror EmitError {
  EmitError(Array[Diagnostic])
}

///|
/// Writes the program for one plan.
priv struct Emitter {
  plan : RequestPlan
  report : Report
  /// The environment variables in use, with the name of the variable of the
  /// program that holds each.
  environment : Map[String, String]
  imports : Map[String, Unit]
  /// The functions of `helper_code` in use.
  helpers : Map[String, Unit]
}

///|
/// Field names whose values are kept out of programs, in lower case.
let secret_fields : Array[String] = [
  "authorization", "proxy-authorization", "cookie", "x-api-key", "api-key", "apikey",
  "x-auth-token", "x-access-token", "x-csrf-token", "x-xsrf-token", "private-token",
  "x-goog-api-key", "x-amz-security-token",
]

///|
/// Query parameters that tend to hold secrets, in lower case.
let secret_parameters : Array[String] = [
  "access_token", "api_key", "apikey", "api-key", "auth", "client_secret", "key",
  "password", "secret", "sig", "signature", "token", "x-amz-signature",
]

///|
fn Emitter::reject(
  self : Emitter,
  code : String,
  message : String,
  help? : String,
) -> Unit {
  self.report.error(code, message, help?)
}

///|
fn Emitter::import_package(self : Emitter, name : String) -> Unit {
  self.imports[name] = ()
}

///|
/// The variable of the program that holds the environment variable `name`.
fn Emitter::variable(self : Emitter, name : String) -> String {
  if self.environment.get(name) is Some(variable) {
    return variable
  }
  let base = "env_\{name.to_lower()}"
  let mut variable = base
  let mut number = 2
  while self.environment.values().any(used => used == variable) {
    variable = "\{base}_\{number}"
    number += 1
  }
  self.environment[name] = variable
  variable
}

///|
/// An environment variable for a secret that is not one of the command.
fn Emitter::fresh_environment(self : Emitter, base : String) -> String {
  let used = self.plan_environment()
  let mut name = base
  let mut number = 2
  while used.contains(name) || self.environment.contains(name) {
    name = "\{base}_\{number}"
    number += 1
  }
  name
}

///|
/// The environment variables the command refers to.
fn Emitter::plan_environment(self : Emitter) -> Array[String] {
  let names : Array[String] = []
  for header in self.plan.headers {
    names.append(header.value.env_names())
  }
  match self.plan.auth {
    Some(Basic(value) | Bearer(value)) => names.append(value.env_names())
    None => ()
  }
  match self.plan.body {
    Some(Data(value)) => names.append(value.env_names())
    Some(Multipart(parts)) =>
      for part in parts {
        names.append(part.content.env_names())
      }
    None => ()
  }
  names
}

///|
/// The contents of a string literal for `text`, without the quotes.
fn escape_text(text : String) -> String {
  let buf = StringBuilder()
  for char in text {
    match char {
      '\\' => buf.write_string("\\\\")
      '"' => buf.write_string("\\\"")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ =>
        if is_plain(char) {
          buf.write_char(char)
        } else {
          buf.write_string("\\u{\{hex(char.to_int())}}")
        }
    }
  }
  buf.to_string()
}

///|
/// Whether `char` shows as itself in source code: no control or format
/// characters, and nothing that changes the direction of text.
fn is_plain(char : Char) -> Bool {
  let code = char.to_int()
  !(code < 0x20 ||
  code is (0x7F..<=0x9F) ||
  code is (0xAD | 0x61C | 0xFEFF) ||
  code is (0x200B..<=0x200F) ||
  code is (0x2028..<=0x202E) ||
  code is (0x2060..<=0x206F) ||
  code is (0xE000..<=0xF8FF) ||
  code is (0xFFF0..<=0xFFFB) ||
  code >= 0xE0000)
}

///|
fn hex(value : Int32) -> String {
  let digits = "0123456789abcdef"
  let out : Array[Char] = []
  for rest = value; rest > 0 || out.is_empty(); rest = rest / 16 {
    out.push(digits[rest % 16].unsafe_to_char())
  }
  out.rev_in_place()
  String::from_array(out)
}

///|
/// An expression of type String for `value`, or `None` if a part of it is
/// not text, or a file.
fn Emitter::string_expression(self : Emitter, value : Value) -> String? {
  let buf = StringBuilder()
  buf.write_char('"')
  for piece in value.pieces {
    match piece {
      Literal(_) => {
        guard Value::from_pieces([piece]).to_text() is Some(text) else {
          return None
        }
        buf.write_string(escape_text(text))
      }
      Env(name) => buf.write_string("\\{\{self.variable(name)}}")
      File(_) => return None
    }
  }
  buf.write_char('"')
  Some(buf.to_string())
}

///|
/// An expression of type Bytes for `bytes`.
fn bytes_expression(bytes : Bytes) -> String {
  let buf = StringBuilder()
  buf.write_string("b\"")
  for byte in bytes {
    match byte {
      b'\\' => buf.write_string("\\\\")
      b'"' => buf.write_string("\\\"")
      b'\n' => buf.write_string("\\n")
      _ =>
        if byte >= 0x20 && byte < 0x7F {
          buf.write_char(byte.to_char())
        } else {
          let digits = hex(byte.to_int())
          buf.write_string("\\x\{if byte < 0x10 { "0" } else { "" }}\{digits}")
        }
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// Whether `text` reads better as lines of `#|`.
fn fits_raw_lines(text : String) -> Bool {
  (text.contains("\"") || text.contains("\n") || text.contains("\\")) &&
  text.iter().all(char => char == '\n' || is_plain(char))
}

///|
/// The statements that define `body`, the bytes of the request body.
fn Emitter::body_statements(
  self : Emitter,
  value : Value,
  out : Array[String],
) -> Unit {
  if value.to_text() is Some(text) && fits_raw_lines(text) {
    self.import_package("moonbitlang/core/encoding/utf8")
    out.push("  let text =")
    for line in text.split("\n") {
      out.push("    #|\{line}")
    }
    out.push("  let body = @utf8.encode(text)")
  } else {
    out.push("  let body = \{self.bytes_value(value)}")
  }
}

///|
/// An expression of type Bytes for `value`.
fn Emitter::bytes_value(self : Emitter, value : Value) -> String {
  if value.to_bytes() is Some(bytes) &&
    (value.to_text() is None || bytes.iter().all(byte => byte < 0x80)) {
    return bytes_expression(bytes)
  }
  if !value.has_file() && self.string_expression(value) is Some(text) {
    self.import_package("moonbitlang/core/encoding/utf8")
    return "@utf8.encode(\{text})"
  }
  let parts = value.pieces.map(piece => {
    match piece {
      Literal(bytes) => bytes_expression(bytes)
      Env(name) => {
        self.import_package("moonbitlang/core/encoding/utf8")
        "@utf8.encode(\{self.variable(name)})"
      }
      File(path~, read~) => {
        self.import_package("moonbitlang/async/fs")
        let file = "@fs.read_file(\"\{escape_text(path)}\").binary()"
        match read {
          Whole => file
          WithoutLineBreaks => {
            self.helpers["without_line_breaks"] = ()
            "without_line_breaks(\{file})"
          }
          FormEncoded(name) => {
            self.helpers["form_encoded"] = ()
            "form_encoded(\{bytes_expression(@utf8.encode(name))}, \{file})"
          }
        }
      }
    }
  })
  parts.join(" + ")
}

///|
/// The statements that define `boundary` and `body` for a form.
fn Emitter::form_statements(
  self : Emitter,
  parts : Array[Part],
  out : Array[String],
) -> Unit {
  self.helpers["form_data"] = ()
  self.import_package("moonbitlang/core/encoding/utf8")
  out.push("  let (boundary, body) = form_data([")
  for part in parts {
    out.push("    (")
    out.push("      \"\{escape_text(part.header_text())}\",")
    out.push("      \{self.bytes_value(part.content)},")
    out.push("    ),")
  }
  out.push("  ])")
}

///|
/// Functions that programs use for files and forms.
let helper_code : Array[(String, String)] = [
  (
    "without_line_breaks",
    (
      #|///|
      #|/// What curl -d sends of a file.
      #|fn without_line_breaks(bytes : Bytes) -> Bytes {
      #|  let kept = bytes
      #|    .iter()
      #|    .filter(byte => byte != b'\n' && byte != b'\r' && byte != b'\x00')
      #|  Bytes::from_array(kept.collect())
      #|}
      #|
    ),
  ),
  (
    "form_encoded",
    (
      #|///|
      #|/// What curl --data-urlencode sends of a file.
      #|fn form_encoded(name : Bytes, bytes : Bytes) -> Bytes {
      #|  guard bytes.length() > 0 else { return b"" }
      #|  let out : Array[Byte] = name.to_array()
      #|  if name.length() > 0 {
      #|    out.push(b'=')
      #|  }
      #|  let digits = b"0123456789ABCDEF"
      #|  for byte in bytes {
      #|    match byte {
      #|      b'A'..<=b'Z' | b'a'..<=b'z' | b'0'..<=b'9' | b'-' | b'.' | b'_' | b'~' =>
      #|        out.push(byte)
      #|      b' ' => out.push(b'+')
      #|      _ => {
      #|        out.push(b'%')
      #|        out.push(digits[byte.to_int() / 16])
      #|        out.push(digits[byte.to_int() % 16])
      #|      }
      #|    }
      #|  }
      #|  Bytes::from_array(out)
      #|}
      #|
    ),
  ),
  (
    "form_data",
    (
      #|///|
      #|/// A multipart form of header fields and contents, and the boundary, which
      #|/// does not occur in any of them.
      #|fn form_data(parts : Array[(String, Bytes)]) -> (String, Bytes) {
      #|  let mut boundary = "------------------------form"
      #|  while parts
      #|        .iter()
      #|        .any(part => {
      #|          part.0.contains(boundary) ||
      #|          part.1.find(@utf8.encode(boundary)) is Some(_)
      #|        }) {
      #|    boundary = boundary + "0"
      #|  }
      #|  let mut body = b""
      #|  for part in parts {
      #|    body = body +
      #|      @utf8.encode("--\{boundary}\r\n\{part.0}\r\n\r\n") +
      #|      part.1 +
      #|      b"\r\n"
      #|  }
      #|  (boundary, body + @utf8.encode("--\{boundary}--\r\n"))
      #|}
      #|
    ),
  ),
]

///|
/// The value to use for a field or credential that holds a secret: one that
/// reads the variable `base` in place of literal text.
fn Emitter::lift(
  self : Emitter,
  value : Value,
  base : String,
  what : String,
) -> Value {
  if value.to_bytes() is None || value.is_empty() {
    return value
  }
  let name = self.fresh_environment(base)
  ignore(self.variable(name))
  self.report.add(
    Note,
    "secret-from-environment",
    "the program reads \{what} from the environment variable \{name}",
  )
  Value::from_pieces([Env(name)])
}

///|
/// The header field with its secret, if any, read from the environment.
fn Emitter::lift_header(self : Emitter, header : Header) -> Header {
  let lower = header.name.to_lower()
  if !secret_fields.contains(lower) {
    return header
  }
  let base = header.name
    .to_upper()
    .iter()
    .map(char => if is_alpha(char) || is_digit(char) { char } else { '_' })
    .collect()
  let base = String::from_array(base)
  let base = if is_digit(base.get_char(0).unwrap()) { "_\{base}" } else { base }
  // `Bearer TOKEN`: the scheme is no secret.
  if lower == "authorization" &&
    header.value.split_once(b' ') is Some((scheme, rest)) &&
    scheme.to_text() is Some(text) &&
    is_token(text) &&
    rest.to_bytes() is Some(_) {
    let name = match text.to_lower() {
      "bearer" => "BEARER_TOKEN"
      "basic" => "BASIC_CREDENTIALS"
      _ => "AUTHORIZATION_VALUE"
    }
    let rest = self.lift(rest, name, "what follows \{text} in Authorization")
    return { ..header, value: scheme.append(Value::literal(" ")).append(rest), }
  }
  { ..header, value: self.lift(header.value, base, header.name), }
}

///|
/// The name of the method in `@http.RequestMethod`.
fn async_method(name : String) -> String? {
  match name {
    "GET" => Some("Get")
    "HEAD" => Some("Head")
    "POST" => Some("Post")
    "PUT" => Some("Put")
    "DELETE" => Some("Delete")
    "OPTIONS" => Some("Options")
    "TRACE" => Some("Trace")
    "PATCH" => Some("Patch")
    _ => None
  }
}

///|
/// The header fields of the program, after checking that the library sends
/// them as they are.
fn Emitter::checked_headers(self : Emitter) -> Array[Header] {
  let out : Array[Header] = []
  let seen : Map[String, Unit] = Map([])
  for header in self.plan.headers {
    let lower = header.name.to_lower()
    if seen.contains(lower) {
      self.reject(
        "duplicate-header",
        "moonbitlang/async sends a field only once, and \{header.name} occurs twice",
        help="join the values with a comma if the field is a list",
      )
      continue
    }
    seen[lower] = ()
    match lower {
      "host" => {
        self.reject(
          "unsupported-header", "moonbitlang/async always takes Host from the URL",
        )
        continue
      }
      "te" if header.value.to_text() != Some("trailers") =>
        self.reject(
          "unsupported-header", "moonbitlang/async does not decode transfer codings, so TE is not supported",
        )
      "upgrade" =>
        self.reject(
          "unsupported-header", "a request that changes the protocol is not supported",
        )
      "accept-encoding" if self.plan.compressed => {
        self.report.add(
          Warning,
          "accept-encoding",
          "moonbitlang/async chooses Accept-Encoding itself when it decompresses, so that of the command is left out",
        )
        continue
      }
      _ => ()
    }
    out.push(header)
  }
  if self.plan.compressed {
    self.report.add(
      Note,
      "compressed",
      "the program offers gzip only, and decompresses it",
    )
  } else if seen.contains("range") && !seen.contains("accept-encoding") {
    // The library would ask for compressed data, whose ranges are others.
    out.push({
      name: "Accept-Encoding",
      value: Value::literal("identity"),
      implied: true,
    })
  }
  out
}

///|
/// The parts of the target program that depend on the options.
fn Emitter::check_plan(self : Emitter) -> Unit {
  let plan = self.plan
  if async_method(plan.http_method) is None {
    self.reject(
      "unsupported-method",
      "moonbitlang/async does not send the method of this request",
      help="it sends GET, HEAD, POST, PUT, DELETE, OPTIONS, TRACE and PATCH, in upper case",
    )
  }
  if plan.url.host.has_prefix("[") {
    self.reject(
      "unsupported-host", "moonbitlang/async does not connect to an IPv6 address in a URL",
    )
  }
  if plan.omit_user_agent {
    self.reject(
      "unsupported-header",
      "moonbitlang/async always sends a User-Agent",
      help="set one with -A",
    )
  }
  if plan.follow_redirects && plan.cookie_engine {
    self.reject(
      "unsupported-redirects",
      "with -b and -L, curl sends back the cookies of redirects, which is not supported",
      help="use -H \"Cookie: ...\" instead of -b",
    )
  }
  if plan.url.query is Some(query) {
    for part in query.split("&") {
      let name = match part.find("=") {
        Some(at) => part[:at].to_owned().to_lower()
        None => ""
      }
      if secret_parameters.contains(name) {
        self.report.add(
          Warning,
          "secret-in-url",
          "the query parameter \{name} may be a secret, and the program holds the whole URL",
        )
      }
    }
  }
}

///|
/// What generated programs do to follow redirects, as curl does.
let redirect_code : String =
  #|///|
  #|/// The origin and path that `location` means in an answer to a request for
  #|/// `path` at `origin`. Fails for anything unusual.
  #|fn redirect_target(
  #|  origin : String,
  #|  path : String,
  #|  location : String,
  #|) -> (String, String) raise {
  #|  guard location
  #|    .iter()
  #|    .all(char => char > ' ' && char < '\u{7F}' && char != '\\') else {
  #|    fail("the redirect has a character that is not supported")
  #|  }
  #|  let location = match location.find("#") {
  #|    Some(at) => location[:at].to_owned()
  #|    None => location
  #|  }
  #|  let location = if location.has_prefix("//") {
  #|    origin[:origin.find("://").unwrap() + 1].to_owned() + location
  #|  } else {
  #|    location
  #|  }
  #|  let base = match path.find("?") {
  #|    Some(at) => path[:at].to_owned()
  #|    None => path
  #|  }
  #|  let (origin, target) = if location.has_prefix("http://") ||
  #|    location.has_prefix("https://") {
  #|    let start = location.find("://").unwrap() + 3
  #|    let rest = location[start:]
  #|    let end = rest.find_by(char => char is ('/' | '?')).unwrap_or(rest.length())
  #|    let host = rest[:end].to_owned()
  #|    guard host != "" &&
  #|      host
  #|      .iter()
  #|      .all(char => {
  #|        char is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '.' | '-' | '_' | ':')
  #|      }) else {
  #|      fail("the redirect has a host that is not supported")
  #|    }
  #|    let target = rest[end:].to_owned()
  #|    (
  #|      location[:start].to_owned() + host,
  #|      if target.has_prefix("/") {
  #|        target
  #|      } else {
  #|        "/" + target
  #|      },
  #|    )
  #|  } else if location
  #|    .split("/")
  #|    .head()
  #|    .unwrap_or("")
  #|    .split("?")
  #|    .head()
  #|    .unwrap_or("")
  #|    .contains(":") {
  #|    fail("the redirect leads to a protocol that is not supported")
  #|  } else if location.has_prefix("/") {
  #|    (origin, location)
  #|  } else if location == "" || location.has_prefix("?") {
  #|    (origin, base + location)
  #|  } else {
  #|    (origin, base[:base.rev_find("/").unwrap() + 1].to_owned() + location)
  #|  }
  #|  let (target, query) = match target.find("?") {
  #|    Some(at) if at + 1 < target.length() =>
  #|      (target[:at].to_owned(), target[at:].to_owned())
  #|    Some(at) => (target[:at].to_owned(), "")
  #|    None => (target, "")
  #|  }
  #|  let segments : Array[String] = []
  #|  let parts = target[1:].split("/").collect()
  #|  for i, part in parts {
  #|    match part.to_owned().to_lower().replace_all(old="%2e", new=".") {
  #|      "." => if i + 1 == parts.length() { segments.push("") }
  #|      ".." => {
  #|        ignore(segments.pop())
  #|        if i + 1 == parts.length() {
  #|          segments.push("")
  #|        }
  #|      }
  #|      _ => segments.push(part.to_owned())
  #|    }
  #|  }
  #|  (origin, "/" + segments.join("/") + query)
  #|}
  #|

///|
/// Adds lines that put `entries`, pairs of expressions, into a map.
fn push_map(
  out : Array[String],
  indent : String,
  open : String,
  entries : Array[(String, String)],
) -> Unit {
  out.push("\{indent}\{open}{")
  for entry in entries {
    out.push("\{indent}  \{entry.0}: \{entry.1},")
  }
}

///|
/// The statements that make the request and define `response` and `data`.
fn Emitter::request_statements(
  self : Emitter,
  headers : Array[(Header, String)],
  has_body : Bool,
) -> Array[String] {
  let plan = self.plan
  let out : Array[String] = []
  let verb = async_method(plan.http_method).unwrap_or("Get")
  let trust = if plan.insecure &&
    (plan.follow_redirects || plan.url.scheme == "https") {
    ", trust=NoVerification"
  } else {
    ""
  }
  let origin = "\{plan.url.scheme}://\{plan.url.authority()}"
  let quoted = text => "\"\{escape_text(text)}\""
  if !plan.follow_redirects {
    out.push("  let client = @http.Client(\{quoted(origin)}\{trust})")
    out.push("  defer client.close()")
    let entries = headers.map(entry => (quoted(entry.0.name), entry.1))
    if has_body {
      entries.push(("\"Content-Length\"", "body.length().to_string()"))
    }
    push_map(
      out,
      "  ",
      "client.request(\{verb}, \{quoted(plan.url.target())}, extra_headers=",
      entries,
    )
    out.push("  })")
    if has_body {
      out.push("  client.write(body)")
    }
    out.push("  let response = client.end_request()")
    out.push("  (response, client.read_all())")
    return out
  }
  // 301 to 303 make curl drop the body. The method becomes GET unless -X
  // sets it.
  out.push("  let first = \{quoted(origin)}")
  out.push("  let mut origin = first")
  out.push("  let mut path = \{quoted(plan.url.target())}")
  if has_body {
    out.push("  let mut with_body = true")
  }
  out.push("  for redirects = 0; ; redirects = redirects + 1 {")
  out.push("    let client = @http.Client(origin\{trust})")
  out.push("    defer client.close()")
  fn is_credential(header : Header) -> Bool {
    ["authorization", "cookie"].contains(header.name.to_lower())
  }

  // curl adds this one because of the body, so it goes with the body.
  fn goes_with_body(header : Header) -> Bool {
    has_body &&
    header.implied &&
    same_name(header.name, "Content-Type") &&
    (
      plan.body is Some(Multipart(_)) ||
      header.value.to_text() == Some("application/x-www-form-urlencoded")
    )
  }

  let always = headers.filter(entry => {
    !is_credential(entry.0) && !goes_with_body(entry.0)
  })
  push_map(
    out,
    "    ",
    "let headers : @http.Headers = ",
    always.map(entry => (quoted(entry.0.name), entry.1)),
  )
  out.push("    }")
  let credentials = headers.filter(entry => is_credential(entry.0))
  if !credentials.is_empty() {
    out.push("    // Credentials are for the first host only.")
    out.push("    if origin == first {")
    for entry in credentials {
      out.push("      headers[\{quoted(entry.0.name)}] = \{entry.1}")
    }
    out.push("    }")
  }
  if has_body {
    out.push("    if with_body {")
    for entry in headers {
      if goes_with_body(entry.0) {
        out.push("      headers[\{quoted(entry.0.name)}] = \{entry.1}")
      }
    }
    out.push("      headers[\"Content-Length\"] = body.length().to_string()")
    out.push("    }")
  }
  let changes = has_body && !plan.explicit_method && verb != "Get"
  let method_expression = if changes {
    "if with_body { \{verb} } else { Get }"
  } else {
    verb
  }
  if changes {
    out.push("    let meth : @http.RequestMethod = \{method_expression}")
    out.push("    client.request(meth, path, extra_headers=headers)")
  } else {
    out.push("    client.request(\{verb}, path, extra_headers=headers)")
  }
  if has_body {
    out.push("    if with_body {")
    out.push("      client.write(body)")
    out.push("    }")
  }
  out.push("    let response = client.end_request()")
  out.push("    let location = match response.headers.get(\"Location\") {")
  out.push("      Some(location) if response.code is (300..<400) =>")
  out.push("        location.trim().to_owned()")
  out.push("      _ => \"\"")
  out.push("    }")
  out.push("    if location == \"\" {")
  out.push("      return (response, client.read_all())")
  out.push("    }")
  out.push("    if redirects == \{plan.max_redirects} {")
  out.push("      fail(\"more than \{plan.max_redirects} redirects\")")
  out.push("    }")
  if has_body {
    out.push("    if response.code is (301 | 302 | 303) {")
    out.push("      with_body = false")
    out.push("    }")
  }
  out.push(
    "    let (next_origin, next_path) = redirect_target(origin, path, location)",
  )
  out.push("    origin = next_origin")
  out.push("    path = next_path")
  out.push("  }")
  out
}

///|
fn Emitter::emit(self : Emitter, secrets : Secrets) -> Emitted raise EmitError {
  let plan = self.plan
  self.check_plan()
  let mut headers = self.checked_headers()
  let mut auth = plan.auth
  if secrets is FromEnv {
    headers = headers.map(header => self.lift_header(header))
    auth = match auth {
      Some(Basic(value)) =>
        Some(
          Basic(
            self.lift(
              value, "BASIC_AUTH", "the user name and password, user:password,",
            ),
          ),
        )
      Some(Bearer(value)) =>
        Some(Bearer(self.lift(value, "BEARER_TOKEN", "the bearer token")))
      None => None
    }
  }
  if self.report.has_errors() {
    raise EmitError(self.report.sorted())
  }
  // Header values are text, which the plan makes sure of.
  let fields : Array[(Header, String)] = []
  match auth {
    Some(Bearer(value)) => {
      let value = Value::literal("Bearer ").append(value)
      let header = Header::{ name: "Authorization", value, implied: false, }
      fields.push((header, self.string_expression(value).unwrap_or("\"\"")))
    }
    Some(Basic(value)) => {
      self.import_package("moonbitlang/core/encoding/base64")
      let header = Header::{ name: "Authorization", value, implied: false, }
      let bytes = self.bytes_value(value)
      fields.push((header, "\"Basic \" + @base64.encode(\{bytes})"))
    }
    None => ()
  }
  for header in headers {
    fields.push(
      (header, self.string_expression(header.value).unwrap_or("\"\"")),
    )
  }
  let body_lines : Array[String] = []
  match plan.body {
    Some(Data(value)) => self.body_statements(value, body_lines)
    Some(Multipart(parts)) => {
      self.form_statements(parts, body_lines)
      let header = Header::{
        name: "Content-Type",
        value: Value::literal("multipart/form-data"),
        implied: true,
      }
      fields.push((header, "\"multipart/form-data; boundary=\\{boundary}\""))
    }
    None => ()
  }
  let request_lines = self.request_statements(fields, plan.body is Some(_))
  // Now all environment variables are known.
  let lines : Array[String] = []
  if !self.environment.is_empty() {
    self.import_package("moonbitlang/core/env")
    lines.append([
      "///|", "/// The value of the environment variable `name`.", "fn env(name : String) -> String raise {",
      "  match @env.get_env_var(name) {", "    Some(value) => value", "    None => fail(\"the environment variable \\{name} is not set\")",
      "  }", "}", "",
    ])
  }
  for entry in helper_code {
    if self.helpers.contains(entry.0) {
      lines.append(entry.1.split("\n").map(line => line.to_owned()).collect())
    }
  }
  if plan.follow_redirects {
    lines.append(
      redirect_code.split("\n").map(line => line.to_owned()).collect(),
    )
  }
  lines.append([
    "///|",
    "/// \{plan.http_method} \{plan.url.scheme}://\{plan.url.authority()}\{plan.url.path}",
    "async fn send_request() -> (@http.Response, &@io.Data) {",
  ])
  for name, variable in self.environment {
    lines.push("  let \{variable} = env(\"\{name}\")")
  }
  lines.append(body_lines)
  lines.append(request_lines)
  lines.append(["}", "", "///|", "async fn main {"])
  match plan.max_time_ms {
    Some(ms) => {
      self.import_package("moonbitlang/async")
      lines.push(
        "  let (response, body) = @async.with_timeout(\{ms}, send_request)",
      )
    }
    None => lines.push("  let (response, body) = send_request()")
  }
  if plan.fail_on_error {
    lines.append([
      "  if response.code >= 400 {", "    fail(\"HTTP status \\{response.code}\")",
      "  }",
    ])
  } else {
    lines.push("  ignore(response)")
  }
  lines.push("  @stdio.stdout.write(body)")
  lines.push("}")
  for
    name in [
      "moonbitlang/async/http", "moonbitlang/async/io", "moonbitlang/async/stdio",
    ] {
    self.import_package(name)
  }
  let imports = self.imports.keys().collect()
  imports.sort()
  {
    code: lines.join("\n") + "\n",
    imports,
    environment: self.environment.keys().collect(),
    diagnostics: self.report.sorted(),
  }
}

///|
/// A MoonBit program that makes the request and writes the body of the
/// response to the standard output, as curl does.
pub fn RequestPlan::emit(
  self : RequestPlan,
  target~ : Target = Async,
  secrets~ : Secrets = FromEnv,
) -> Emitted raise EmitError {
  let emitter = Emitter::{
    plan: self,
    report: Report::{ found: [], },
    environment: Map([]),
    imports: Map([]),
    helpers: Map([]),
  }
  match target {
    Async => emitter.emit(secrets)
  }
}

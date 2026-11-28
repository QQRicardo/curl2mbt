///|
/// A header field of a request.
#derive(Eq, Debug)
pub struct Header {
  /// As written; the case has no meaning.
  name : String
  value : Value
  /// Whether curl adds the field on its own, rather than because of an
  /// option that sets it.
  implied : Bool
}

///|
/// How the request says who sends it.
#derive(Eq, Debug)
pub enum Auth {
  /// `user:password`, sent as `Authorization: Basic ...`.
  Basic(Value)
  /// A token, sent as `Authorization: Bearer ...`.
  Bearer(Value)
}

///|
/// The body of a request.
#derive(Eq, Debug)
pub enum Body {
  /// These bytes.
  Data(Value)
  /// A form, sent as multipart/form-data with any boundary that fits. The
  /// Content-Type is not in the headers of the plan.
  Multipart(Array[Part])
  /// What the file of this name holds when the request is made, from `-T`.
  /// Unlike other bodies it stays when a 301 or 302 redirects.
  Upload(String)
}

///|
/// What a curl command asks for. Only `parse`, `parse_argv` and `from_json`
/// make plans, so the parts always fit together.
#derive(Eq, Debug)
pub struct RequestPlan {
  http_method : String
  /// Whether `-X` sets the method. curl then keeps it across redirects.
  explicit_method : Bool
  url : Url
  /// In the order curl sends them, without those any HTTP client adds (Host
  /// and Content-Length), and without `auth`. The User-Agent is only here if
  /// the command sets it.
  headers : Array[Header]
  /// Whether the command removes the User-Agent.
  omit_user_agent : Bool
  auth : Auth?
  /// `None` is a request without a body. `Data` of an empty value is a
  /// request with a body of length 0.
  body : Body?
  /// `--compressed`: offer compressed responses and decompress them.
  compressed : Bool
  /// `-L`.
  follow_redirects : Bool
  /// `--location-trusted`: send credentials to every host that a redirect
  /// leads to, not only to the first one.
  location_trusted : Bool
  /// `--post301`, `--post302` and `--post303`: the codes of redirects
  /// after which a POST stays a POST, with its body, in ascending order.
  keep_post : Array[Int32]
  /// How many redirects to follow at most.
  max_redirects : Int32
  /// Whether `-b` makes curl send back the cookies it receives on redirects.
  cookie_engine : Bool
  /// `-k`: do not verify the certificate of the server.
  insecure : Bool
  /// `-f`: treat a status of 400 or more as a failure.
  fail_on_error : Bool
  /// `--fail-with-body`: like `fail_on_error`, after the body is written.
  fail_with_body : Bool
  /// `-o`, `-O` and `--output-dir`: the file that gets the body of the
  /// response. `None` is the standard output.
  output_file : String?
  /// `--create-dirs`: create the directories of `output_file` and
  /// `etag_save`.
  create_dirs : Bool
  /// `--no-clobber`: if `output_file` exists, write to the first of
  /// `output_file.1` to `output_file.100` that does not.
  no_clobber : Bool
  /// `--remove-on-error`: remove the file that was written when the program
  /// fails afterwards, which `fail_with_body` makes it do.
  remove_on_error : Bool
  /// `--max-filesize`: fail, without writing the body, if the response is
  /// larger, by its Content-Length or by what arrives.
  max_filesize : Int64?
  /// `-w`: what to write after the body, in the syntax of curl, with only
  /// the variables that programs write.
  write_out : String?
  /// `-m`: the time each attempt may take.
  max_time_ms : Int32?
  /// `--connect-timeout`: the time that making each connection may take,
  /// with the `CONNECT` of a proxy and the TLS handshake.
  connect_timeout_ms : Int32?
  /// `--request-target`: what the request line has instead of the path and
  /// query of `url`, also after redirects. Visible ASCII characters.
  request_target : String?
  /// `--etag-compare`: the file whose text, without line breaks, goes into
  /// If-None-Match when the request is made, after the other fields; `""`
  /// if there is no such file or it is empty.
  etag_compare : String?
  /// `--etag-save`: the file that is made before the request and gets the
  /// ETag of each response with a status from 200 to 399.
  etag_save : String?
  /// `--retry` and the options that go with it.
  retry : Retry?
  /// `-x`: the proxy that the request goes through, in a tunnel that
  /// `CONNECT` makes, as with `-p`.
  proxy : Proxy?
}

///|
/// An HTTP proxy.
#derive(Eq, Debug)
pub struct Proxy {
  /// `http` or `https`: how the program talks to the proxy.
  scheme : String
  /// A name or an IPv4 address.
  host : String
  port : Int32
  /// `user:password`, sent to the proxy as `Proxy-Authorization: Basic ...`.
  user : Value?
}

///|
/// The proxy as a URL, as `-x` takes it.
pub fn Proxy::to_string(self : Proxy) -> String {
  "\{self.scheme}://\{self.host}:\{self.port}"
}

///|
/// When a request is sent again, as `--retry` asks: after a timeout, or a
/// status of 408, 429, 500, 502, 503, 504, 522 or 524.
#derive(Eq, Debug)
pub struct Retry {
  /// How many times the request may be sent again; at least 1.
  count : Int32
  /// `--retry-delay`: the pause before each retry. `None` is the pause of
  /// curl: one second, twice as long each time, up to ten minutes. A longer
  /// pause that `Retry-After` asks for wins.
  delay_ms : Int32?
  /// `--retry-max-time`: no retry after this much time from the start.
  max_time_ms : Int32?
  /// `--retry-all-errors`: every error is retried, and with `-f` every
  /// status of 400 or more.
  all_errors : Bool
}

///|
/// The outcome of reading a command.
pub struct Parsed {
  plan : RequestPlan
  /// Warnings and notes, in the order of the input.
  diagnostics : Array[Diagnostic]
}

///|
fn is_token_char(char : Char) -> Bool {
  is_alpha(char) ||
  is_digit(char) ||
  char
  is ('!'
  | '#'
  | '$'
  | '%'
  | '&'
  | '\''
  | '*'
  | '+'
  | '-'
  | '.'
  | '^'
  | '_'
  | '`'
  | '|'
  | '~')
}

///|
/// Whether `text` is a token of HTTP, such as a method or a field name.
fn is_token(text : StringView) -> Bool {
  !text.is_empty() && text.iter().all(is_token_char)
}

///|
fn same_name(a : String, b : String) -> Bool {
  a.to_lower() == b.to_lower()
}

///|
let default_max_redirects : Int32 = 50

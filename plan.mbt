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
  /// `--create-dirs`: create the directories of `output_file`.
  create_dirs : Bool
  /// `-m`: the time the whole request may take.
  max_time_ms : Int32?
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

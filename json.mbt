///|
/// The JSON is not a plan that this version writes.
#derive(Debug)
pub suberror PlanError {
  /// Where in the JSON the problem is, such as `headers[0].name`, and what
  /// it is.
  PlanError(path~ : String, message~ : String)
}

///|
let plan_version : Int32 = 1

///|
/// A value is a string, or an array of `{"text": ...}`, `{"base64": ...}`,
/// `{"env": ...}` and `{"file": ...}`.
fn Value::to_json_value(self : Value) -> Json {
  if self.to_text() is Some(text) {
    return Json::string(text)
  }
  Json::array(
    self.pieces.map(piece => {
      match piece {
        Env(name) => Json::object({ "env": Json::string(name) })
        File(path~, read~) => {
          let out : Map[String, Json] = { "file": Json::string(path) }
          match read {
            Whole => ()
            WithoutLineBreaks =>
              out["without_line_breaks"] = Json::boolean(true)
            FormEncoded(name) => out["form_encoded"] = Json::string(name)
          }
          Json::object(out)
        }
        Literal(bytes) =>
          match Value::from_pieces([piece]).to_text() {
            Some(text) => Json::object({ "text": Json::string(text) })
            None =>
              Json::object({ "base64": Json::string(@base64.encode(bytes)) })
          }
      }
    }),
  )
}

///|
/// The plan as JSON that `RequestPlan::from_json` reads back. What has its
/// default value is left out.
pub fn RequestPlan::to_json(self : RequestPlan) -> Json {
  let out : Map[String, Json] = Map([])
  let flag = (name, on) => if on { out[name] = Json::boolean(true) }
  out["version"] = Json::number(plan_version.to_double())
  out["method"] = Json::string(self.http_method)
  flag("explicit_method", self.explicit_method)
  out["url"] = Json::string(self.url.to_string())
  out["headers"] = Json::array(
    self.headers.map(header => {
      let field : Map[String, Json] = {
        "name": Json::string(header.name),
        "value": header.value.to_json_value(),
      }
      if header.implied {
        field["implied"] = Json::boolean(true)
      }
      Json::object(field)
    }),
  )
  flag("omit_user_agent", self.omit_user_agent)
  match self.auth {
    Some(Basic(value)) =>
      out["auth"] = Json::object({ "basic": value.to_json_value() })
    Some(Bearer(value)) =>
      out["auth"] = Json::object({ "bearer": value.to_json_value() })
    None => ()
  }
  match self.body {
    Some(Data(value)) =>
      out["body"] = Json::object({ "data": value.to_json_value() })
    Some(Upload(path)) =>
      out["body"] = Json::object({ "upload": Json::string(path) })
    Some(Multipart(parts)) =>
      out["body"] = Json::object({
        "multipart": Json::array(
          parts.map(part => {
            let field : Map[String, Json] = {
              "name": Json::string(part.name),
              "content": part.content.to_json_value(),
            }
            if part.filename is Some(filename) {
              field["filename"] = Json::string(filename)
            }
            if part.content_type is Some(content_type) {
              field["type"] = Json::string(content_type)
            }
            Json::object(field)
          }),
        ),
      })
    None => ()
  }
  flag("compressed", self.compressed)
  flag("follow_redirects", self.follow_redirects)
  if self.max_redirects != default_max_redirects {
    out["max_redirects"] = Json::number(self.max_redirects.to_double())
  }
  flag("cookie_engine", self.cookie_engine)
  flag("insecure", self.insecure)
  flag("fail_on_error", self.fail_on_error)
  flag("fail_with_body", self.fail_with_body)
  if self.output_file is Some(path) {
    out["output_file"] = Json::string(path)
  }
  flag("create_dirs", self.create_dirs)
  if self.write_out is Some(text) {
    out["write_out"] = Json::string(text)
  }
  if self.retry is Some(retry) {
    let fields : Map[String, Json] = {
      "count": Json::number(retry.count.to_double()),
    }
    if retry.delay_ms is Some(ms) {
      fields["delay_ms"] = Json::number(ms.to_double())
    }
    if retry.max_time_ms is Some(ms) {
      fields["max_time_ms"] = Json::number(ms.to_double())
    }
    if retry.all_errors {
      fields["all_errors"] = Json::boolean(true)
    }
    out["retry"] = Json::object(fields)
  }
  if self.max_time_ms is Some(ms) {
    out["max_time_ms"] = Json::number(ms.to_double())
  }
  Json::object(out)
}

///|
fn[T] bad_plan(path : String, message : String) -> T raise PlanError {
  raise PlanError(path~, message~)
}

///|
/// A JSON object of a plan, at `path`.
priv struct Fields {
  path : String
  fields : Map[String, Json]
}

///|
/// The object `json`, which may only have the fields `known`.
fn Fields::new(
  path : String,
  json : Json,
  known : ArrayView[String],
) -> Fields raise PlanError {
  guard json is Object(fields) else { bad_plan(path, "must be an object") }
  for name in fields.keys() {
    if !known.contains(name) {
      bad_plan(path, "has a field this version does not know")
    }
  }
  { path, fields, }
}

///|
fn Fields::at(self : Fields, name : String) -> String {
  if self.path == "" {
    name
  } else {
    "\{self.path}.\{name}"
  }
}

///|
fn Fields::string(self : Fields, name : String) -> String raise PlanError {
  match self.fields.get(name) {
    Some(String(text)) => text
    _ => bad_plan(self.at(name), "must be a string")
  }
}

///|
fn Fields::flag(self : Fields, name : String) -> Bool raise PlanError {
  match self.fields.get(name) {
    None | Some(False) => false
    Some(True) => true
    _ => bad_plan(self.at(name), "must be true or false")
  }
}

///|
/// A whole number from `min` to 999999999.
fn Fields::integer(
  self : Fields,
  name : String,
  min~ : Int32,
) -> Int32? raise PlanError {
  match self.fields.get(name) {
    None => None
    Some(Number(number, ..)) if number >= min.to_double() &&
      number <= 999999999.0 &&
      number.to_int().to_double() == number => Some(number.to_int())
    _ => bad_plan(self.at(name), "must be a whole number from \{min} on")
  }
}

///|
fn Fields::value(self : Fields, name : String) -> Value raise PlanError {
  let path = self.at(name)
  match self.fields.get(name) {
    Some(String(text)) => Value::literal(well_formed(path, text))
    Some(Array(items)) => {
      let pieces : Array[Piece] = []
      for i, item in items {
        pieces.push(piece_from_json("\{path}[\{i}]", item))
      }
      Value::from_pieces(pieces)
    }
    _ => bad_plan(path, "must be a string or an array")
  }
}

///|
/// `text`, unless it has half of a surrogate pair, which has no bytes.
fn well_formed(path : String, text : String) -> String raise PlanError {
  for i = 0; i < text.length(); {
    match text.get_char(i) {
      Some(char) => continue i + char.utf16_len()
      None => bad_plan(path, "has half of a surrogate pair")
    }
  }
  text
}

///|
fn piece_from_json(path : String, json : Json) -> Piece raise PlanError {
  let item = Fields::new(path, json, [
    "text", "base64", "env", "file", "without_line_breaks", "form_encoded",
  ])
  if item.fields.contains("file") &&
    !["text", "base64", "env"].iter().any(name => item.fields.contains(name)) {
    return file_from_json(item)
  }
  guard item.fields.length() == 1 else {
    bad_plan(path, "must have exactly one of text, base64, env and file")
  }
  if item.fields.contains("text") {
    let text = item.string("text")
    return Literal(@utf8.encode(well_formed(item.at("text"), text)))
  }
  if item.fields.contains("base64") {
    let text = item.string("base64")
    return Literal(@base64.decode(text)) catch {
      _ => bad_plan(item.at("base64"), "is not valid base64")
    }
  }
  let name = item.string("env")
  let units = name.code_units()
  if units.is_empty() ||
    !is_name_start(units[0]) ||
    !units.iter().all(is_name_part) {
    bad_plan(item.at("env"), "is not the name of a variable")
  }
  Env(name)
}

///|
fn file_from_json(item : Fields) -> Piece raise PlanError {
  let path = well_formed(item.at("file"), item.string("file"))
  if path is ("" | "-") || path.contains("\u0000") {
    bad_plan(item.at("file"), "is not the name of a file")
  }
  let lines = item.flag("without_line_breaks")
  let encoded = item.fields.contains("form_encoded")
  if item.fields.length() > 2 || (lines && encoded) {
    bad_plan(item.path, "reads a file in more than one way")
  }
  let read = if lines {
    WithoutLineBreaks
  } else if encoded {
    let name = well_formed(item.at("form_encoded"), item.string("form_encoded"))
    if name.contains("=") || name.contains("@") || name.contains("\u0000") {
      bad_plan(item.at("form_encoded"), "is not the name of a field")
    }
    FormEncoded(name)
  } else {
    Whole
  }
  File(path~, read~)
}

///|
fn part_from_json(path : String, json : Json) -> Part raise PlanError {
  let item = Fields::new(path, json, ["name", "content", "filename", "type"])
  let text = field => {
    if item.fields.contains(field) {
      Some(well_formed(item.at(field), item.string(field)))
    } else {
      None
    }
  }
  let name = item.string("name")
  if name == "" || well_formed(item.at("name"), name).contains("\u0000") {
    bad_plan(item.at("name"), "is not the name of a part")
  }
  let content_type = text("type")
  if content_type is Some(found) && !is_media_type(found) {
    bad_plan(item.at("type"), "is not a type such as text/plain")
  }
  let filename = text("filename")
  if filename is Some(found) && (found == "" || found.contains("\u0000")) {
    bad_plan(item.at("filename"), "is not the name of a file")
  }
  { name, content: item.value("content"), filename, content_type, }
}

///|
fn header_from_json(path : String, json : Json) -> Header raise PlanError {
  let item = Fields::new(path, json, ["name", "value", "implied"])
  let name = item.string("name")
  if !is_token(name) {
    bad_plan(item.at("name"), "is not the name of a header field")
  }
  if ["content-length", "transfer-encoding"].contains(name.to_lower()) {
    bad_plan(item.at("name"), "is a field that plans do not hold")
  }
  let value = item.value("value")
  if !value.is_field_value() || value.trim() != value {
    bad_plan(item.at("value"), "is not the value of a header field")
  }
  { name, value, implied: item.flag("implied"), }
}

///|
/// Reads what `RequestPlan::to_json` writes.
pub fn RequestPlan::from_json(json : Json) -> RequestPlan raise PlanError {
  let plan = Fields::new("", json, [
    "version", "method", "explicit_method", "url", "headers", "omit_user_agent",
    "auth", "body", "compressed", "follow_redirects", "max_redirects", "cookie_engine",
    "insecure", "fail_on_error", "fail_with_body", "output_file", "create_dirs",
    "max_time_ms", "retry", "write_out",
  ])
  if plan.integer("version", min=1) != Some(plan_version) {
    bad_plan("version", "must be \{plan_version}")
  }
  let http_method = plan.string("method")
  if !is_token(http_method) {
    bad_plan("method", "is not an HTTP token")
  }
  let text = plan.string("url")
  let parsed = parse_url(text, globbing=false, path_as_is=true) catch {
    UrlError({ message, .. }) => bad_plan("url", message)
  }
  if parsed.url.to_string() != text {
    bad_plan("url", "is not written the way plans write URLs")
  }
  let headers : Array[Header] = []
  match plan.fields.get("headers") {
    Some(Array(items)) =>
      for i, item in items {
        headers.push(header_from_json("headers[\{i}]", item))
      }
    _ => bad_plan("headers", "must be an array")
  }
  let hosts = headers.filter(header => same_name(header.name, "Host"))
  if hosts.length() > 1 || hosts.iter().any(header => header.value.is_empty()) {
    bad_plan("headers", "have an empty or second Host")
  }
  let omit_user_agent = plan.flag("omit_user_agent")
  if omit_user_agent &&
    headers.iter().any(header => same_name(header.name, "User-Agent")) {
    bad_plan("omit_user_agent", "contradicts the headers")
  }
  let auth = match plan.fields.get("auth") {
    None => None
    Some(json) => {
      let auth = Fields::new("auth", json, ["basic", "bearer"])
      if auth.fields.length() != 1 {
        bad_plan("auth", "must have exactly one of basic and bearer")
      }
      if headers.iter().any(header => same_name(header.name, "Authorization")) {
        bad_plan("auth", "contradicts the headers")
      }
      if auth.fields.contains("basic") {
        let value = auth.value("basic")
        if value.split_once(b':') is None {
          bad_plan("auth.basic", "must have a colon")
        }
        if value.has_file() {
          bad_plan("auth.basic", "must not refer to a file")
        }
        Some(Basic(value))
      } else {
        let value = auth.value("bearer")
        if value.is_empty() || !value.is_field_value() {
          bad_plan("auth.bearer", "is not a token")
        }
        Some(Bearer(value))
      }
    }
  }
  let fail_with_body = plan.flag("fail_with_body")
  if fail_with_body && !plan.flag("fail_on_error") {
    bad_plan("fail_with_body", "needs fail_on_error")
  }
  let output_file = if plan.fields.contains("output_file") {
    let path = well_formed("output_file", plan.string("output_file"))
    if path is ("" | "-") || path.contains("\u0000") {
      bad_plan("output_file", "is not the name of a file")
    }
    Some(path)
  } else {
    None
  }
  let create_dirs = plan.flag("create_dirs")
  if create_dirs && output_file is None {
    bad_plan("create_dirs", "needs output_file")
  }
  let write_out = match plan.fields.get("write_out") {
    None => None
    Some(_) => {
      let text = well_formed(plan.at("write_out"), plan.string("write_out"))
      if text == "" || text.has_prefix("@") {
        bad_plan("write_out", "must not be empty or start with @")
      }
      if parse_write_out(text) is Err(message) {
        bad_plan("write_out", message)
      }
      Some(text)
    }
  }
  let retry = match plan.fields.get("retry") {
    None => None
    Some(json) => {
      let retry = Fields::new("retry", json, [
        "count", "delay_ms", "max_time_ms", "all_errors",
      ])
      guard retry.integer("count", min=1) is Some(count) else {
        bad_plan("retry.count", "must be a whole number from 1 on")
      }
      Some(Retry::{
        count,
        delay_ms: retry.integer("delay_ms", min=1),
        max_time_ms: retry.integer("max_time_ms", min=1),
        all_errors: retry.flag("all_errors"),
      })
    }
  }
  let body = match plan.fields.get("body") {
    None => None
    Some(json) => {
      let body = Fields::new("body", json, ["data", "multipart", "upload"])
      if body.fields.length() != 1 {
        bad_plan("body", "must have exactly one of data, multipart and upload")
      }
      match body.fields.get("multipart") {
        None if body.fields.contains("upload") => {
          let path = well_formed(body.at("upload"), body.string("upload"))
          if path is ("" | "-") || path.contains("\u0000") {
            bad_plan(body.at("upload"), "is not the name of a file")
          }
          Some(Upload(path))
        }
        None => Some(Data(body.value("data")))
        Some(Array([_, ..] as items)) => {
          if headers
            .iter()
            .any(header => same_name(header.name, "Content-Type")) {
            bad_plan("headers", "have a Content-Type beside that of the form")
          }
          let parts : Array[Part] = []
          for i, item in items {
            parts.push(part_from_json("body.multipart[\{i}]", item))
          }
          Some(Multipart(parts))
        }
        Some(_) => bad_plan("body.multipart", "must be an array with a part")
      }
    }
  }
  {
    http_method,
    explicit_method: plan.flag("explicit_method"),
    url: parsed.url,
    headers,
    omit_user_agent,
    auth,
    body,
    compressed: plan.flag("compressed"),
    follow_redirects: plan.flag("follow_redirects"),
    max_redirects: plan
    .integer("max_redirects", min=0)
    .unwrap_or(default_max_redirects),
    cookie_engine: plan.flag("cookie_engine"),
    insecure: plan.flag("insecure"),
    fail_on_error: plan.flag("fail_on_error"),
    fail_with_body,
    output_file,
    create_dirs,
    max_time_ms: plan.integer("max_time_ms", min=1),
    retry,
    write_out,
  }
}

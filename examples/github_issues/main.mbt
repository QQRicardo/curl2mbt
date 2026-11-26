// Needs moonbitlang/async 0.22: moon add moonbitlang/async
// Imports for moon.pkg, with pkgtype(kind: "executable"):
//   import {
//     "moonbitlang/async/io",
//     "moonbitlang/core/env",
//     "moonbitlang/async/http",
//     "moonbitlang/async/stdio",
//   }
// Environment variables: GITHUB_TOKEN

///|
/// The value of the environment variable `name`.
fn env(name : String) -> String raise {
  match @env.get_env_var(name) {
    Some(value) => value
    None => fail("the environment variable \{name} is not set")
  }
}

///|
/// The origin and path that `location` means in an answer to a request for
/// `path` at `origin`. Fails for anything unusual.
fn redirect_target(
  origin : String,
  path : String,
  location : String,
) -> (String, String) raise {
  guard location
    .iter()
    .all(char => char > ' ' && char < '\u{7F}' && char != '\\') else {
    fail("the redirect has a character that is not supported")
  }
  let location = match location.find("#") {
    Some(at) => location[:at].to_owned()
    None => location
  }
  let location = if location.has_prefix("//") {
    origin[:origin.find("://").unwrap() + 1].to_owned() + location
  } else {
    location
  }
  let base = match path.find("?") {
    Some(at) => path[:at].to_owned()
    None => path
  }
  let (origin, target) = if location.has_prefix("http://") ||
    location.has_prefix("https://") {
    let start = location.find("://").unwrap() + 3
    let rest = location[start:]
    let end = rest.find_by(char => char is ('/' | '?')).unwrap_or(rest.length())
    let host = rest[:end].to_owned()
    guard host != "" &&
      host
      .iter()
      .all(char => {
        char is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '.' | '-' | '_' | ':')
      }) else {
      fail("the redirect has a host that is not supported")
    }
    let target = rest[end:].to_owned()
    (
      location[:start].to_owned() + host,
      if target.has_prefix("/") {
        target
      } else {
        "/" + target
      },
    )
  } else if location
    .split("/")
    .head()
    .unwrap_or("")
    .split("?")
    .head()
    .unwrap_or("")
    .contains(":") {
    fail("the redirect leads to a protocol that is not supported")
  } else if location.has_prefix("/") {
    (origin, location)
  } else if location == "" || location.has_prefix("?") {
    (origin, base + location)
  } else {
    (origin, base[:base.rev_find("/").unwrap() + 1].to_owned() + location)
  }
  let (target, query) = match target.find("?") {
    Some(at) if at + 1 < target.length() =>
      (target[:at].to_owned(), target[at:].to_owned())
    Some(at) => (target[:at].to_owned(), "")
    None => (target, "")
  }
  let segments : Array[String] = []
  let parts = target[1:].split("/").collect()
  for i, part in parts {
    match part.to_owned().to_lower().replace_all(old="%2e", new=".") {
      "." => if i + 1 == parts.length() { segments.push("") }
      ".." => {
        ignore(segments.pop())
        if i + 1 == parts.length() {
          segments.push("")
        }
      }
      _ => segments.push(part.to_owned())
    }
  }
  (origin, "/" + segments.join("/") + query)
}

///|
/// GET https://api.github.com/repos/moonbitlang/core/issues
async fn send_request() -> (@http.Response, &@io.Data) {
  let env_github_token = env("GITHUB_TOKEN")
  let first = "https://api.github.com"
  let mut origin = first
  let mut path = "/repos/moonbitlang/core/issues"
  for redirects = 0; ; redirects = redirects + 1 {
    let client = @http.Client(origin)
    defer client.close()
    let headers : @http.Headers = {
      "Accept": "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    }
    // Credentials are for the first host only.
    if origin == first {
      headers["Authorization"] = "Bearer \{env_github_token}"
    }
    client.request(Get, path, extra_headers=headers)
    let response = client.end_request()
    let location = match response.headers.get("Location") {
      Some(location) if response.code is (300..<400) =>
        location.trim().to_owned()
      _ => ""
    }
    if location == "" {
      return (response, client.read_all())
    }
    if redirects == 50 {
      fail("more than 50 redirects")
    }
    let (next_origin, next_path) = redirect_target(origin, path, location)
    origin = next_origin
    path = next_path
  }
}

///|
async fn main {
  let (response, body) = send_request()
  ignore(response)
  @stdio.stdout.write(body)
}

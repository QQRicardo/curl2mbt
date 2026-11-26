// Needs moonbitlang/async 0.22: moon add moonbitlang/async
// Imports for moon.pkg, with pkgtype(kind: "executable"):
//   import {
//     "moonbitlang/async/io",
//     "moonbitlang/core/env",
//     "moonbitlang/async/http",
//     "moonbitlang/async/stdio",
//   }
// Environment variables: SESSION
//
// warning[cmd-variable] at 3:23: the value of a variable is used as it is, while cmd would give a meaning to quotes, & and other characters in it
// note[compressed]: the program offers gzip only, and decompresses it

///|
/// The value of the environment variable `name`.
fn env(name : String) -> String raise {
  match @env.get_env_var(name) {
    Some(value) => value
    None => fail("the environment variable \{name} is not set")
  }
}

///|
/// GET https://example.com/api/items
async fn send_request() -> (@http.Response, &@io.Data) {
  let env_session = env("SESSION")
  let client = @http.Client("https://example.com")
  defer client.close()
  client.request(Get, "/api/items?page=2", extra_headers={
    "accept": "application/json",
    "cookie": "session=\{env_session}",
  })
  let response = client.end_request()
  (response, client.read_all())
}

///|
async fn main {
  let (response, body) = send_request()
  ignore(response)
  @stdio.stdout.write(body)
}

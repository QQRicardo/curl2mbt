// Needs moonbitlang/async 0.22: moon add moonbitlang/async
// Imports for moon.pkg, with pkgtype(kind: "executable"):
//   import {
//     "moonbitlang/async",
//     "moonbitlang/async/io",
//     "moonbitlang/async/http",
//     "moonbitlang/async/stdio",
//     "moonbitlang/core/encoding/utf8",
//   }

///|
/// POST https://httpbin.org/post
async fn send_request() -> (@http.Response, &@io.Data) {
  let text =
    #|{"name": "apple", "count": 3}
  let body = @utf8.encode(text)
  let client = @http.Client("https://httpbin.org")
  defer client.close()
  client.request(Post, "/post", extra_headers={
    "Content-Type": "application/json",
    "Accept": "application/json",
    "Content-Length": body.length().to_string(),
  })
  client.write(body)
  let response = client.end_request()
  (response, client.read_all())
}

///|
/// The retries that are left, and the pause before the next one.
struct Retries {
  mut left : Int32
  mut pause : Int32
}

///|
/// The pause before the next retry, or `None` if there is none.
/// `retry_after` is the pause that the server asks for.
fn Retries::next(self : Retries, retry_after : Int32?) -> Int32? {
  if self.left == 0 {
    return None
  }
  let mut pause = self.pause
  if retry_after is Some(ms) && ms > pause {
    pause = ms
  }
  self.left -= 1
  self.pause = if self.pause >= 300000 { 600000 } else { self.pause * 2 }
  Some(pause)
}

///|
/// The pause that `Retry-After` asks for, if it is a number of seconds.
fn retry_after(response : @http.Response) -> Int32? raise {
  guard response.headers.get("Retry-After") is Some(text) else {
    return None
  }
  let mut seconds = 0
  for char in text {
    guard char is ('0'..<='9') else {
      fail("a Retry-After that is not a number of seconds is not supported: \{text}")
    }
    seconds = seconds * 10 + (char.to_int() - '0'.to_int())
    if seconds > 999999 {
      seconds = 999999
    }
  }
  if text == "" {
    None
  } else {
    Some(seconds * 1000)
  }
}

///|
/// Sends the request, and again as `--retry` asks.
async fn send_with_retries(retries : Retries) -> (@http.Response, &@io.Data) {
  let (response, body) = send_request()
  if response.code is (408 | 429 | 500 | 502 | 503 | 504 | 522 | 524) &&
    retries.next(retry_after(response)) is Some(pause) {
    @async.sleep(pause)
    return send_with_retries(retries)
  }
  (response, body)
}

///|
async fn main {
  let (response, body) = send_with_retries(Retries::{ left: 3, pause: 1000 })
  if response.code >= 400 {
    fail("HTTP status \{response.code}")
  }
  @stdio.stdout.write(body)
}

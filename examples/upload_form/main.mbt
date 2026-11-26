// Needs moonbitlang/async 0.22: moon add moonbitlang/async
// Imports for moon.pkg, with pkgtype(kind: "executable"):
//   import {
//     "moonbitlang/async/fs",
//     "moonbitlang/async/io",
//     "moonbitlang/async/http",
//     "moonbitlang/async/stdio",
//     "moonbitlang/core/encoding/utf8",
//   }

///|
/// A multipart form of header fields and contents, and the boundary, which
/// does not occur in any of them.
fn form_data(parts : Array[(String, Bytes)]) -> (String, Bytes) {
  let mut boundary = "------------------------form"
  while parts
        .iter()
        .any(part => {
          part.0.contains(boundary) ||
          part.1.find(@utf8.encode(boundary)) is Some(_)
        }) {
    boundary = boundary + "0"
  }
  let mut body = b""
  for part in parts {
    body = body +
      @utf8.encode("--\{boundary}\r\n\{part.0}\r\n\r\n") +
      part.1 +
      b"\r\n"
  }
  (boundary, body + @utf8.encode("--\{boundary}--\r\n"))
}

///|
/// POST https://example.com/upload
async fn send_request() -> (@http.Response, &@io.Data) {
  let (boundary, body) = form_data([
    (
      "Content-Disposition: form-data; name=\"description\"",
      b"a photo of the office",
    ),
    (
      "Content-Disposition: form-data; name=\"file\"; filename=\"photo.png\"\r\nContent-Type: image/png",
      @fs.read_file("photo.png").binary(),
    ),
  ])
  let client = @http.Client("https://example.com")
  defer client.close()
  client.request(Post, "/upload", extra_headers={
    "Accept": "*/*",
    "Content-Type": "multipart/form-data; boundary=\{boundary}",
    "Content-Length": body.length().to_string(),
  })
  client.write(body)
  let response = client.end_request()
  (response, client.read_all())
}

///|
async fn main {
  let (response, body) = send_request()
  ignore(response)
  @stdio.stdout.write(body)
}

// Needs moonbitlang/async 0.22: moon add moonbitlang/async
// Imports for moon.pkg, with pkgtype(kind: "executable"):
//   import {
//     "moonbitlang/async/fs",
//     "moonbitlang/async/io",
//     "moonbitlang/async/http",
//     "moonbitlang/async/stdio",
//   }

///|
/// PUT https://example.com/files/report.csv
async fn send_request() -> (@http.Response, &@io.Data) {
  let body = @fs.read_file("report.csv").binary()
  let client = @http.Client("https://example.com")
  defer client.close()
  client.request(Put, "/files/report.csv?version=2", extra_headers={
    "Accept": "*/*",
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

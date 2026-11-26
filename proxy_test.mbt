///|
/// The proxy of the plan of a command line, as `-x` and `-U` write it.
fn proxy_plan(arguments : Array[String]) -> String raise {
  let words = ["curl"]
  words.append(arguments)
  match @curl2mbt.parse_argv(words).plan.proxy {
    None => "none"
    Some(proxy) =>
      match proxy.user {
        Some(user) => "\{proxy.to_string()} \{user.to_text().unwrap_or("?")}"
        None => proxy.to_string()
      }
  }
}

///|
/// The codes of what is reported about a command line.
fn proxy_codes(arguments : Array[String]) -> Array[String] {
  let words = ["curl"]
  words.append(arguments)
  let found = @curl2mbt.parse_argv(words).diagnostics catch {
      CurlError(found) => found
    }
  found.map(item => item.code)
}

///|
test "proxies" {
  assert_eq(proxy_plan(["https://h/"]), "none")
  // 1080 is the port of curl for an http proxy, and 443 for https.
  assert_eq(proxy_plan(["-x", "p", "https://h/"]), "http://p:1080")
  assert_eq(proxy_plan(["-x", "HTTP://p:80", "https://h/"]), "http://p:80")
  assert_eq(proxy_plan(["-x", "https://p", "https://h/"]), "https://p:443")
  assert_eq(
    proxy_plan(["--proxy", "p:3128", "-p", "http://h/"]),
    "http://p:3128",
  )
  // The last one counts, and an empty one is no proxy.
  assert_eq(proxy_plan(["-x", "p", "-x", "", "http://h/"]), "none")
  assert_eq(proxy_plan(["-x", "a", "-x", "b:1", "https://h/"]), "http://b:1")
}

///|
test "credentials of proxies" {
  assert_eq(
    proxy_plan(["-x", "p", "-U", "u:pw", "https://h/"]),
    "http://p:1080 u:pw",
  )
  // Those of the URL win over -U.
  assert_eq(
    proxy_plan(["-U", "v:w", "-x", "http://u%41:p%3a@p", "https://h/"]),
    "http://p:1080 uA:p:",
  )
  assert_eq(proxy_plan(["-x", "http://u@p", "https://h/"]), "http://p:1080 u:")
  // Versions of curl differ about empty ones.
  assert_eq(proxy_codes(["-x", "p", "-U", ":", "https://h/"]), [
    "unsupported-value",
  ])
  assert_eq(proxy_codes(["-x", "http://:@p", "https://h/"]), [
    "unsupported-value",
  ])
  assert_eq(
    proxy_plan(["-x", "p", "-U", ":b", "https://h/"]),
    "http://p:1080 :b",
  )
  assert_eq(proxy_codes(["-U", "v:w", "-x", "http://u:p@p", "https://h/"]), [
    "no-effect",
  ])
  assert_eq(proxy_codes(["-x", "p", "-U", "u", "https://h/"]), [
    "password-prompt",
  ])
}

///|
test "proxies that are reported" {
  assert_eq(proxy_codes(["-x", "p/x?y", "https://h/"]), ["proxy-path-ignored"])
  assert_eq(proxy_codes(["-U", "a:b", "https://h/"]), ["no-effect"])
  assert_eq(proxy_codes(["-p", "https://h/"]), ["no-effect"])
  assert_eq(proxy_codes(["-x", "p", "http://h/"]), ["proxy-without-tunnel"])
  assert_eq(proxy_codes(["-x", "p", "-L", "https://h/"]), [
    "proxy-without-tunnel",
  ])
  assert_eq(proxy_codes(["-x", "socks5h://p", "https://h/"]), [
    "unsupported-proxy",
  ])
  assert_eq(proxy_codes(["-x", "[::1]:8080", "https://h/"]), [
    "unsupported-proxy",
  ])
  assert_eq(proxy_codes(["-x", "ftp://p", "https://h/"]), [
    "unsupported-protocol",
  ])
  assert_eq(proxy_codes(["--noproxy", "*", "-x", "p", "https://h/"]), [
    "unsupported-option",
  ])
  assert_eq(
    proxy_codes(["--proxy-insecure", "-x", "https://p", "https://h/"]),
    ["unsupported-option"],
  )
}

///|
test "the program for a proxy" {
  let code = @curl2mbt.parse("curl -x http://u:pw@p:8080 -A agent https://h/a").plan.emit(
      secrets=Inline,
    ).code
  assert_true(
    code.contains(
      (
        #|  let proxy = @http.Client("http://p:8080", headers={ "Proxy-Authorization": "Basic " + @base64.encode(b"u:pw"), "User-Agent": "agent" })
        #|  let client = @http.Client("https://h", proxy~)
      ),
    ),
  )
  // A new tunnel for each redirect.
  let code = @curl2mbt.parse("curl -L -p -x p http://h/").plan.emit().code
  assert_true(
    code.contains(
      (
        #|    let proxy = @http.Client("http://p:1080")
        #|    let client = @http.Client(origin, proxy~)
      ),
    ),
  )
  // The credentials of the proxy come from the environment.
  let code = @curl2mbt.parse("curl -x p -U u:pw https://h/").plan.emit().code
  assert_true(code.contains("env(\"PROXY_AUTH\")"))
  assert_false(code.contains("u:pw"))
}

///|
test "proxies in plans and commands" {
  let plan = @curl2mbt.parse("curl -x p -U u:pw https://h/").plan
  assert_eq(plan.to_curl(), "curl -x http://p:1080 -U u:pw -p https://h/")
  assert_eq(@curl2mbt.RequestPlan::from_json(plan.to_json()), plan)
  let bad : Array[Json] = [
    { "url": "http://p" },
    { "url": "http://p:1/x" },
    { "url": "http://u@p:1" },
    { "url": "socks5://p:1" },
    { "url": "http://p:1", "user": "nocolon" },
  ]
  for proxy in bad {
    let json = plan.to_json()
    guard json is Object(fields) else { fail("not an object") }
    fields["proxy"] = proxy
    assert_true(
      try @curl2mbt.RequestPlan::from_json(json) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
}

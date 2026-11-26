///|
fn Settings::apply_proxy_user(self : Settings, option : Occurrence) -> Unit {
  if option.value.split_once(b':') is None {
    self.fail_at(
      option,
      "password-prompt",
      "curl asks for the password of the proxy, because the value has no colon",
      help="write \"user:password\"; \"user:\" for an empty password",
    )
    return
  }
  self.proxy_user = Some((option.value, option.value_location))
}

///|
/// The port of a proxy URL, which is 1080 for http if the URL has none,
/// unlike for the URL of a request. `parsed` is `text` as `parse_url` reads
/// it, which leaves out the default port of the scheme.
fn proxy_port(text : String, parsed : Url) -> Int32 {
  if parsed.port is Some(port) {
    return port
  }
  let rest = match text.find("://") {
    Some(at) => text[at + 3:]
    None => text[:]
  }
  let end = rest.find_by(c => c is ('/' | '?' | '#')).unwrap_or(rest.length())
  let authority = rest[:end]
  let host_port = match authority.rev_find("@") {
    Some(at) => authority[at + 1:]
    None => authority
  }
  let written = match host_port.rev_find(":") {
    Some(colon) => host_port[colon + 1:].iter().any(is_digit)
    None => false
  }
  match (parsed.scheme, written) {
    ("https", _) => 443
    (_, true) => 80
    (_, false) => 1080
  }
}

///|
/// The proxy of the request to `url`, from `-x`, `-U` and `-p`.
fn Settings::build_proxy(self : Settings, url : Url) -> Proxy? {
  guard self.proxy is Some((text, location)) && text != "" else {
    if self.proxy_user is Some((_, location)) {
      self.report.add(
        Note,
        "no-effect",
        "-U only matters with a proxy",
        location~,
      )
    }
    if self.proxy_tunnel {
      self.report.add(Note, "no-effect", "-p only matters with a proxy")
    }
    return None
  }
  let lower = text.to_lower()
  if lower.has_prefix("socks") {
    self.report.error(
      "unsupported-proxy",
      "SOCKS proxies are not supported",
      help="use an http or https proxy",
      location~,
    )
    return None
  }
  let parsed = parse_url(text, globbing=false, path_as_is=true) catch {
    UrlError({ code, message, help, }) => {
      self.report.error(code, "the proxy: \{message}", help?, location~)
      return None
    }
  }
  let proxy_url = parsed.url
  if proxy_url.host.has_prefix("[") {
    self.report.error(
      "unsupported-proxy",
      "a proxy at an IPv6 address is not supported, because moonbitlang/async 0.22 does not connect to one",
      help="use the name of the proxy",
      location~,
    )
    return None
  }
  if proxy_url.path != "/" || proxy_url.query is Some(_) {
    self.report.add(
      Note,
      "proxy-path-ignored",
      "curl ignores the path of a proxy URL",
      location~,
    )
  }
  // Credentials in the URL win over -U, as in curl.
  if parsed.user_info is Some(_) && self.proxy_user is Some((_, location)) {
    self.report.add(
      Warning,
      "no-effect",
      "curl takes the user name and password from the proxy URL and not from -U",
      location~,
    )
  }
  let user = match parsed.user_info {
    Some((user, password)) => {
      let bytes = percent_decode(user) + b":" + percent_decode(password)
      if bytes.iter().any(b => b < 0x20) {
        self.report.error(
          "bad-url",
          "the user name or password of the proxy has a control character",
          location~,
        )
      }
      Some(Value::from_pieces([Literal(bytes)]))
    }
    None => self.proxy_user.map(entry => entry.0)
  }
  if user is Some(value) && value.to_text() is Some(":") {
    self.report.error(
      "unsupported-value",
      "versions of curl differ about an empty user name and password of a proxy: some send them, and later ones send none",
      help="leave the credentials out, or give a user name",
      location~,
    )
  }
  if !self.proxy_tunnel {
    let help = "with -p curl tunnels every request with CONNECT, as programs do"
    if url.scheme == "http" {
      self.report.error(
        "proxy-without-tunnel",
        "curl sends a request for an http URL to the proxy as it is, which moonbitlang/async cannot do",
        help~,
        location~,
      )
    } else if self.follow {
      self.report.error(
        "proxy-without-tunnel",
        "after a redirect to an http URL, curl would send the request to the proxy as it is, which moonbitlang/async cannot do",
        help~,
        location~,
      )
    }
  }
  Some({
    scheme: proxy_url.scheme,
    host: proxy_url.host,
    port: proxy_port(text, proxy_url),
    user,
  })
}

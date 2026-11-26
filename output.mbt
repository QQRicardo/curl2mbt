///|
/// What `-o` or `-O` asks for.
priv enum OutputName {
  /// The name, or `-` for the standard output.
  Named(String)
  /// The last part of the path of the URL.
  Remote
}

///|
fn Settings::apply_output(self : Settings, option : Occurrence) -> Unit {
  let name = if option.name == "output" {
    guard self.text(option) is Some(text) else { return }
    if text == "" {
      self.fail_at(option, "unsupported-value", "the name of the file is empty")
      return
    }
    Named(text)
  } else {
    Remote
  }
  match self.output {
    Some(_) =>
      self.report.add(
        Warning,
        "ignored-output",
        "curl puts the response of each URL where an option for it says, so this one is for a URL that is not there",
        location=option.location,
      )
    None => self.output = Some((name, option.location))
  }
}

///|
/// The file that `-O` writes for a URL with this path: its last part that is
/// not empty.
fn remote_name(path : String) -> String {
  for part in path.split("/").collect().rev() {
    if !part.is_empty() {
      return part.to_owned()
    }
  }
  "curl_response"
}

///|
/// The file that gets the response, if not the standard output.
fn Settings::output_file(self : Settings, url : Url) -> String? {
  let name = match self.output {
    None if self.remote_name_all => remote_name(url.path)
    None | Some((Named("-"), _)) => return None
    Some((Named(name), _)) => name
    Some((Remote, _)) => remote_name(url.path)
  }
  let path = match self.output_dir {
    Some(dir) => "\{dir}/\{name}"
    None => name
  }
  if self.head is Some(location) {
    self.report.add(
      Warning,
      "headers-not-written",
      "curl writes the header lines of the response into the file; the program writes the body, which is empty",
      location~,
    )
  }
  if self.create_dirs && self.windows && path.contains("\\") {
    self.report.error(
      "unsupported-value",
      "--create-dirs is only supported for a file named with /",
      help="write / between the directories",
      location?=self.output.map(output => output.1),
    )
  }
  Some(path)
}

///|
/// The directory part of a path, if any.
fn parent_directory(path : String) -> String? {
  match path.rev_find("/") {
    Some(0) | None => None
    Some(at) => Some(path[:at].to_owned())
  }
}

///|
fn Settings::apply_retry(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(text) else { return }
  if option.name == "retry" {
    if text != "" && text.length() <= 6 && text.iter().all(is_digit) {
      let count = text
        .iter()
        .fold(init=0, (n, c) => n * 10 + (c.to_int() - '0'))
      self.retry_count = Some((count, option.location))
    } else {
      self.fail_at(
        option, "unsupported-value", "the number of retries must be between 0 and 999999",
      )
    }
    return
  }
  self.retry_details = Some(option.location)
  match parse_milliseconds(text) {
    // 0 is the default for both.
    Some(0) =>
      if option.name == "retry-delay" {
        self.retry_delay_ms = None
      } else {
        self.retry_max_time_ms = None
      }
    Some(ms) =>
      if option.name == "retry-delay" {
        self.retry_delay_ms = Some(ms)
      } else {
        self.retry_max_time_ms = Some(ms)
      }
    None =>
      self.fail_at(
        option, "unsupported-value", "the time must be a number of seconds with at most three decimals, up to 999999",
      )
  }
}

///|
/// What the retry options ask for.
fn Settings::build_retry(self : Settings) -> Retry? {
  guard self.retry_count is Some((count, _)) && count > 0 else {
    if self.retry_details is Some(location) {
      self.report.add(
        Warning,
        "no-effect",
        "without --retry, the options for retries have no effect",
        location~,
      )
    }
    return None
  }
  if self.retry_connrefused is Some(location) && !self.retry_all_errors {
    self.report.error(
      "unsupported-option",
      "--retry-connrefused is not supported, because a program cannot tell a refused connection from other errors",
      help="use --retry-all-errors, or remove it",
      location~,
    )
  }
  Some({
    count,
    delay_ms: self.retry_delay_ms,
    max_time_ms: self.retry_max_time_ms,
    all_errors: self.retry_all_errors,
  })
}

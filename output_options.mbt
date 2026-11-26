///|
/// The largest `--max-filesize` that a plan holds: what a JSON number holds
/// exactly.
let max_filesize_limit : Int64 = 9007199254740992L

///|
/// The number of bytes of the value of `--max-filesize`, as curl reads it:
/// digits and one of the units `b`, `k`, `m`, `g`, `t` and `p`, in either
/// case. `None` for what curl rejects or what is above `max_filesize_limit`.
fn parse_size(text : String) -> Int64? {
  guard text != "" else { return None }
  let (digits, unit) = match text.get_char(text.length() - 1) {
    Some(last) if is_digit(last) => (text[:], 1L)
    Some(last) => {
      let unit = match last {
        'b' | 'B' => 1L
        'k' | 'K' => 1024L
        'm' | 'M' => 1024L * 1024
        'g' | 'G' => 1024L * 1024 * 1024
        't' | 'T' => 1024L * 1024 * 1024 * 1024
        'p' | 'P' => 1024L * 1024 * 1024 * 1024 * 1024
        _ => return None
      }
      (text[:text.length() - 1], unit)
    }
    None => return None
  }
  guard digits != "" && digits.iter().all(is_digit) else { return None }
  let mut value = 0L
  for char in digits {
    value = value * 10 + (char.to_int() - '0').to_int64()
    if value > max_filesize_limit {
      return None
    }
  }
  if value > max_filesize_limit / unit {
    return None
  }
  Some(value * unit)
}

///|
fn Settings::apply_max_filesize(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(text) else { return }
  match parse_size(text) {
    Some(0L) => self.max_filesize = None
    Some(size) => self.max_filesize = Some(size)
    None =>
      self.fail_at(
        option, "unsupported-value", "the size must be a whole number of bytes, with k, m, g, t or p for a unit, up to 2^53 bytes",
      )
  }
}

///|
/// Reports the options about the output file that do not go with the rest.
fn Settings::check_output_options(
  self : Settings,
  output_file : String?,
) -> Unit {
  let options = [
    ("--no-clobber", self.no_clobber),
    ("--remove-on-error", self.remove_on_error),
  ]
  for entry in options {
    guard entry.1 is Some(location) else { continue }
    if output_file is None {
      self.report.add(
        Note,
        "no-effect",
        "\{entry.0} only matters with a file from -o or -O",
        location~,
      )
    } else if self.retry_count is Some(_) {
      self.report.error(
        "conflicting-options",
        "\{entry.0} together with --retry is not supported",
        location~,
      )
    }
  }
}

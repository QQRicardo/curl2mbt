///|
/// The time that `-z` compares with.
#derive(Eq, Debug)
pub enum TimeSource {
  /// Seconds since 1970, in UTC.
  At(Int64)
  /// The time the file of this name was last modified, when the request is
  /// made. Without such a file there is no condition, as with curl.
  FileTime(String)
}

///|
/// `-z`: a condition on the time the document was last modified.
#derive(Eq, Debug)
pub struct TimeCondition {
  /// `If-Modified-Since`, `If-Unmodified-Since`, or `Last-Modified` for
  /// `-z =`, which curl sends as it is.
  field : String
  time : TimeSource
}

///|
/// Whether the condition asks for a document modified before the time.
pub fn TimeCondition::unmodified(self : TimeCondition) -> Bool {
  self.field == "If-Unmodified-Since"
}

///|
let weekday_names : Array[String] = [
  "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
]

///|
let month_names : Array[String] = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

///|
/// Time zones that curl knows by name, with the minutes to add to get UTC.
let zone_names : Array[(String, Int32)] = [
  ("GMT", 0),
  ("UT", 0),
  ("UTC", 0),
  ("WET", 0),
  ("BST", -60),
  ("WAT", 60),
  ("AST", 240),
  ("ADT", 180),
  ("EST", 300),
  ("EDT", 240),
  ("CST", 360),
  ("CDT", 300),
  ("MST", 420),
  ("MDT", 360),
  ("PST", 480),
  ("PDT", 420),
  ("YST", 540),
  ("YDT", 480),
  ("HST", 600),
  ("HDT", 540),
  ("CAT", 600),
  ("AHST", 600),
  ("NT", 660),
  ("IDLW", 720),
  ("CET", -60),
  ("MET", -60),
  ("MEWT", -60),
  ("MEST", -120),
  ("CEST", -120),
  ("MESZ", -120),
  ("FWT", -60),
  ("FST", -120),
  ("EET", -120),
  ("WAST", -420),
  ("WADT", -480),
  ("CCT", -480),
  ("JST", -540),
  ("EAST", -600),
  ("EADT", -660),
  ("GST", -600),
  ("NZT", -720),
  ("NZST", -720),
  ("NZDT", -780),
  ("IDLE", -720),
  ("A", 60),
  ("B", 120),
  ("C", 180),
  ("D", 240),
  ("E", 300),
  ("F", 360),
  ("G", 420),
  ("H", 480),
  ("I", 540),
  ("K", 600),
  ("L", 660),
  ("M", 720),
  ("N", -60),
  ("O", -120),
  ("P", -180),
  ("Q", -240),
  ("R", -300),
  ("S", -360),
  ("T", -420),
  ("U", -480),
  ("V", -540),
  ("W", -600),
  ("X", -660),
  ("Y", -720),
  ("Z", 0),
]

///|
/// The number of days from 1970-01-01 to the first of `month` (0 to 11) of
/// `year`.
fn days_before(year : Int64, month : Int32) -> Int64 {
  let cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
  let leap_year = if month <= 1 { year - 1 } else { year }
  let leaps = leap_year / 4 -
    leap_year / 100 +
    leap_year / 400 -
    (1969L / 4 - 1969L / 100 + 1969L / 400)
  (year - 1970) * 365 + leaps + cumulative[month].to_int64()
}

///|
/// One or two digits at `at`, and where they end.
fn one_or_two_digits(chars : Array[Char], at : Int32) -> (Int32, Int32) {
  let first = chars[at].to_int() - '0'.to_int()
  if at + 1 < chars.length() && is_digit(chars[at + 1]) {
    (first * 10 + (chars[at + 1].to_int() - '0'.to_int()), at + 2)
  } else {
    (first, at + 1)
  }
}

///|
/// `HH:MM` or `HH:MM:SS` at `at`: the hour, minute, second and where it ends.
fn time_of_day(
  chars : Array[Char],
  at : Int32,
) -> (Int32, Int32, Int32, Int32)? {
  let digit_at = i => i < chars.length() && is_digit(chars[i])
  let (hour, next) = one_or_two_digits(chars, at)
  guard hour < 24 &&
    next < chars.length() &&
    chars[next] == ':' &&
    digit_at(next + 1) else {
    return None
  }
  let (minute, next) = one_or_two_digits(chars, next + 1)
  guard minute < 60 else { return None }
  if next < chars.length() && chars[next] == ':' && digit_at(next + 1) {
    let (second, end) = one_or_two_digits(chars, next + 1)
    if second <= 60 {
      Some((hour, minute, second, end))
    } else {
      None
    }
  } else {
    Some((hour, minute, 0, next))
  }
}

///|
/// The time that `text` stands for, in seconds since 1970, read with the
/// rules of curl for dates: names of days, months and time zones in any
/// case, times, numbers for the day and the year, `YYYYMMDD`, and `+HHMM`
/// or `-HHMM`, in any order and with anything else than letters and digits
/// between them. `None` if curl would not read it as a date.
pub fn parse_curl_date(text : StringView) -> Int64? {
  let chars = text.iter().collect()
  let mut at = 0
  let mut weekday = -1
  let mut month = -1
  let mut day = -1
  let mut hour = -1
  let mut minute = -1
  let mut second = -1
  let mut year = -1
  let mut zone : Int64? = None
  let mut day_next = true
  let mut parts = 0
  while at < chars.length() && parts < 6 {
    while at < chars.length() && !is_alpha(chars[at]) && !is_digit(chars[at]) {
      at += 1
    }
    if at >= chars.length() {
      break
    }
    if is_alpha(chars[at]) {
      let start = at
      while at < chars.length() && is_alpha(chars[at]) && at - start < 12 {
        at += 1
      }
      let word = String::from_array(chars[start:at]).to_lower()
      let mut found = false
      if at - start != 12 {
        if weekday == -1 {
          for i, name in weekday_names {
            if word == name.to_lower() || word == name[:3].to_owned().to_lower() {
              weekday = i
              found = true
              break
            }
          }
        }
        if !found && month == -1 && word.length() == 3 {
          for i, name in month_names {
            if word == name.to_lower() {
              month = i
              found = true
              break
            }
          }
        }
        if !found && zone is None {
          for entry in zone_names {
            if word == entry.0.to_lower() {
              zone = Some(entry.1.to_int64() * 60)
              found = true
              break
            }
          }
        }
      }
      if !found {
        return None
      }
    } else if second == -1 && time_of_day(chars, at) is Some((h, m, s, end)) {
      hour = h
      minute = m
      second = s
      at = end
    } else {
      let start = at
      let mut value = 0
      while at < chars.length() && is_digit(chars[at]) {
        value = value * 10 + (chars[at].to_int() - '0'.to_int())
        at += 1
        if value > 99999999 {
          return None
        }
      }
      let digits = at - start
      let mut found = false
      if zone is None &&
        digits == 4 &&
        value <= 1400 &&
        start > 0 &&
        chars[start - 1] is ('+' | '-') {
        found = true
        let offset = ((value / 100 * 60 + value % 100) * 60).to_int64()
        zone = Some(if chars[start - 1] == '+' { -offset } else { offset })
      } else if digits == 8 && year == -1 && month == -1 && day == -1 {
        found = true
        year = value / 10000
        month = value % 10000 / 100 - 1
        day = value % 100
      }
      if !found && day_next && day == -1 {
        if value > 0 && value < 32 {
          day = value
          found = true
        }
        day_next = false
      }
      if !found && !day_next && year == -1 {
        year = value
        found = true
        if year < 100 {
          year += if year > 70 { 1900 } else { 2000 }
        }
        if day == -1 {
          day_next = true
        }
      }
      if !found {
        return None
      }
    }
    parts += 1
  }
  if second == -1 {
    hour = 0
    minute = 0
    second = 0
  }
  if day == -1 || month == -1 || year == -1 || year < 1583 {
    return None
  }
  if day > 31 || month > 11 || hour > 23 || minute > 59 || second > 60 {
    return None
  }
  let days = days_before(year.to_int64(), month) + (day - 1).to_int64()
  let time = days * 86400 +
    (hour * 3600 + minute * 60 + second).to_int64() +
    zone.unwrap_or(0)
  // curl never gives -1 for a date.
  Some(if time == -1 { 0 } else { time })
}

///|
/// `time` as HTTP writes dates, such as `Sun, 06 Nov 1994 08:49:37 GMT`.
/// From 1970 to the end of 9999.
pub fn http_date(time : Int64) -> String {
  let days = time / 86400
  let seconds = (time % 86400).to_int()
  // From the days since 1970 to the date, in the proleptic Gregorian
  // calendar, with years that start in March.
  let shifted = days + 719468
  let era = shifted / 146097
  let day_of_era = shifted - era * 146097
  let year_of_era = (
      day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096
    ) /
    365
  let day_of_year = day_of_era -
    (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
  let shifted_month = (5L * day_of_year + 2) / 153
  let day = (day_of_year - (153L * shifted_month + 2) / 5 + 1).to_int()
  let month = (if shifted_month < 10 {
    shifted_month + 2
  } else {
    shifted_month - 10
  }).to_int()
  let year = (year_of_era + era * 400 + (if month <= 1 { 1L } else { 0L })).to_int()
  let weekday = weekday_names[((days + 3) % 7).to_int()][:3]
  let two = (n : Int32) => if n < 10 { "0\{n}" } else { n.to_string() }
  "\{weekday}, \{two(day)} \{month_names[month]} \{year} \{two(seconds / 3600)}:\{two(seconds / 60 % 60)}:\{two(seconds % 60)} GMT"
}

///|
/// The latest time that `http_date` writes: the end of 9999.
let latest_time : Int64 = 253402300799L

///|
/// `-z`: a date, or the name of a file, after `-` for If-Unmodified-Since,
/// `=` for Last-Modified, or `+`, which is the default, If-Modified-Since.
fn Settings::apply_time_cond(self : Settings, option : Occurrence) -> Unit {
  guard self.text(option) is Some(text) else { return }
  let (field, rest) = match text.get_char(0) {
    Some('-') => ("If-Unmodified-Since", text[1:].to_owned())
    Some('=') => ("Last-Modified", text[1:].to_owned())
    Some('+') => ("If-Modified-Since", text[1:].to_owned())
    _ => ("If-Modified-Since", text)
  }
  let time = match parse_curl_date(rest) {
    Some(time) if time < 0 || time > latest_time => {
      self.fail_at(
        option, "unsupported-value", "the date must be from 1970 to 9999; curl fails with earlier ones",
      )
      return
    }
    Some(time) => At(time)
    None if rest.is_empty() || rest.contains("\u0000") => {
      self.fail_at(
        option, "unsupported-value", "the value of -z must be a date or the name of a file",
      )
      return
    }
    // curl takes what is not a date for the name of a file.
    None => FileTime(rest)
  }
  self.time_cond = Some(({ field, time, }, option.value_location))
}

///|
/// Reports what curl would do otherwise with `-z`.
fn Settings::check_time_cond(self : Settings) -> Unit {
  guard self.time_cond is Some((condition, location)) else { return }
  if self.has_line(condition.field) {
    self.report.error(
      "conflicting-options",
      "-z together with a header line for \{condition.field} is not supported, because curl then sends the line and still checks the time",
      help="leave out one of them",
      location~,
    )
  }
  if self.range is Some(_) {
    self.report.error(
      "conflicting-options",
      "-z together with -r is not supported",
      location~,
    )
  }
  if self.no_clobber is Some(_) &&
    self.remove_on_error is Some(_) &&
    self.fail_with_body {
    self.report.error(
      "conflicting-options",
      "-z together with --no-clobber, --remove-on-error and --fail-with-body is not supported",
      location~,
    )
  }
  if condition.time is FileTime(name) {
    self.report.add(
      Note,
      "time-from-file",
      "\{name} is not a date to curl, so the time is that of the file \{name} when the request is made; without the file there is no condition",
      location~,
    )
  }
}

///|
/// How a program reads Last-Modified, with the rules of curl for dates and
/// the time zones of HTTP.
let time_cond_code : String =
  #|
  #|///|
  #|/// The time of a date in Last-Modified, in seconds since 1970, read with
  #|/// the rules of curl for dates, or `None` if it is not one.
  #|fn http_date_time(text : String) -> Int64? {
  #|  let chars : Array[Char] = text.iter().collect()
  #|  let digit = (i : Int) => i < chars.length() && chars[i] is ('0'..='9')
  #|  let letter = (i : Int) => {
  #|    i < chars.length() && chars[i] is ('a'..='z' | 'A'..='Z')
  #|  }
  #|  let value = (i : Int) => chars[i].to_int() - '0'.to_int()
  #|  let one_or_two = (i : Int) => if digit(i + 1) {
  #|    (value(i) * 10 + value(i + 1), i + 2)
  #|  } else {
  #|    (value(i), i + 1)
  #|  }
  #|  fn clock_at(i : Int) -> (Int, Int, Int, Int)? {
  #|    let (hour, next) = one_or_two(i)
  #|    guard hour < 24 && next < chars.length() && chars[next] == ':' && digit(next + 1) else {
  #|      return None
  #|    }
  #|    let (minute, next) = one_or_two(next + 1)
  #|    guard minute < 60 else { return None }
  #|    if next < chars.length() && chars[next] == ':' && digit(next + 1) {
  #|      let (second, end) = one_or_two(next + 1)
  #|      if second <= 60 { Some((hour, minute, second, end)) } else { None }
  #|    } else {
  #|      Some((hour, minute, 0, next))
  #|    }
  #|  }
  #|
  #|  let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
  #|  let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
  #|  let mut at = 0
  #|  let mut parts = 0
  #|  let mut weekday = false
  #|  let mut day = -1
  #|  let mut month = -1
  #|  let mut year = -1
  #|  let mut zone : Int64? = None
  #|  let mut clock : (Int, Int, Int)? = None
  #|  let mut day_next = true
  #|  while at < chars.length() && parts < 6 {
  #|    while at < chars.length() && !letter(at) && !digit(at) {
  #|      at += 1
  #|    }
  #|    if at >= chars.length() {
  #|      break
  #|    }
  #|    if letter(at) {
  #|      let start = at
  #|      while letter(at) && at - start < 12 {
  #|        at += 1
  #|      }
  #|      let word = String::from_array(chars[start:at]).to_lower()
  #|      let mut found = false
  #|      if at - start != 12 {
  #|        if !weekday && weekdays.contains(word) {
  #|          weekday = true
  #|          found = true
  #|        }
  #|        if !found && month == -1 && months.search(word) is Some(m) {
  #|          month = m
  #|          found = true
  #|        }
  #|        if !found && zone is None && word is ("gmt" | "ut" | "utc" | "z") {
  #|          zone = Some(0)
  #|          found = true
  #|        }
  #|      }
  #|      if !found {
  #|        return None
  #|      }
  #|    } else if clock is None && clock_at(at) is Some((h, m, s, end)) {
  #|      clock = Some((h, m, s))
  #|      at = end
  #|    } else {
  #|      let start = at
  #|      let mut number = 0
  #|      while digit(at) {
  #|        number = number * 10 + value(at)
  #|        at += 1
  #|        if number > 99999999 {
  #|          return None
  #|        }
  #|      }
  #|      let digits = at - start
  #|      let mut found = false
  #|      if zone is None && digits == 4 && number <= 1400 && start > 0 && chars[start - 1] is ('+' | '-') {
  #|        found = true
  #|        let offset = ((number / 100 * 60 + number % 100) * 60).to_int64()
  #|        zone = Some(if chars[start - 1] == '+' { -offset } else { offset })
  #|      } else if digits == 8 && year == -1 && month == -1 && day == -1 {
  #|        found = true
  #|        year = number / 10000
  #|        month = number % 10000 / 100 - 1
  #|        day = number % 100
  #|      }
  #|      if !found && day_next && day == -1 {
  #|        if number > 0 && number < 32 {
  #|          day = number
  #|          found = true
  #|        }
  #|        day_next = false
  #|      }
  #|      if !found && !day_next && year == -1 {
  #|        year = number
  #|        found = true
  #|        if year < 100 {
  #|          year += if year > 70 { 1900 } else { 2000 }
  #|        }
  #|        if day == -1 {
  #|          day_next = true
  #|        }
  #|      }
  #|      if !found {
  #|        return None
  #|      }
  #|    }
  #|    parts += 1
  #|  }
  #|  let (hour, minute, second) = clock.unwrap_or((0, 0, 0))
  #|  guard day != -1 && month != -1 && year >= 1583 && day <= 31 && month <= 11 else {
  #|    return None
  #|  }
  #|  let cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
  #|  let leap_year = (if month <= 1 { year - 1 } else { year }).to_int64()
  #|  let leaps = leap_year / 4 - leap_year / 100 + leap_year / 400 - 477L
  #|  let days = (year.to_int64() - 1970) * 365 + leaps + cumulative[month].to_int64() + (day - 1).to_int64()
  #|  Some(days * 86400 + (hour * 3600 + minute * 60 + second).to_int64() + zone.unwrap_or(0))
  #|}

///|
/// How a program writes the time of a file for `-z`.
let file_time_code : String =
  #|
  #|///|
  #|/// The time `path` was last modified, as HTTP writes dates, or `None`
  #|/// if there is no such file, which leaves out the condition, as in curl.
  #|async fn file_time(path : String) -> (Int64, String)? {
  #|  let (time, _) = @fs.mtime(path) catch {
  #|    _ => return None
  #|  }
  #|  let days = time / 86400
  #|  let seconds = (time % 86400).to_int()
  #|  let shifted = days + 719468
  #|  let era = shifted / 146097
  #|  let day_of_era = shifted - era * 146097
  #|  let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365
  #|  let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
  #|  let shifted_month = (5L * day_of_year + 2) / 153
  #|  let day = (day_of_year - (153L * shifted_month + 2) / 5 + 1).to_int()
  #|  let month = (if shifted_month < 10 { shifted_month + 2 } else { shifted_month - 10 }).to_int()
  #|  let year = (year_of_era + era * 400 + (if month <= 1 { 1L } else { 0L })).to_int()
  #|  let weekdays = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
  #|  let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  #|  let two = (n : Int) => if n < 10 { "0\{n}" } else { n.to_string() }
  #|  let date = "\{weekdays[(days % 7).to_int()]}, \{two(day)} \{months[month]} \{year} \{two(seconds / 3600)}:\{two(seconds / 60 % 60)}:\{two(seconds % 60)} GMT"
  #|  Some((time, date))
  #|}

///|
/// How a program decides, as curl does, that the condition of `-z` is not
/// met.
let condition_unmet_code : String =
  #|
  #|///|
  #|/// Whether Last-Modified of `response` shows that the document is not
  #|/// newer than `time`, or with `unmodified` not older, so that curl
  #|/// answers 304 itself and writes no body.
  #|fn condition_unmet(response : @http.Response, time : Int64, unmodified : Bool) -> Bool {
  #|  guard time != 0 &&
  #|    response.headers.get("Last-Modified") is Some(text) &&
  #|    http_date_time(text) is Some(modified) &&
  #|    modified != 0 else {
  #|    return false
  #|  }
  #|  if unmodified {
  #|    modified >= time
  #|  } else {
  #|    modified <= time
  #|  }
  #|}

///|
/// The statements in `main` that answer 304 instead of the server when the
/// condition of `-z` is not met, as curl does, and define `unmet`.
fn Emitter::time_cond_statements(self : Emitter) -> Array[String] {
  guard self.plan.time_condition is Some(condition) else { return [] }
  let unmodified = condition.unmodified()
  let check = match condition.time {
    At(time) => "condition_unmet(response, \{time}L, \{unmodified})"
    FileTime(path) =>
      "file_time(\"\{escape_text(path)}\") is Some((time, _)) &&\n    condition_unmet(response, time, \{unmodified})"
  }
  [
    "  // curl answers 304 itself when Last-Modified shows that the condition",
    "  // of -z is not met.",
    "  let unmet = \{check}",
    "  let body = if unmet { (b\"\" : Bytes) as &@io.Data } else { body }",
  ]
}

///|
/// The statements that add the field of `-z` with the time of a file to
/// `headers`, if there is such a file.
fn Emitter::file_time_header(self : Emitter, indent : String) -> Array[String] {
  guard self.plan.time_condition is Some({ field, time: FileTime(_), }) else {
    return []
  }
  [
    "\{indent}if condition_time is Some((_, date)) {",
    "\{indent}  headers[\"\{field}\"] = date",
    "\{indent}}",
  ]
}

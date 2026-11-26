///|
/// Reads the text of a config file of curl, as `curl -K FILE` does, into the
/// plan of the request it describes. Each line holds one option, with or
/// without its dashes, and its value, quoted or not, after blanks, `=` or `:`:
///
/// ```text
/// url = "https://api.example.com/v1/items"
/// header = "Accept: application/json"
/// -u user:password
/// ```
///
/// Values are taken literally; nothing in them is a variable. Lines that
/// curl reads differently than they look are rejected: blanks before an
/// option, a value that goes on after a blank without quotes, text after
/// the closing quote, and a quote that is not closed.
pub fn parse_config(text : StringView) -> Parsed raise CurlError {
  let report = Report::{ found: [], }
  let options : Array[Occurrence] = []
  let mut start = 0
  while start <= text.length() {
    let end = for i = start; i < text.length(); i = i + 1 {
      if text.get(i) is Some('\n') {
        break i
      }
    } nobreak {
      text.length()
    }
    read_config_line(text, start, end, report, options)
    start = end + 1
  }
  plan_of_options(options, [], report, windows=false)
}

///|
/// The blanks between the parts of a line in a config file.
fn is_config_space(unit : UInt16) -> Bool {
  unit is (' ' | '\t')
}

///|
/// Reads the line from `start` to `end` of a config file, without its line
/// break, into `options`.
fn read_config_line(
  text : StringView,
  start : Int32,
  end : Int32,
  report : Report,
  options : Array[Occurrence],
) -> Unit {
  // A file from Windows ends its lines with CR LF.
  let crlf = end > start && text.get(end - 1) is Some('\r')
  let end = if crlf { end - 1 } else { end }
  let fail = (message : String, help : String, from : Int32, to : Int32) => {
    report.error(
      "config-syntax",
      message,
      help~,
      location=Text(start=from, end=to),
    )
  }
  let mut pos = start
  while pos < end && text.get(pos) is Some(unit) && is_config_space(unit) {
    pos += 1
  }
  if crlf && pos == end && pos > start {
    fail(
      "versions of curl differ about a line of blanks that ends with CR", "remove the blanks",
      start, end,
    )
    return
  }
  if pos == end || text.get(pos) is Some('#') {
    return
  }
  if pos > start {
    fail(
      "curl does not read an option after blanks at the start of a line", "remove the blanks",
      start, end,
    )
    return
  }
  for i in start..<end {
    match text.get(i) {
      Some('\u{0}') => {
        fail("curl ends the line at a NUL character", "remove it", i, i + 1)
        return
      }
      // curl takes them for blanks in some places and not in others.
      Some('\r' | '\u{0B}' | '\u{0C}') => {
        fail(
          "a CR, vertical tab or form feed in a line is not supported",
          "remove it; in quotes, write \\r or \\v",
          i,
          i + 1,
        )
        return
      }
      _ => ()
    }
  }
  let dashed = text.get(pos) is Some('-')
  let is_separator = (unit : UInt16) => !dashed && unit is ('=' | ':')
  let name_start = pos
  while pos < end &&
        text.get(pos) is Some(unit) &&
        !is_config_space(unit) &&
        !is_separator(unit) {
    pos += 1
  }
  let name = text[name_start:pos].to_owned()
  let name_end = pos
  // curl 8.19 takes the CR into the option, and later versions do not.
  if crlf && name_end == end {
    fail(
      "versions of curl differ about a CR right after an option", "put the value in quotes after a blank, or end the line with LF only",
      name_start, end,
    )
    return
  }
  while pos < end &&
        text.get(pos) is Some(unit) &&
        (is_config_space(unit) || is_separator(unit)) {
    pos += 1
  }
  let value_start = pos
  let value = StringBuilder()
  let mut given = false
  if text.get(pos) is Some('"') {
    given = true
    pos += 1
    let mut closed = false
    while pos < end {
      let mut at = pos
      match text.get(pos) {
        Some('"') => {
          pos += 1
          closed = true
          break
        }
        Some('\\') => {
          if pos + 1 >= end {
            break
          }
          at = pos + 1
          let escaped = match text.get(at) {
            Some('t') => Some('\t')
            Some('n') => Some('\n')
            Some('r') => Some('\r')
            Some('v') => Some('\u{0B}')
            _ => None
          }
          if escaped is Some(char) {
            value.write_char(char)
            pos = at + 1
            continue
          }
        }
        _ => ()
      }
      // Any other character, also after a backslash, is taken as it is.
      guard text.get_char(at) is Some(char) else {
        fail(
          "half of a surrogate pair is not a character",
          "remove it",
          at,
          at + 1,
        )
        return
      }
      value.write_char(char)
      pos = at + char.utf16_len()
    }
    if !closed {
      fail(
        "the quote is not closed on this line", "end the value with \"; a value cannot go on to the next line, but \\n in quotes is a line break",
        value_start, end,
      )
      return
    }
  } else {
    while pos < end && text.get(pos) is Some(unit) && !is_config_space(unit) {
      guard text.get_char(pos) is Some(char) else {
        fail(
          "half of a surrogate pair is not a character",
          "remove it",
          pos,
          pos + 1,
        )
        return
      }
      value.write_char(char)
      pos += char.utf16_len()
    }
    given = pos > value_start
  }
  let value_end = pos
  while pos < end && text.get(pos) is Some(unit) && is_config_space(unit) {
    pos += 1
  }
  if pos < end && !(text.get(pos) is Some('#')) {
    fail(
      if text.get(value_start) is Some('"') {
        "curl ignores what comes after the closing quote"
      } else {
        "curl ends the value at the first blank and ignores the rest"
      },
      "put the whole value in quotes",
      pos,
      end,
    )
    return
  }
  let option_word = Word::{
    value: Value::literal(if dashed { name } else { "--\{name}" }),
    location: Text(start=name_start, end=name_end),
  }
  let words = [option_word]
  if given {
    words.push({
      value: Value::literal(value.to_string()),
      location: Text(start=value_start, end=value_end),
    })
  }
  let long = !dashed || name.has_prefix("--")
  let found_before = report.found.length()
  let used = if long {
    split_long(words, 0, options, report)
  } else {
    split_short(words, 0, options, report)
  }
  // An empty value in quotes is no value to curl.
  if used == 1 &&
    report.found.length() == found_before &&
    words is [_, { value, location, }] &&
    !value.is_empty() {
    report.error(
      "unexpected-value",
      "curl rejects a value after an option that takes none or has one already",
      help="remove the value",
      location~,
    )
  }
}

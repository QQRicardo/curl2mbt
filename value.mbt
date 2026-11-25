///|
/// A part of a `Value`.
#derive(Eq, Debug)
pub(all) enum Piece {
  /// Bytes known from the command.
  Literal(Bytes)
  /// What the environment variable of this name holds when the request is
  /// made, as in `"Bearer $TOKEN"`.
  Env(String)
  /// What the file holds when the request is made. Only in bodies.
  File(path~ : String, read~ : FileRead)
}

///|
/// How the content of a file becomes data.
#derive(Eq, Debug)
pub(all) enum FileRead {
  /// As it is.
  Whole
  /// Without CR, LF and NUL.
  WithoutLineBreaks
  /// Encoded as in a form, after this name and `=`, unless the name is empty.
  /// Nothing at all if the file is empty.
  FormEncoded(String)
}

///|
/// Text of a request that may refer to environment variables. Never holds an
/// empty literal or two literals in a row.
#derive(Eq, Debug)
pub struct Value {
  priv pieces : Array[Piece]
}

///|
/// The value made of `pieces`, with literals in a row joined.
fn Value::from_pieces(pieces : Array[Piece]) -> Value {
  let out : Array[Piece] = []
  for piece in pieces {
    match (piece, out.last()) {
      (Literal(bytes), Some(Literal(before))) =>
        out[out.length() - 1] = Literal(before + bytes)
      (Literal(bytes), _) => if bytes.length() > 0 { out.push(piece) }
      (Env(_) | File(_), _) => out.push(piece)
    }
  }
  { pieces: out, }
}

///|
fn Value::literal(text : StringView) -> Value {
  Value::from_pieces([Literal(@utf8.encode(text))])
}

///|
/// The parts of the value, in order.
pub fn Value::pieces(self : Value) -> ArrayView[Piece] {
  self.pieces[:]
}

///|
fn Value::append(self : Value, other : Value) -> Value {
  Value::from_pieces(self.pieces + other.pieces)
}

///|
/// The bytes of the value, unless it refers to an environment variable or a
/// file.
pub fn Value::to_bytes(self : Value) -> Bytes? {
  match self.pieces {
    [] => Some(b"")
    [Literal(bytes)] => Some(bytes)
    _ => None
  }
}

///|
/// The text of the value, unless it refers to an environment variable or a
/// file, or is not valid UTF-8.
pub fn Value::to_text(self : Value) -> String? {
  guard self.to_bytes() is Some(bytes) else { return None }
  Some(@utf8.decode(bytes, ignore_bom=true)) catch {
    _ => None
  }
}

///|
/// The names of the environment variables the value refers to, in order.
pub fn Value::env_names(self : Value) -> Array[String] {
  self.pieces.filter_map(piece => {
    match piece {
      Env(name) => Some(name)
      Literal(_) | File(_) => None
    }
  })
}

///|
fn Value::has_file(self : Value) -> Bool {
  self.pieces.iter().any(piece => piece is File(_))
}

///|
fn Value::is_empty(self : Value) -> Bool {
  self.pieces.is_empty()
}

///|
/// Whether one of the literal bytes passes `test`.
fn Value::any_byte(self : Value, pred : (Byte) -> Bool) -> Bool {
  self.pieces
  .iter()
  .any(piece => piece is Literal(bytes) && bytes.iter().any(pred))
}

///|
/// Splits the value at the first literal `byte`, which is in neither half.
fn Value::split_once(self : Value, byte : Byte) -> (Value, Value)? {
  for i, piece in self.pieces {
    guard piece is Literal(bytes) else { continue }
    guard index_of(bytes, b => b == byte) is Some(at) else { continue }
    let before = self.pieces[:i].to_owned()
    before.push(Literal(bytes[:at].to_owned()))
    let after : Array[Piece] = [Literal(bytes[at + 1:].to_owned())]
    after.append(self.pieces[i + 1:])
    return Some((Value::from_pieces(before), Value::from_pieces(after)))
  }
  None
}

///|
/// The value without its first `count` bytes, which must be literal.
fn Value::drop_bytes(self : Value, count : Int32) -> Value {
  guard self.pieces is [Literal(bytes), .. rest] else { return self }
  let out : Array[Piece] = [Literal(bytes[count:].to_owned())]
  out.append(rest)
  Value::from_pieces(out)
}

///|
/// The literal bytes the value starts with.
fn Value::prefix(self : Value) -> Bytes {
  match self.pieces {
    [Literal(bytes), ..] => bytes
    _ => b""
  }
}

///|
/// The index of the first of `bytes` that passes `pred`.
fn index_of(bytes : Bytes, pred : (Byte) -> Bool) -> Int32? {
  for i in 0..<bytes.length() {
    if pred(bytes[i]) {
      return Some(i)
    }
  }
  None
}

///|
fn is_blank(byte : Byte) -> Bool {
  byte is (b' ' | b'\t')
}

///|
/// The value without literal blanks at its ends.
fn Value::trim(self : Value) -> Value {
  let pieces = self.pieces.copy()
  if pieces is [Literal(bytes), ..] {
    let mut start = 0
    while start < bytes.length() && is_blank(bytes[start]) {
      start += 1
    }
    pieces[0] = Literal(bytes[start:].to_owned())
  }
  if pieces is [.., Literal(bytes)] {
    let mut end = bytes.length()
    while end > 0 && is_blank(bytes[end - 1]) {
      end -= 1
    }
    pieces[pieces.length() - 1] = Literal(bytes[:end].to_owned())
  }
  Value::from_pieces(pieces)
}

///|
/// Whether the value can be the value of a header field: text without
/// control characters other than tab.
fn Value::is_field_value(self : Value) -> Bool {
  self.pieces
  .iter()
  .all(piece => {
    match piece {
      Env(_) => true
      File(_) => false
      Literal(bytes) =>
        bytes.iter().all(b => b is b'\t' || (b >= 0x20 && b != 0x7F)) &&
        (try @utf8.decode(bytes, ignore_bom=true) catch {
          _ => false
        } noraise {
          _ => true
        })
    }
  })
}

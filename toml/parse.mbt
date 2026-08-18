// TOML bytes to `Value`.
//
// Built through a mutable tree rather than straight into `Value`, because a
// `[a.b.c]` header has to reach into a table that may not exist yet and
// `Value::Map` holds immutable pairs. The tree is converted once at the end.
//
// String *values* are never decoded: an unescaped one is a `BytesView` into
// the input, which is what the data model holds anyway, so parsing borrows.
// Keys are decoded, because they get compared, interpolated into error paths,
// and are short.
//
// Not supported, deliberately: datetimes, which have no counterpart in `Value`
// and are refused with a message rather than coerced into a string that would
// no longer be a datetime; and multi-line strings, which nothing in this
// package writes.

///|
priv enum Node {
  Leaf(@data.Value)
  Sub(Table)
  Arr(Array[Table])
}

///|
priv struct Table {
  entries : Array[(String, Node)]
}

///|
fn Table::new() -> Table {
  { entries: [] }
}

///|
fn Table::find(self : Table, key : String) -> Node? {
  for entry in self.entries {
    if entry.0 == key {
      return Some(entry.1)
    }
  }
  None
}

///|
/// The sub-table at `key`, created if absent.
fn Table::table_at(
  self : Table,
  key : String,
  path : @data.Path,
) -> Table raise @data.DeError {
  match self.find(key) {
    Some(Sub(t)) => t
    Some(Arr(tables)) =>
      // `[a.b]` after `[[a]]` addresses the last element, as TOML specifies.
      match tables.last() {
        Some(t) => t
        None =>
          raise @data.DeCustom(
            path~,
            message="TOML: `\{key}` is an empty array of tables",
          )
      }
    Some(Leaf(_)) =>
      raise @data.DeCustom(
        path~,
        message="TOML: `\{key}` is already a value, not a table",
      )
    None => {
      let t = Table::new()
      self.entries.push((key, Sub(t)))
      t
    }
  }
}

///|
fn Table::push_array_table(
  self : Table,
  key : String,
  path : @data.Path,
) -> Table raise @data.DeError {
  let fresh = Table::new()
  match self.find(key) {
    Some(Arr(tables)) => {
      tables.push(fresh)
      fresh
    }
    None => {
      self.entries.push((key, Arr([fresh])))
      fresh
    }
    _ =>
      raise @data.DeCustom(
        path~,
        message="TOML: `\{key}` is not an array of tables",
      )
  }
}

///|
fn Table::to_value(self : Table) -> @data.Value {
  let entries = []
  for entry in self.entries {
    let key = @data.Value::Str(@utf8.encode(entry.0)[:])
    entries.push((key, node_to_value(entry.1)))
  }
  @data.Map(ReadOnlyArray::from_array(entries))
}

///|
fn node_to_value(node : Node) -> @data.Value {
  match node {
    Leaf(v) => v
    Sub(t) => t.to_value()
    Arr(tables) =>
      @data.Seq(ReadOnlyArray::from_array(tables.map(t => t.to_value())))
  }
}

///|
/// A Unicode scalar value as UTF-8, for the `\u` and `\U` escapes — the only
/// place this parser has to encode anything.
fn write_utf8(out : @buffer.Buffer, code : Int) -> Unit {
  if code < 0x80 {
    out.write_byte(code.to_byte())
  } else if code < 0x800 {
    out.write_byte((0xC0 | (code >> 6)).to_byte())
    out.write_byte((0x80 | (code & 0x3F)).to_byte())
  } else if code < 0x10000 {
    out.write_byte((0xE0 | (code >> 12)).to_byte())
    out.write_byte((0x80 | ((code >> 6) & 0x3F)).to_byte())
    out.write_byte((0x80 | (code & 0x3F)).to_byte())
  } else {
    out.write_byte((0xF0 | (code >> 18)).to_byte())
    out.write_byte((0x80 | ((code >> 12) & 0x3F)).to_byte())
    out.write_byte((0x80 | ((code >> 6) & 0x3F)).to_byte())
    out.write_byte((0x80 | (code & 0x3F)).to_byte())
  }
}

// ---- the parser ----

///|
priv struct Parser {
  src : Bytes
  mut pos : Int
}

///|
const EOF : Int = -1

///|
fn parse(input : Bytes) -> @data.Value raise @data.DeError {
  let p = Parser::{ src: input, pos: 0 }
  let root = Table::new()
  let mut current = root
  let mut prefix : Array[String] = []
  for ;; {
    p.trivia()
    if p.done() {
      break
    }
    if p.peek() == 0x5B { // [
      p.bump()
      let array_of = p.peek() == 0x5B
      if array_of {
        p.bump()
      }
      let path = p.key_path()
      p.expect(0x5D) // ]
      if array_of {
        p.expect(0x5D)
      }
      guard path.length() > 0 else {
        raise @data.DeCustom(path=Root, message="TOML: empty table header")
      }
      let mut table = root
      for i, segment in path {
        let at = @data.Root.key(path_prefix(path, i))
        table = if i == path.length() - 1 && array_of {
          table.push_array_table(segment, at)
        } else {
          table.table_at(segment, at)
        }
      }
      current = table
      prefix = path
      continue
    }
    let path = p.key_path()
    guard path.length() > 0 else {
      raise @data.DeCustom(path=Root, message="TOML: expected a key")
    }
    p.expect(0x3D) // =
    let at = @data.Root.key(
      path_prefix(prefix + path, prefix.length() + path.length() - 1),
    )
    let value = p.value(at)
    let mut table = current
    for i in 0..<(path.length() - 1) {
      table = table.table_at(path[i], at)
    }
    let leaf = path[path.length() - 1]
    guard table.find(leaf) is None else {
      raise @data.DeCustom(path=at, message="TOML: duplicate key `\{leaf}`")
    }
    table.entries.push((leaf, Leaf(value)))
  }
  root.to_value()
}

///|
fn path_prefix(path : Array[String], upto : Int) -> String {
  let parts = []
  for i in 0..<(upto + 1) {
    if i < path.length() {
      parts.push(path[i])
    }
  }
  parts.join(".")
}

///|
fn Parser::done(self : Parser) -> Bool {
  self.pos >= self.src.length()
}

///|
fn Parser::peek(self : Parser) -> Int {
  if self.done() {
    EOF
  } else {
    self.src[self.pos].to_int()
  }
}

///|
fn Parser::bump(self : Parser) -> Unit {
  self.pos = self.pos + 1
}

///|
/// Whitespace, newlines and comments — everything between two meaningful
/// tokens. All ASCII, so skipping it needs no decoding.
fn Parser::trivia(self : Parser) -> Unit {
  while !self.done() {
    let c = self.peek()
    if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      self.bump()
    } else if c == 0x23 { // #
      while !self.done() && self.peek() != 0x0A {
        self.bump()
      }
    } else {
      break
    }
  }
}

///|
/// Spaces and tabs only, which is what may sit inside a line.
fn Parser::spaces(self : Parser) -> Unit {
  while !self.done() && (self.peek() == 0x20 || self.peek() == 0x09) {
    self.bump()
  }
}

///|
fn Parser::expect(self : Parser, byte : Int) -> Unit raise @data.DeError {
  self.spaces()
  guard self.peek() == byte else {
    raise @data.DeCustom(
      path=Root,
      message="TOML: expected `\{describe(byte)}`, found `\{describe(self.peek())}`",
    )
  }
  self.bump()
}

///|
fn describe(byte : Int) -> String {
  if byte == EOF {
    "end of input"
  } else {
    match Int::to_char(byte) {
      Some(c) => c.to_string()
      None => "byte \{byte}"
    }
  }
}

///|
fn is_bare(byte : Int) -> Bool {
  (byte >= 0x41 && byte <= 0x5A) ||
  (byte >= 0x61 && byte <= 0x7A) ||
  (byte >= 0x30 && byte <= 0x39) ||
  byte == 0x5F ||
  byte == 0x2D
}

///|
/// A dotted key path: `a`, `a.b`, `"quoted".c`.
///
/// Keys are decoded, unlike values: they get compared against each other and
/// interpolated into error paths, and they are short.
fn Parser::key_path(self : Parser) -> Array[String] raise @data.DeError {
  let parts = []
  let mut more = true
  while more {
    self.spaces()
    let c = self.peek()
    if c == 0x22 || c == 0x27 { // " '
      parts.push(decode(self.quoted()))
    } else {
      let start = self.pos
      while !self.done() && is_bare(self.peek()) {
        self.bump()
      }
      if self.pos == start {
        break
      }
      parts.push(decode(self.src[start:self.pos]))
    }
    self.spaces()
    if self.peek() == 0x2E { // .
      self.bump()
    } else {
      more = false
    }
  }
  parts
}

///|
fn decode(raw : BytesView) -> String raise @data.DeError {
  @utf8.decode(raw) catch {
    _ =>
      raise @data.InvalidValue(path=Root, expected="UTF-8", found="raw bytes")
  }
}

///|
/// The contents of a quoted string.
///
/// A literal string (`'…'`) never has escapes and a basic string (`"…"`)
/// usually does not, so the common case returns a view into the input and
/// copies nothing. Only a string that actually contains a backslash is built.
fn Parser::quoted(self : Parser) -> BytesView raise @data.DeError {
  let quote = self.peek()
  self.bump()
  let start = self.pos
  let mut i = start
  let mut clean = true
  for ;; {
    guard i < self.src.length() else {
      raise @data.DeCustom(path=Root, message="TOML: unterminated string")
    }
    let b = self.src[i].to_int()
    if b == quote {
      break
    }
    if b == 0x5C && quote == 0x22 {
      clean = false
      break
    }
    i = i + 1
  }
  if clean {
    let view = self.src[start:i]
    self.pos = i + 1
    return view
  }
  let out = Buffer(size_hint=16)
  self.pos = start
  for ;; {
    guard !self.done() else {
      raise @data.DeCustom(path=Root, message="TOML: unterminated string")
    }
    let b = self.peek()
    if b == quote {
      self.bump()
      break
    }
    if b == 0x5C {
      self.bump()
      let e = self.peek()
      self.bump()
      match e {
        0x6E => out.write_byte(b'\n') // n
        0x74 => out.write_byte(b'\t') // t
        0x72 => out.write_byte(b'\r') // r
        0x22 => out.write_byte(b'"')
        0x5C => out.write_byte(b'\\')
        0x62 => out.write_byte(b'\x08') // b
        0x66 => out.write_byte(b'\x0c') // f
        0x75 => write_utf8(out, self.hex_escape(4)) // u
        0x55 => write_utf8(out, self.hex_escape(8)) // U
        other =>
          raise @data.DeCustom(
            path=Root,
            message="TOML: unknown escape `\\\{describe(other)}`",
          )
      }
    } else {
      out.write_byte(self.src[self.pos])
      self.bump()
    }
  }
  out.to_bytes()[:]
}

///|
/// The scalar value behind a `\u` or `\U` escape.
fn Parser::hex_escape(self : Parser, digits : Int) -> Int raise @data.DeError {
  let mut acc = 0
  for _ in 0..<digits {
    let c = self.peek()
    let d = if c >= 0x30 && c <= 0x39 {
      c - 0x30
    } else if c >= 0x61 && c <= 0x66 {
      c - 0x61 + 10
    } else if c >= 0x41 && c <= 0x46 {
      c - 0x41 + 10
    } else {
      raise @data.DeCustom(path=Root, message="TOML: bad `\\u` escape")
    }
    acc = acc * 16 + d
    self.bump()
  }
  guard Int::to_char(acc) is Some(_) else {
    raise @data.DeCustom(
      path=Root,
      message="TOML: `\\u` escape is not a scalar value",
    )
  }
  acc
}

///|
fn Parser::value(
  self : Parser,
  at : @data.Path,
) -> @data.Value raise @data.DeError {
  self.spaces()
  let c = self.peek()
  if c == 0x22 || c == 0x27 { // " '
    // Borrowed straight from the input: the data model holds UTF-8, so there
    // is nothing to convert.
    return @data.Str(self.quoted())
  }
  if c == 0x5B { // [
    self.bump()
    let items = []
    for ;; {
      self.trivia()
      if self.peek() == 0x5D { // ]
        self.bump()
        break
      }
      items.push(self.value(at))
      self.trivia()
      if self.peek() == 0x2C { // ,
        self.bump()
      }
    }
    return @data.Seq(ReadOnlyArray::from_array(items))
  }
  if c == 0x7B { // {
    self.bump()
    let entries = []
    for ;; {
      self.spaces()
      if self.peek() == 0x7D { // }
        self.bump()
        break
      }
      let key = self.key_path()
      guard key.length() == 1 else {
        raise @data.DeCustom(
          path=at,
          message="TOML: dotted keys inside an inline table are not supported",
        )
      }
      self.expect(0x3D) // =
      let v = self.value(at)
      entries.push((@data.Value::Str(@utf8.encode(key[0])[:]), v))
      self.spaces()
      if self.peek() == 0x2C { // ,
        self.bump()
      }
    }
    return @data.Map(ReadOnlyArray::from_array(entries))
  }
  // A bare token: boolean, number, or something TOML has that we do not. It is
  // ASCII by construction and short, so decoding it costs nothing.
  let start = self.pos
  while !self.done() &&
        self.peek() != 0x2C &&
        self.peek() != 0x5D &&
        self.peek() != 0x7D &&
        self.peek() != 0x0A &&
        self.peek() != 0x0D &&
        self.peek() != 0x23 {
    self.bump()
  }
  scalar(decode(self.src[start:self.pos]).trim().to_owned(), at)
}

///|
/// A bare token, once its extent is known.
fn scalar(text : String, at : @data.Path) -> @data.Value raise @data.DeError {
  if text == "true" {
    return @data.Boolean(true)
  }
  if text == "false" {
    return @data.Boolean(false)
  }
  if text == "inf" || text == "+inf" {
    return @data.Double(@double.infinity)
  }
  if text == "-inf" {
    return @data.Double(@double.neg_infinity)
  }
  if text == "nan" || text == "+nan" || text == "-nan" {
    return @data.Double(@double.not_a_number)
  }
  guard text.length() > 0 else {
    raise @data.DeCustom(path=at, message="TOML: expected a value")
  }
  // A datetime has no counterpart in the data model, and turning one into a
  // string would round-trip into something that is no longer a datetime.
  if looks_like_datetime(text) {
    raise @data.DeCustom(
      path=at,
      message="TOML: datetimes are not part of the data model",
    )
  }
  let cleaned = strip_underscores(text)
  if is_float(cleaned) {
    @data.Double(
      @string.parse_double(cleaned) catch {
        _ => raise @data.InvalidValue(path=at, expected="a float", found=text)
      },
    )
  } else {
    @data.Int(
      @string.parse_int64(cleaned) catch {
        _ =>
          raise @data.InvalidValue(path=at, expected="an integer", found=text)
      },
    )
  }
}

///|
fn strip_underscores(text : String) -> String {
  let out = StringBuilder::new()
  for c in text {
    if c != '_' {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn is_float(text : String) -> Bool {
  text.to_array().iter().any(c => c == '.' || c == 'e' || c == 'E')
}

///|
/// `1979-05-27` and `07:32:00` shapes, enough to tell a date from a number.
fn looks_like_datetime(text : String) -> Bool {
  let chars = text.to_array()
  if chars.length() >= 10 &&
    chars[4] == '-' &&
    chars[7] == '-' &&
    is_digit(chars[0]) {
    return true
  }
  chars.length() >= 5 && chars[2] == ':' && is_digit(chars[0])
}

///|
fn is_digit(c : Char) -> Bool {
  let v = c.to_int()
  v >= 0x30 && v <= 0x39
}

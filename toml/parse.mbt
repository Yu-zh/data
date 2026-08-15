// TOML text to `Value`.
//
// Built through a mutable tree rather than straight into `Value`, because a
// `[a.b.c]` header has to reach into a table that may not exist yet and
// `Value::Map` holds immutable pairs. The tree is converted once at the end.
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
    let key = @data.Value::Str(str_bytes(entry.0))
    entries.push((key, node_to_value(entry.1)))
  }
  @data.Map(entries)
}

///|
fn node_to_value(node : Node) -> @data.Value {
  match node {
    Leaf(v) => v
    Sub(t) => t.to_value()
    Arr(tables) => @data.Seq(tables.map(t => t.to_value()))
  }
}

///|
/// A `String` as the UTF-8 bytes `Value::Str` holds.
fn str_bytes(text : String) -> BytesView {
  let out = Array::new(capacity=text.length())
  for c in text {
    let v = c.to_int()
    if v < 0x80 {
      out.push(v.to_byte())
    } else if v < 0x800 {
      out.push((0xC0 | (v >> 6)).to_byte())
      out.push((0x80 | (v & 0x3F)).to_byte())
    } else if v < 0x10000 {
      out.push((0xE0 | (v >> 12)).to_byte())
      out.push((0x80 | ((v >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (v & 0x3F)).to_byte())
    } else {
      out.push((0xF0 | (v >> 18)).to_byte())
      out.push((0x80 | ((v >> 12) & 0x3F)).to_byte())
      out.push((0x80 | ((v >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (v & 0x3F)).to_byte())
    }
  }
  Bytes::from_array(out[:])[:]
}

// ---- the parser ----

///|
priv struct Parser {
  src : Array[Char]
  mut pos : Int
}

///|
fn parse(text : String) -> @data.Value raise @data.DeError {
  let p = Parser::{ src: text.to_array(), pos: 0 }
  let root = Table::new()
  let mut current = root
  let mut prefix : Array[String] = []
  for ;; {
    p.trivia()
    if p.done() {
      break
    }
    if p.peek() == '[' {
      p.bump()
      let array_of = p.peek() == '['
      if array_of {
        p.bump()
      }
      let path = p.key_path()
      p.expect(']')
      if array_of {
        p.expect(']')
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
    p.expect('=')
    let at = @data.Root.key(path_prefix(prefix + path, prefix.length() + path.length() - 1))
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
fn Parser::peek(self : Parser) -> Char {
  if self.done() {
    '\u{0}'
  } else {
    self.src[self.pos]
  }
}

///|
fn Parser::bump(self : Parser) -> Unit {
  self.pos = self.pos + 1
}

///|
/// Whitespace, newlines and comments — everything between two meaningful
/// tokens.
fn Parser::trivia(self : Parser) -> Unit {
  while !self.done() {
    let c = self.peek()
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      self.bump()
    } else if c == '#' {
      while !self.done() && self.peek() != '\n' {
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
  while !self.done() && (self.peek() == ' ' || self.peek() == '\t') {
    self.bump()
  }
}

///|
fn Parser::expect(self : Parser, c : Char) -> Unit raise @data.DeError {
  self.spaces()
  guard self.peek() == c else {
    raise @data.DeCustom(
      path=Root,
      message="TOML: expected `\{c}`, found `\{self.peek()}`",
    )
  }
  self.bump()
}

///|
/// A dotted key path: `a`, `a.b`, `"quoted".c`.
fn Parser::key_path(self : Parser) -> Array[String] raise @data.DeError {
  let parts = []
  let mut more = true
  while more {
    self.spaces()
    let c = self.peek()
    if c == '"' || c == '\'' {
      parts.push(self.string_literal())
    } else {
      let start = self.pos
      while !self.done() && is_bare(self.peek()) {
        self.bump()
      }
      if self.pos == start {
        break
      }
      let text = StringBuilder::new()
      for i in start..<self.pos {
        text.write_char(self.src[i])
      }
      parts.push(text.to_string())
    }
    self.spaces()
    if self.peek() == '.' {
      self.bump()
    } else {
      more = false
    }
  }
  parts
}

///|
fn is_bare(c : Char) -> Bool {
  let v = c.to_int()
  (v >= 0x41 && v <= 0x5A) ||
  (v >= 0x61 && v <= 0x7A) ||
  (v >= 0x30 && v <= 0x39) ||
  v == 0x5F ||
  v == 0x2D
}

///|
fn Parser::string_literal(self : Parser) -> String raise @data.DeError {
  let quote_char = self.peek()
  self.bump()
  let out = StringBuilder::new()
  while true {
    guard !self.done() else {
      raise @data.DeCustom(path=Root, message="TOML: unterminated string")
    }
    let c = self.peek()
    if c == quote_char {
      self.bump()
      break
    }
    if c == '\\' && quote_char == '"' {
      self.bump()
      let e = self.peek()
      self.bump()
      match e {
        'n' => out.write_char('\n')
        't' => out.write_char('\t')
        'r' => out.write_char('\r')
        '"' => out.write_char('"')
        '\\' => out.write_char('\\')
        'b' => out.write_char('\u{8}')
        'f' => out.write_char('\u{c}')
        'u' => out.write_char(self.hex_escape(4))
        'U' => out.write_char(self.hex_escape(8))
        other =>
          raise @data.DeCustom(
            path=Root,
            message="TOML: unknown escape `\\\{other}`",
          )
      }
    } else {
      out.write_char(c)
      self.bump()
    }
  }
  out.to_string()
}

///|
fn Parser::hex_escape(self : Parser, digits : Int) -> Char raise @data.DeError {
  let mut acc = 0
  for _ in 0..<digits {
    let c = self.peek().to_int()
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
  match Int::to_char(acc) {
    Some(c) => c
    None =>
      raise @data.DeCustom(
        path=Root,
        message="TOML: `\\u` escape is not a scalar value",
      )
  }
}

///|
fn Parser::value(
  self : Parser,
  at : @data.Path,
) -> @data.Value raise @data.DeError {
  self.spaces()
  let c = self.peek()
  if c == '"' || c == '\'' {
    return @data.Str(str_bytes(self.string_literal()))
  }
  if c == '[' {
    self.bump()
    let items = []
    for ;; {
      self.trivia()
      if self.peek() == ']' {
        self.bump()
        break
      }
      items.push(self.value(at))
      self.trivia()
      if self.peek() == ',' {
        self.bump()
      }
    }
    return @data.Seq(items)
  }
  if c == '{' {
    self.bump()
    let entries = []
    for ;; {
      self.spaces()
      if self.peek() == '}' {
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
      self.expect('=')
      let v = self.value(at)
      entries.push((@data.Value::Str(str_bytes(key[0])), v))
      self.spaces()
      if self.peek() == ',' {
        self.bump()
      }
    }
    return @data.Map(entries)
  }
  // A bare token: boolean, number, or something TOML has that we do not.
  let start = self.pos
  while
    !self.done() &&
    self.peek() != ',' &&
    self.peek() != ']' &&
    self.peek() != '}' &&
    self.peek() != '\n' &&
    self.peek() != '\r' &&
    self.peek() != '#' {
    self.bump()
  }
  let text = StringBuilder::new()
  for i in start..<self.pos {
    text.write_char(self.src[i])
  }
  scalar(text.to_string().trim().to_owned(), at)
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
        _ => raise @data.InvalidValue(path=at, expected="an integer", found=text)
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

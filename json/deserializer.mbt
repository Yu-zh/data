///|
/// One open `[` or `{`, remembering the path to restore on the way out and how
/// many items have been read so far (which is what decides whether the next
/// item needs a leading comma).
priv struct Scope {
  base : @data.Path
  mut count : Int
}

///|
/// One open enum. `wrapped` records whether it was written as
/// `{"Variant": payload}`, which has a `}` to consume, or as a bare
/// `"Variant"` string, which does not.
priv struct EnumScope {
  wrapped : Bool
  base : @data.Path
}

///|
/// Reads JSON from UTF-8 bytes.
///
/// A streaming parser, so lengths are never known in advance and
/// `deserialize_seq_begin` returns `None`. Iteration is driven by the type
/// being built, exactly as serde intends: the parser never decides what shape
/// the input has until asked.
struct JsonDeserializer {
  input : Bytes
  mut pos : Int
  mut path : @data.Path
  scopes : Array[Scope]
  enums : Array[EnumScope]
  /// Set on the throwaway deserializer used to read an object key: the
  /// already-decoded, already-unescaped key text. JSON keys are always
  /// strings, but the key *type* may be a number, so the token has to be
  /// re-read through whatever `Deserialize` the map's key type provides.
  /// Holding the text avoids re-encoding it just to parse it again.
  bare : String?
}

///|
pub fn JsonDeserializer::new(input : Bytes) -> JsonDeserializer {
  { input, pos: 0, path: @data.Root, scopes: [], enums: [], bare: None }
}

///|
/// Checks that the whole input was consumed.
pub fn JsonDeserializer::finish(
  self : JsonDeserializer,
) -> Unit raise @data.DeError {
  self.skip_ws()
  if self.pos < self.input.length() {
    raise @data.DeCustom(path=self.path, message="trailing input after value")
  }
}

///|
fn JsonDeserializer::key_reader(
  self : JsonDeserializer,
  text : String,
) -> JsonDeserializer {
  {
    input: b"",
    pos: 0,
    path: self.path,
    scopes: [],
    enums: [],
    bare: Some(text),
  }
}

// ---- scanning ----

///|
/// The byte at `i`, widened for comparison against the ASCII structural
/// characters JSON is made of. Multi-byte UTF-8 sequences only ever appear
/// inside string literals, where `decode_chunk` handles them.
fn JsonDeserializer::code(self : JsonDeserializer, i : Int) -> Int {
  self.input[i].to_int()
}

///|
/// Decodes a byte range that came from inside a string literal or a number.
fn JsonDeserializer::decode_chunk(
  self : JsonDeserializer,
  start : Int,
  end : Int,
) -> String raise @data.DeError {
  @utf8.decode(self.input[start:end]) catch {
    _ =>
      raise @data.DeCustom(path=self.path, message="input is not valid UTF-8")
  }
}

///|
fn JsonDeserializer::at_end(self : JsonDeserializer) -> Bool {
  self.pos >= self.input.length()
}

///|
fn JsonDeserializer::skip_ws(self : JsonDeserializer) -> Unit {
  while self.pos < self.input.length() {
    let c = self.code(self.pos)
    if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      self.pos = self.pos + 1
    } else {
      break
    }
  }
}

///|
fn JsonDeserializer::peek(self : JsonDeserializer) -> Int raise @data.DeError {
  self.skip_ws()
  if self.at_end() {
    raise @data.Eof(path=self.path)
  }
  self.code(self.pos)
}

///|
fn describe(c : Int) -> String {
  match Int::to_char(c) {
    Some(ch) => ch.to_string()
    None => "U+" + c.to_string(radix=16)
  }
}

///|
/// Names the shape of whatever is at the cursor, in the same vocabulary
/// `Value::type_name` uses, so `InvalidType` messages read the same whichever
/// format produced them.
fn JsonDeserializer::found(self : JsonDeserializer) -> String {
  self.skip_ws()
  if self.at_end() {
    return "end of input"
  }
  match self.code(self.pos) {
    0x22 => "string"
    0x7B => "map"
    0x5B => "sequence"
    0x74 | 0x66 => "boolean"
    0x6E => "unit"
    0x5D => "end of sequence"
    0x7D => "end of map"
    _ => "a number"
  }
}

///|
fn JsonDeserializer::expect(
  self : JsonDeserializer,
  ch : Char,
) -> Unit raise @data.DeError {
  let c = self.peek()
  guard c == ch.to_int() else {
    raise @data.DeCustom(
      path=self.path,
      message="expected `\{ch}`, found `\{describe(c)}`",
    )
  }
  self.pos = self.pos + 1
}

///|
fn JsonDeserializer::eat(self : JsonDeserializer, literal : String) -> Bool {
  self.skip_ws()
  if self.pos + literal.length() > self.input.length() {
    return false
  }
  for i in 0..<literal.length() {
    if self.code(self.pos + i) != literal[i].to_int() {
      return false
    }
  }
  self.pos = self.pos + literal.length()
  true
}

///|
/// A token that begins like `true` / `false` / `null` but does not finish that
/// way is a malformed literal, not a value of some other type. Saying so beats
/// "expected unit, found unit".
fn[T] JsonDeserializer::bad_literal(
  self : JsonDeserializer,
  expected : String,
) -> T raise @data.DeError {
  raise @data.DeCustom(
    path=self.path,
    message="invalid literal, expected `\{expected}`",
  )
}

///|
fn[T] JsonDeserializer::mismatch(
  self : JsonDeserializer,
  expected : String,
) -> T raise @data.DeError {
  raise @data.InvalidType(path=self.path, expected~, found=self.found())
}

// ---- strings ----

///|
fn JsonDeserializer::hex4(self : JsonDeserializer) -> Int raise @data.DeError {
  if self.pos + 4 > self.input.length() {
    raise @data.Eof(path=self.path)
  }
  let mut value = 0
  for i in 0..<4 {
    let c = self.code(self.pos + i)
    let digit = if c >= 0x30 && c <= 0x39 {
      c - 0x30
    } else if c >= 0x61 && c <= 0x66 {
      c - 0x61 + 10
    } else if c >= 0x41 && c <= 0x46 {
      c - 0x41 + 10
    } else {
      raise @data.DeCustom(
        path=self.path,
        message="invalid `\\u` escape: `\{describe(c)}` is not a hex digit",
      )
    }
    value = value * 16 + digit
  }
  self.pos = self.pos + 4
  value
}

///|
/// Consumes a literal `\u` without skipping whitespace, for the second half of
/// a surrogate pair where nothing may intervene.
fn JsonDeserializer::eat_u_escape(self : JsonDeserializer) -> Bool {
  if self.pos + 1 >= self.input.length() {
    return false
  }
  if self.code(self.pos) != 0x5C || self.code(self.pos + 1) != 0x75 {
    return false
  }
  self.pos = self.pos + 2
  true
}

///|
fn JsonDeserializer::decode_escape(
  self : JsonDeserializer,
  out : StringBuilder,
) -> Unit raise @data.DeError {
  if self.at_end() {
    raise @data.Eof(path=self.path)
  }
  let e = self.code(self.pos)
  self.pos = self.pos + 1
  match e {
    0x22 => out.write_char('"')
    0x5C => out.write_char('\\')
    0x2F => out.write_char('/')
    0x62 => out.write_char(Int::unsafe_to_char(0x08))
    0x66 => out.write_char(Int::unsafe_to_char(0x0C))
    0x6E => out.write_char('\n')
    0x72 => out.write_char('\r')
    0x74 => out.write_char('\t')
    0x75 => {
      let hi = self.hex4()
      if hi >= 0xD800 && hi <= 0xDBFF {
        guard self.eat_u_escape() else {
          raise @data.DeCustom(
            path=self.path,
            message="high surrogate escape is not followed by a low surrogate",
          )
        }
        let lo = self.hex4()
        guard lo >= 0xDC00 && lo <= 0xDFFF else {
          raise @data.DeCustom(
            path=self.path,
            message="high surrogate escape is not followed by a low surrogate",
          )
        }
        out.write_char(
          Int::unsafe_to_char(0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)),
        )
      } else if hi >= 0xDC00 && hi <= 0xDFFF {
        raise @data.DeCustom(
          path=self.path,
          message="unpaired low surrogate escape",
        )
      } else {
        out.write_char(Int::unsafe_to_char(hi))
      }
    }
    _ =>
      raise @data.DeCustom(
        path=self.path,
        message="unknown escape `\\\{describe(e)}`",
      )
  }
}

///|
fn JsonDeserializer::parse_string(
  self : JsonDeserializer,
) -> String raise @data.DeError {
  guard self.peek() == 0x22 else { self.mismatch("string") }
  self.pos = self.pos + 1
  let out = StringBuilder::new()
  let mut chunk = self.pos
  while true {
    if self.at_end() {
      raise @data.Eof(path=self.path)
    }
    let c = self.code(self.pos)
    if c == 0x22 {
      out.write_string(self.decode_chunk(chunk, self.pos))
      self.pos = self.pos + 1
      break
    } else if c == 0x5C {
      out.write_string(self.decode_chunk(chunk, self.pos))
      self.pos = self.pos + 1
      self.decode_escape(out)
      chunk = self.pos
    } else if c < 0x20 {
      raise @data.DeCustom(
        path=self.path,
        message="unescaped control character in string",
      )
    } else {
      self.pos = self.pos + 1
    }
  }
  out.to_string()
}

// ---- numbers ----

///|
fn JsonDeserializer::number_text(
  self : JsonDeserializer,
) -> String raise @data.DeError {
  if self.bare is Some(text) {
    return text
  }
  self.skip_ws()
  let start = self.pos
  if !self.at_end() && self.code(self.pos) == 0x2D {
    self.pos = self.pos + 1
  }
  while !self.at_end() {
    let c = self.code(self.pos)
    if (c >= 0x30 && c <= 0x39) ||
      c == 0x2E ||
      c == 0x65 ||
      c == 0x45 ||
      c == 0x2B ||
      c == 0x2D {
      self.pos = self.pos + 1
    } else {
      break
    }
  }
  if self.pos == start {
    self.mismatch("a number")
  }
  self.decode_chunk(start, self.pos)
}

///|
fn is_fractional(text : String) -> Bool {
  for c in text {
    if c == '.' || c == 'e' || c == 'E' {
      return true
    }
  }
  false
}

///|
fn JsonDeserializer::read_int64(
  self : JsonDeserializer,
) -> Int64 raise @data.DeError {
  let text = self.number_text()
  @string.parse_int64(text) catch {
    _ =>
      raise @data.InvalidValue(
        path=self.path,
        expected="an integer",
        found=text,
      )
  }
}

///|
fn JsonDeserializer::read_double(
  self : JsonDeserializer,
) -> Double raise @data.DeError {
  let text = self.number_text()
  @string.parse_double(text) catch {
    _ =>
      raise @data.InvalidValue(path=self.path, expected="a number", found=text)
  }
}

///|
fn JsonDeserializer::int_in_range(
  self : JsonDeserializer,
  lo : Int64,
  hi : Int64,
  what : String,
) -> Int64 raise @data.DeError {
  let value = self.read_int64()
  if value < lo || value > hi {
    raise @data.InvalidValue(
      path=self.path,
      expected=what,
      found=value.to_string(),
    )
  }
  value
}

// ---- scopes ----

///|
fn JsonDeserializer::push_scope(self : JsonDeserializer) -> Unit {
  self.scopes.push({ base: self.path, count: 0 })
}

///|
fn JsonDeserializer::top_scope(
  self : JsonDeserializer,
) -> Scope raise @data.DeError {
  guard self.scopes.length() > 0 else {
    raise @data.DeCustom(
      path=self.path,
      message="JSON: container read without a begin",
    )
  }
  self.scopes[self.scopes.length() - 1]
}

///|
fn JsonDeserializer::pop_scope(
  self : JsonDeserializer,
) -> Unit raise @data.DeError {
  guard self.scopes.pop() is Some(scope) else {
    raise @data.DeCustom(
      path=self.path,
      message="JSON: container ended without a begin",
    )
  }
  self.path = scope.base
}

///|
/// Advances to the next item of an open container, or closes it.
///
/// Returns `false` when the closing delimiter was consumed and the scope
/// popped, `true` when a further item follows and the path has been set to it.
fn JsonDeserializer::next_item(
  self : JsonDeserializer,
  closing : Int,
) -> Bool raise @data.DeError {
  let scope = self.top_scope()
  if self.peek() == closing {
    self.pos = self.pos + 1
    self.pop_scope()
    return false
  }
  if scope.count > 0 {
    self.expect(',')
  }
  true
}

// ---- the untyped fallback ----

///|
fn JsonDeserializer::parse_any(
  self : JsonDeserializer,
) -> @data.Value raise @data.DeError {
  if self.bare is Some(text) {
    return Str(text)
  }
  match self.peek() {
    0x7B => {
      self.pos = self.pos + 1
      let entries = []
      while self.peek() != 0x7D {
        if entries.length() > 0 {
          self.expect(',')
        }
        let key = self.parse_string()
        self.expect(':')
        entries.push((@data.Str(key), self.parse_any()))
      }
      self.pos = self.pos + 1
      Map(entries)
    }
    0x5B => {
      self.pos = self.pos + 1
      let items = []
      while self.peek() != 0x5D {
        if items.length() > 0 {
          self.expect(',')
        }
        items.push(self.parse_any())
      }
      self.pos = self.pos + 1
      Seq(items)
    }
    0x22 => Str(self.parse_string())
    0x74 => {
      guard self.eat("true") else { self.bad_literal("true") }
      Boolean(true)
    }
    0x66 => {
      guard self.eat("false") else { self.bad_literal("false") }
      Boolean(false)
    }
    0x6E => {
      guard self.eat("null") else { self.bad_literal("null") }
      Null
    }
    _ => {
      let text = self.number_text()
      if is_fractional(text) {
        Double(
          @string.parse_double(text) catch {
            _ =>
              raise @data.InvalidValue(
                path=self.path,
                expected="a number",
                found=text,
              )
          },
        )
      } else {
        Int(
          // Prefer the narrowest representation that holds the digits, then fall
          // back to a float the way most JSON readers do.
          @string.parse_int64(text),
        ) catch {
          _ =>
            UInt(@string.parse_uint64(text)) catch {
              _ =>
                Double(
                  @string.parse_double(text) catch {
                    _ =>
                      raise @data.InvalidValue(
                        path=self.path,
                        expected="a number",
                        found=text,
                      )
                  },
                )
            }
        }
      }
    }
  }
}

// ---- Deserializer ----

///|
pub impl @data.Deserializer for JsonDeserializer with fn path(self) {
  self.path
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_unit(self) {
  if self.eat("null") {
    return
  }
  if self.peek() == 0x6E {
    self.bad_literal("null")
  }
  self.mismatch("unit")
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_bool(self) {
  if self.eat("true") {
    true
  } else if self.eat("false") {
    false
  } else if self.peek() == 0x74 || self.peek() == 0x66 {
    self.bad_literal("true` or `false")
  } else {
    self.mismatch("boolean")
  }
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_byte(self) {
  self.int_in_range(0L, 255L, "a byte").to_byte()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_int16(self) {
  Int16::from_int64(self.int_in_range(-32768L, 32767L, "an int16"))
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_uint16(
  self,
) {
  self.int_in_range(0L, 65535L, "a uint16").to_uint16()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_int(self) {
  self.int_in_range(-2147483648L, 2147483647L, "an int").to_int()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_uint(self) {
  self.int_in_range(0L, 4294967295L, "a uint").reinterpret_as_uint64().to_uint()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_int64(self) {
  self.read_int64()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_uint64(
  self,
) {
  let text = self.number_text()
  @string.parse_uint64(text) catch {
    _ =>
      raise @data.InvalidValue(
        path=self.path,
        expected="an unsigned integer",
        found=text,
      )
  }
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_float(self) {
  Float::from_double(self.read_double())
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_double(
  self,
) {
  self.read_double()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_char(self) {
  let text = self.deserialize_string()
  if text.char_length() != 1 {
    raise @data.InvalidValue(
      path=self.path,
      expected="a single character",
      found=text,
    )
  }
  text.to_array()[0]
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_string(
  self,
) {
  if self.bare is Some(text) {
    text
  } else {
    self.parse_string()
  }
}

///|
/// The mirror of writing bytes as an array of numbers.
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_bytes(self) {
  guard self.peek() == 0x5B else { self.mismatch("byte string") }
  self.pos = self.pos + 1
  let out = []
  while self.peek() != 0x5D {
    if out.length() > 0 {
      self.expect(',')
    }
    out.push(self.int_in_range(0L, 255L, "a byte").to_byte())
  }
  self.pos = self.pos + 1
  Bytes::from_array(out)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_option(
  self,
) {
  if self.eat("null") {
    None
  } else {
    Some(@data.Deserialize::deserialize(self))
  }
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_seq_begin(
  self,
) {
  self.expect('[')
  self.push_scope()
  // A streaming parser cannot know the length without scanning ahead.
  None
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_seq_next(
  self,
) {
  guard self.next_item(0x5D) else { return None }
  let scope = self.top_scope()
  self.path = scope.base.index(scope.count)
  scope.count = scope.count + 1
  Some(@data.Deserialize::deserialize(self))
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_map_begin(
  self,
) {
  self.expect('{')
  self.push_scope()
  None
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_map_next_key(
  self,
) {
  guard self.next_item(0x7D) else { return None }
  let scope = self.top_scope()
  let text = self.parse_string()
  self.expect(':')
  self.path = scope.base.key(text)
  scope.count = scope.count + 1
  Some(@data.Deserialize::deserialize(self.key_reader(text)))
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_map_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_struct_begin(
  self,
  _name,
  _fields,
) {
  self.expect('{')
  self.push_scope()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_field_name(
  self,
) {
  guard self.next_item(0x7D) else { return None }
  let scope = self.top_scope()
  let name = self.parse_string()
  self.expect(':')
  self.path = scope.base.key(name)
  scope.count = scope.count + 1
  Some(name)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_field_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn skip_value(self) {
  let _ = self.parse_any()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_enum_begin(
  self,
  _name,
  variants,
) {
  let base = self.path
  let wrapped = self.peek() == 0x7B
  if wrapped {
    self.pos = self.pos + 1
  }
  let variant = self.parse_string()
  guard variants.is_empty() || variants.contains(variant) else {
    raise @data.UnknownVariant(path=base, variant~, expected=variants)
  }
  if wrapped {
    self.expect(':')
  }
  self.enums.push({ wrapped, base })
  self.path = base.key(variant)
  variant
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_unit_variant(
  self,
) {
  ignore(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_newtype_variant(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_enum_end(
  self,
) {
  guard self.enums.pop() is Some(scope) else {
    raise @data.DeCustom(
      path=self.path,
      message="JSON: enum ended without a begin",
    )
  }
  if scope.wrapped {
    self.expect('}')
  }
  self.path = scope.base
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_any(self) {
  self.parse_any()
}

///|
/// Tuples get their own handling rather than riding on the sequence protocol,
/// because a JSON array has a closing `]` that something has to consume and
/// `deserialize_tuple_next` — reading a known number of elements — never sees
/// the end of the array.
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_tuple_begin(
  self,
  _len,
) {
  self.expect('[')
  self.push_scope()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_tuple_next(
  self,
) {
  let scope = self.top_scope()
  if self.peek() == 0x5D {
    raise @data.Eof(path=self.path)
  }
  if scope.count > 0 {
    self.expect(',')
  }
  self.path = scope.base.index(scope.count)
  scope.count = scope.count + 1
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_tuple_end(
  self,
) {
  self.expect(']')
  self.pop_scope()
}

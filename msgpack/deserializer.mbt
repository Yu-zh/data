// The MessagePack decoder.
//
// Every marker carries its own length, so unlike CBOR there is no break byte
// and no indefinite form to accept — the decoder reads exactly the shapes the
// encoder writes, plus the wider integer and string forms a different encoder
// might have chosen for the same value.

///|
/// One open array, map or struct.
priv struct Scope {
  base : @data.Path
  mut remaining : Int
  mut count : Int
  /// The field names the caller declared, empty for arrays and maps. Matching
  /// against these hands back the caller's own `String` rather than a new one.
  expected : Array[String]
}

///|
priv struct EnumScope {
  base : @data.Path
}

///|
/// Reads MessagePack from bytes.
struct MsgpackDeserializer {
  input : Bytes
  mut pos : Int
  mut path : @data.Path
  scopes : Array[Scope]
  enums : Array[EnumScope]
}

///|
pub fn MsgpackDeserializer::new(input : Bytes) -> MsgpackDeserializer {
  { input, pos: 0, path: @data.Root, scopes: [], enums: [] }
}

///|
/// Checks that the whole input was consumed.
pub fn MsgpackDeserializer::finish(
  self : MsgpackDeserializer,
) -> Unit raise @data.DeError {
  if self.pos < self.input.length() {
    raise @data.DeCustom(path=self.path, message="trailing input after value")
  }
}

// ---- primitives of the reader ----

///|
fn MsgpackDeserializer::marker(
  self : MsgpackDeserializer,
) -> Int raise @data.DeError {
  if self.pos >= self.input.length() {
    raise @data.Eof(path=self.path)
  }
  let b = self.input[self.pos].to_int()
  self.pos = self.pos + 1
  b
}

///|
fn MsgpackDeserializer::peek(
  self : MsgpackDeserializer,
) -> Int raise @data.DeError {
  if self.pos >= self.input.length() {
    raise @data.Eof(path=self.path)
  }
  self.input[self.pos].to_int()
}

///|
fn MsgpackDeserializer::be(
  self : MsgpackDeserializer,
  count : Int,
) -> UInt64 raise @data.DeError {
  let mut acc = 0UL
  for _ in 0..<count {
    acc = (acc << 8) | self.marker().to_uint64()
  }
  acc
}

///|
/// A count read from the input, checked against what is left of it.
fn MsgpackDeserializer::bounded(
  self : MsgpackDeserializer,
  n : UInt64,
) -> Int raise @data.DeError {
  let left = (self.input.length() - self.pos).to_int64().reinterpret_as_uint64()
  guard n <= left else {
    raise @data.DeCustom(
      path=self.path,
      message="MessagePack: length \{n} exceeds the \{left} byte(s) remaining",
    )
  }
  n.to_uint().reinterpret_as_int()
}

///|
fn MsgpackDeserializer::take(
  self : MsgpackDeserializer,
  n : Int,
) -> BytesView {
  let view = self.input[self.pos:self.pos + n]
  self.pos = self.pos + n
  view
}

///|
fn kind_name(marker : Int) -> String {
  if marker < 0x80 || marker >= 0xe0 {
    "integer"
  } else if marker < 0x90 {
    "map"
  } else if marker < 0xa0 {
    "sequence"
  } else if marker < 0xc0 {
    "string"
  } else {
    match marker {
      0xc0 => "unit"
      0xc2 | 0xc3 => "boolean"
      0xc4 | 0xc5 | 0xc6 => "bytes"
      0xca | 0xcb => "a float"
      0xcc | 0xcd | 0xce | 0xcf | 0xd0 | 0xd1 | 0xd2 | 0xd3 => "integer"
      0xd9 | 0xda | 0xdb => "string"
      0xdc | 0xdd => "sequence"
      0xde | 0xdf => "map"
      _ => "an extension"
    }
  }
}

///|
fn[T] MsgpackDeserializer::mismatch(
  self : MsgpackDeserializer,
  expected : String,
  marker : Int,
) -> T raise @data.DeError {
  raise @data.InvalidType(
    path=self.path,
    expected~,
    found=kind_name(marker),
  )
}

// ---- integers ----

///|
fn MsgpackDeserializer::as_int64(
  self : MsgpackDeserializer,
) -> Int64 raise @data.DeError {
  let m = self.marker()
  if m < 0x80 {
    m.to_int64()
  } else if m >= 0xe0 {
    (m - 256).to_int64()
  } else {
    match m {
      0xcc => self.be(1).reinterpret_as_int64()
      0xcd => self.be(2).reinterpret_as_int64()
      0xce => self.be(4).reinterpret_as_int64()
      0xcf => {
        let v = self.be(8)
        guard v <= 0x7FFFFFFFFFFFFFFF else {
          raise @data.InvalidValue(
            path=self.path,
            expected="a signed integer",
            found=v.to_string(),
          )
        }
        v.reinterpret_as_int64()
      }
      0xd0 => sign_extend(self.be(1), 8)
      0xd1 => sign_extend(self.be(2), 16)
      0xd2 => sign_extend(self.be(4), 32)
      0xd3 => self.be(8).reinterpret_as_int64()
      _ => self.mismatch("integer", m)
    }
  }
}

///|
/// The low `bits` of `raw`, read as a two's-complement signed value.
fn sign_extend(raw : UInt64, bits : Int) -> Int64 {
  let shift = 64 - bits
  (raw << shift).reinterpret_as_int64() >> shift
}

///|
fn MsgpackDeserializer::int_in_range(
  self : MsgpackDeserializer,
  low : Int64,
  high : Int64,
  what : String,
) -> Int64 raise @data.DeError {
  let v = self.as_int64()
  guard v >= low && v <= high else {
    raise @data.InvalidValue(path=self.path, expected=what, found=v.to_string())
  }
  v
}

///|
fn MsgpackDeserializer::as_uint64(
  self : MsgpackDeserializer,
) -> UInt64 raise @data.DeError {
  let m = self.peek()
  if m == 0xcf {
    let _ = self.marker()
    self.be(8)
  } else {
    let v = self.as_int64()
    guard v >= 0 else {
      raise @data.InvalidValue(
        path=self.path,
        expected="an unsigned integer",
        found=v.to_string(),
      )
    }
    v.reinterpret_as_uint64()
  }
}

///|
fn MsgpackDeserializer::as_double(
  self : MsgpackDeserializer,
) -> Double raise @data.DeError {
  let m = self.peek()
  match m {
    0xca => {
      let _ = self.marker()
      Float::reinterpret_from_uint(self.be(4).to_uint()).to_double()
    }
    0xcb => {
      let _ = self.marker()
      self.be(8).reinterpret_as_double()
    }
    // An encoder that shortened a whole number to an integer still decodes
    // into a field asking for a double, which is what the asker wants.
    _ => self.as_int64().to_double()
  }
}

// ---- strings, byte strings, containers ----

///|
/// The length of a string header, whichever of the four forms it took.
fn MsgpackDeserializer::text_len(
  self : MsgpackDeserializer,
) -> Int raise @data.DeError {
  let m = self.marker()
  if m >= 0xa0 && m < 0xc0 {
    m & 0x1F
  } else {
    match m {
      0xd9 => self.bounded(self.be(1))
      0xda => self.bounded(self.be(2))
      0xdb => self.bounded(self.be(4))
      _ => self.mismatch("string", m)
    }
  }
}

///|
fn MsgpackDeserializer::str_bytes(
  self : MsgpackDeserializer,
) -> BytesView raise @data.DeError {
  let n = self.text_len()
  let _ = self.bounded(n.to_int64().reinterpret_as_uint64())
  self.take(n)
}

///|
fn MsgpackDeserializer::text(
  self : MsgpackDeserializer,
) -> String raise @data.DeError {
  let view = self.str_bytes()
  @utf8.decode(view) catch {
    _ =>
      raise @data.InvalidValue(
        path=self.path,
        expected="UTF-8",
        found="raw bytes",
      )
  }
}

///|
fn MsgpackDeserializer::bin(
  self : MsgpackDeserializer,
) -> BytesView raise @data.DeError {
  let m = self.marker()
  let n = match m {
    0xc4 => self.bounded(self.be(1))
    0xc5 => self.bounded(self.be(2))
    0xc6 => self.bounded(self.be(4))
    _ => self.mismatch("bytes", m)
  }
  self.take(n)
}

///|
/// The element count of an array or map header.
fn MsgpackDeserializer::open(
  self : MsgpackDeserializer,
  fix : Int,
  m16 : Int,
  m32 : Int,
  what : String,
  expected : Array[String],
) -> Int raise @data.DeError {
  let m = self.marker()
  let n = if m >= fix && m < fix + 16 {
    m & 0x0F
  } else if m == m16 {
    self.be(2).to_uint().reinterpret_as_int()
  } else if m == m32 {
    self.be(4).to_uint().reinterpret_as_int()
  } else {
    self.mismatch(what, m)
  }
  self.scopes.push({ base: self.path, remaining: n, count: 0, expected })
  n
}

///|
fn MsgpackDeserializer::top(
  self : MsgpackDeserializer,
) -> Scope raise @data.DeError {
  match self.scopes.last() {
    Some(scope) => scope
    None =>
      raise @data.DeCustom(
        path=self.path,
        message="MessagePack: item outside a container",
      )
  }
}

///|
fn MsgpackDeserializer::next_item(
  self : MsgpackDeserializer,
) -> Bool raise @data.DeError {
  let scope = self.top()
  if scope.remaining == 0 {
    let _ = self.scopes.pop()
    self.path = scope.base
    false
  } else {
    scope.remaining = scope.remaining - 1
    true
  }
}

// ---- the trait ----

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn path(self) {
  self.path
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_unit(
  self,
) {
  let m = self.marker()
  guard m == 0xc0 else { self.mismatch("unit", m) }
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_bool(
  self,
) {
  match self.marker() {
    0xc2 => false
    0xc3 => true
    other => self.mismatch("boolean", other)
  }
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_byte(
  self,
) {
  self.int_in_range(0, 255, "a byte").to_byte()
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_int16(
  self,
) {
  Int16::from_int64(self.int_in_range(-32768, 32767, "an int16"))
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_uint16(
  self,
) {
  self.int_in_range(0, 65535, "a uint16").to_uint16()
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_int(
  self,
) {
  self.int_in_range(-2147483648, 2147483647, "an int").to_int()
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_uint(
  self,
) {
  self.int_in_range(0, 4294967295, "a uint").reinterpret_as_uint64().to_uint()
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_int64(
  self,
) {
  self.as_int64()
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_uint64(
  self,
) {
  self.as_uint64()
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_float(
  self,
) {
  Float::from_double(self.as_double())
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_double(
  self,
) {
  self.as_double()
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_char(
  self,
) {
  let s = self.text()
  guard s.char_length() == 1 else {
    raise @data.InvalidValue(
      path=self.path,
      expected="a one-character string",
      found=s,
    )
  }
  s.to_array()[0]
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_string(
  self,
) {
  self.text()
}

///|
/// Overridden: the bytes are in hand, so a consumer that does not want a
/// `String` never pays for one.
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_str_bytes(
  self,
) {
  self.str_bytes()
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_bytes(
  self,
) {
  Bytes::from_iter(self.bin().iter())
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_option(
  self,
) {
  if self.peek() == 0xc0 {
    let _ = self.marker()
    None
  } else {
    Some(@data.Deserialize::deserialize(self))
  }
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_seq_begin(
  self,
) {
  Some(self.open(0x90, 0xdc, 0xdd, "sequence", []))
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_seq_next(
  self,
) {
  guard self.next_item() else { return None }
  let scope = self.top()
  self.path = scope.base.index(scope.count)
  scope.count = scope.count + 1
  Some(@data.Deserialize::deserialize(self))
}

///|
/// Overridden away from the sequence default, which would leave a scope the
/// tuple protocol never pops. The header still has to be read — a tuple is an
/// array on the wire — but its length comes from the type.
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_tuple_begin(
  self,
  len,
) {
  let n = self.open(0x90, 0xdc, 0xdd, "sequence", [])
  guard n == len else {
    raise @data.InvalidLength(path=self.path, expected=len, found=n)
  }
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_tuple_next(
  self,
) {
  let scope = self.top()
  self.path = scope.base.index(scope.count)
  scope.count = scope.count + 1
  scope.remaining = scope.remaining - 1
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_tuple_end(
  self,
) {
  let scope = self.top()
  let _ = self.scopes.pop()
  self.path = scope.base
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_map_begin(
  self,
) {
  Some(self.open(0x80, 0xde, 0xdf, "map", []))
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_map_next_key(
  self,
) {
  guard self.next_item() else { return None }
  Some(@data.Deserialize::deserialize(self))
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_map_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_struct_begin(
  self,
  _name,
  fields,
) {
  let _ = self.open(0x80, 0xde, 0xdf, "map", fields)

}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_field_name(
  self,
) {
  guard self.next_item() else { return None }
  let scope = self.top()
  let name = self.text()
  let mut interned = name
  for candidate in scope.expected {
    if candidate == name {
      interned = candidate
      break
    }
  }
  self.path = scope.base.key(interned)
  scope.count = scope.count + 1
  Some(interned)
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_field_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
/// Implementable, as in CBOR and unlike the non-self-describing fixture: every
/// marker says how much follows it.
pub impl @data.Deserializer for MsgpackDeserializer with fn skip_value(self) {
  let _ = self.parse_any()

}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_enum_begin(
  self,
  _name,
  variants,
) {
  let base = self.path
  let m = self.peek()
  let wrapped = (m >= 0x80 && m < 0x90) || m == 0xde || m == 0xdf
  if wrapped {
    let n = self.open(0x80, 0xde, 0xdf, "map", [])
    guard n == 1 else {
      raise @data.DeCustom(
        path=base,
        message="MessagePack: an enum is a one-entry map, not \{n}",
      )
    }
    let _ = self.scopes.pop()

  }
  let name = self.text()
  let mut index = -1
  for i, candidate in variants {
    if candidate == name {
      index = i
      break
    }
  }
  guard index >= 0 else {
    raise @data.UnknownVariant(path=base, variant=name, expected=variants)
  }
  self.enums.push({ base, })
  self.path = base.key(name)
  index
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_unit_variant(
  _self,
) {

}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_newtype_variant(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_enum_end(
  self,
) {
  match self.enums.pop() {
    Some(scope) => self.path = scope.base
    None =>
      raise @data.DeCustom(
        path=self.path,
        message="MessagePack: enum ended without a begin",
      )
  }
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn deserialize_any(
  self,
) {
  self.parse_any()
}

///|
fn MsgpackDeserializer::parse_any(
  self : MsgpackDeserializer,
) -> @data.Value raise @data.DeError {
  let m = self.peek()
  if m < 0x80 || m >= 0xe0 || (m >= 0xcc && m <= 0xd3) {
    let v = self.as_int64()
    return if v >= 0 { @data.UInt(v.reinterpret_as_uint64()) } else { @data.Int(v) }
  }
  if m >= 0xa0 && m < 0xc0 {
    return @data.Str(self.str_bytes())
  }
  if m >= 0x80 && m < 0x90 {
    return self.any_map()
  }
  if m >= 0x90 && m < 0xa0 {
    return self.any_seq()
  }
  match m {
    0xc0 => {
      let _ = self.marker()
      @data.Null
    }
    0xc2 | 0xc3 => @data.Boolean(self.marker() == 0xc3)
    0xc4 | 0xc5 | 0xc6 => @data.Bytes(Bytes::from_iter(self.bin().iter()))
    0xca | 0xcb => @data.Double(self.as_double())
    0xd9 | 0xda | 0xdb => @data.Str(self.str_bytes())
    0xdc | 0xdd => self.any_seq()
    0xde | 0xdf => self.any_map()
    // An ext is a type byte and an opaque payload with no inner value to fall
    // back to, unlike a CBOR tag, and `Value` has no case for one.
    _ =>
      raise @data.DeCustom(
        path=self.path,
        message="MessagePack: extension types are not part of the data model",
      )
  }
}

///|
fn MsgpackDeserializer::any_seq(
  self : MsgpackDeserializer,
) -> @data.Value raise @data.DeError {
  let n = self.open(0x90, 0xdc, 0xdd, "sequence", [])
  let items = []
  for _ in 0..<n {
    items.push(self.parse_any())
  }
  let _ = self.scopes.pop()
  @data.Seq(items)
}

///|
fn MsgpackDeserializer::any_map(
  self : MsgpackDeserializer,
) -> @data.Value raise @data.DeError {
  let n = self.open(0x80, 0xde, 0xdf, "map", [])
  let entries = []
  for _ in 0..<n {
    let k = self.parse_any()
    entries.push((k, self.parse_any()))
  }
  let _ = self.scopes.pop()
  @data.Map(entries)
}

///|
pub impl @data.Deserializer for MsgpackDeserializer with fn is_human_readable(
  _self,
) {
  false
}

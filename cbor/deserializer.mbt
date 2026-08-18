// The CBOR decoder.
//
// Accepts strictly more than the encoder produces: indefinite-length
// containers and strings, half-precision floats, and semantic tags. A decoder
// that only understood its own output would be useless for interoperating,
// which is the entire reason to prefer CBOR over an ad-hoc binary format.

///|
/// One open array, map or struct.
priv struct Scope {
  base : @data.Path
  /// Items still to read, or `INDEFINITE` for a container that ends at a break
  /// byte rather than at a count.
  mut remaining : Int
  /// How many have been read, for the path of the next one.
  mut count : Int
  /// The immutable field names the caller declared, empty for arrays and
  /// maps. Known keys reuse these canonical strings for paths.
  expected : ReadOnlyArray[String]
}

///|
const INDEFINITE : Int = -1

///|
let no_fields : ReadOnlyArray[String] = []

///|
/// One open enum, remembering the path to restore on the way out.
priv struct EnumScope {
  base : @data.Path
}

///|
/// Reads CBOR from bytes.
struct CborDeserializer {
  input : Bytes
  mut pos : Int
  mut path : @data.Path
  scopes : Array[Scope]
  enums : Array[EnumScope]
}

///|
pub fn CborDeserializer::new(input : Bytes) -> CborDeserializer {
  { input, pos: 0, path: @data.Root, scopes: [], enums: [] }
}

///|
/// Checks that the whole input was consumed.
pub fn CborDeserializer::finish(
  self : CborDeserializer,
) -> Unit raise @data.DeError {
  if self.pos < self.input.length() {
    raise @data.DeCustom(path=self.path, message="trailing input after value")
  }
}

// ---- reading heads ----

///|
fn CborDeserializer::byte(self : CborDeserializer) -> Byte raise @data.DeError {
  if self.pos >= self.input.length() {
    raise @data.Eof(path=self.path)
  }
  let b = self.input[self.pos]
  self.pos = self.pos + 1
  b
}

///|
fn CborDeserializer::peek_byte(
  self : CborDeserializer,
) -> Byte raise @data.DeError {
  if self.pos >= self.input.length() {
    raise @data.Eof(path=self.path)
  }
  self.input[self.pos]
}

///|
fn CborDeserializer::be(
  self : CborDeserializer,
  count : Int,
) -> UInt64 raise @data.DeError {
  let mut acc = 0UL
  for _ in 0..<count {
    acc = (acc << 8) | self.byte().to_uint64()
  }
  acc
}

///|
/// A decoded head: the major type, its argument, and whether the argument was
/// the indefinite marker rather than a length.
priv struct Head {
  major : Int
  arg : UInt64
  indefinite : Bool
}

///|
fn CborDeserializer::head(self : CborDeserializer) -> Head raise @data.DeError {
  let initial = self.byte().to_int()
  let major = initial >> 5
  let info = initial & 0x1F
  match info {
    31 => { major, arg: 0, indefinite: true }
    24 => { major, arg: self.be(1), indefinite: false }
    25 => { major, arg: self.be(2), indefinite: false }
    26 => { major, arg: self.be(4), indefinite: false }
    27 => { major, arg: self.be(8), indefinite: false }
    _ =>
      if info < 24 {
        {
          major,
          arg: info.to_int64().reinterpret_as_uint64(),
          indefinite: false,
        }
      } else {
        raise @data.DeCustom(
          path=self.path,
          message="CBOR: reserved additional information \{info}",
        )
      }
  }
}

///|
/// A head, with semantic tags stepped over.
///
/// Tags are read and dropped, so a tagged value decodes as its content. `Value`
/// has no case for a tag, and rejecting them would refuse ordinary documents
/// from encoders that mark their timestamps or bignums.
fn CborDeserializer::untagged_head(
  self : CborDeserializer,
) -> Head raise @data.DeError {
  let mut h = self.head()
  while h.major == 6 {
    h = self.head()
  }
  h
}

///|
fn CborDeserializer::expect_head(
  self : CborDeserializer,
  major : Int,
  what : String,
) -> Head raise @data.DeError {
  let h = self.untagged_head()
  guard h.major == major else {
    raise @data.InvalidType(
      path=self.path,
      expected=what,
      found=major_name(h.major),
    )
  }
  h
}

///|
fn major_name(major : Int) -> String {
  match major {
    0 | 1 => "integer"
    2 => "bytes"
    3 => "string"
    4 => "sequence"
    5 => "map"
    6 => "a tag"
    _ => "a simple value"
  }
}

///|
fn CborDeserializer::at_break(
  self : CborDeserializer,
) -> Bool raise @data.DeError {
  self.peek_byte() == BREAK
}

// ---- integers ----

///|
/// The value of an integer head, as `Int64`.
///
/// Both integer major types land here: an unsigned argument that does not fit
/// `Int64` is out of range, and a negative one is `-1 - arg`.
fn CborDeserializer::as_int64(
  self : CborDeserializer,
) -> Int64 raise @data.DeError {
  let h = self.untagged_head()
  match h.major {
    0 =>
      if h.arg > 0x7FFFFFFFFFFFFFFF {
        raise @data.InvalidValue(
          path=self.path,
          expected="a signed integer",
          found=h.arg.to_string(),
        )
      } else {
        h.arg.reinterpret_as_int64()
      }
    1 =>
      if h.arg > 0x7FFFFFFFFFFFFFFF {
        raise @data.InvalidValue(
          path=self.path,
          expected="a signed integer",
          found="-1-\{h.arg}",
        )
      } else {
        h.arg.reinterpret_as_int64().lnot()
      }
    other =>
      raise @data.InvalidType(
        path=self.path,
        expected="integer",
        found=major_name(other),
      )
  }
}

///|
fn CborDeserializer::int_in_range(
  self : CborDeserializer,
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
fn CborDeserializer::as_uint64(
  self : CborDeserializer,
) -> UInt64 raise @data.DeError {
  let h = self.untagged_head()
  guard h.major == 0 else {
    raise @data.InvalidType(
      path=self.path,
      expected="an unsigned integer",
      found=major_name(h.major),
    )
  }
  h.arg
}

// ---- floats ----

///|
/// Half precision, which the encoder never writes and plenty of others do.
fn half_to_double(bits : Int) -> Double {
  let sign = ((bits >> 15) & 1).to_int64().reinterpret_as_uint64() << 63
  let exponent = (bits >> 10) & 0x1F
  let mantissa = bits & 0x3FF
  let frac = mantissa.to_int64().reinterpret_as_uint64() << 42
  // Assembled bit by bit rather than computed with `pow`, so every half is
  // exactly the double it denotes rather than the nearest one a power
  // function happened to return.
  if exponent == 31 {
    return (sign | 0x7FF0000000000000 | frac).reinterpret_as_double()
  }
  if exponent == 0 {
    if mantissa == 0 {
      return sign.reinterpret_as_double()
    }
    // Subnormal as a half, comfortably normal as a double: shift until the
    // implicit leading one appears and drop the exponent to match.
    let mut m = mantissa
    let mut e = -14
    while (m & 0x400) == 0 {
      m = m << 1
      e = e - 1
    }
    let biased = (e + 1023).to_int64().reinterpret_as_uint64() << 52
    let normalized = (m & 0x3FF).to_int64().reinterpret_as_uint64() << 42
    return (sign | biased | normalized).reinterpret_as_double()
  }
  let biased = (exponent - 15 + 1023).to_int64().reinterpret_as_uint64() << 52
  (sign | biased | frac).reinterpret_as_double()
}

///|
/// Any of the three float widths, or an integer widened.
///
/// Widening is deliberate: a document written by an encoder that shortens
/// whole numbers to integers still decodes into a `Double` field, which is
/// what a reader asking for one wants.
fn CborDeserializer::as_double(
  self : CborDeserializer,
) -> Double raise @data.DeError {
  let before = self.pos
  let h = self.untagged_head()
  match h.major {
    7 =>
      match h.arg {
        _ if self.input[before] == b'\xf9' =>
          half_to_double(h.arg.to_uint().reinterpret_as_int())
        _ if self.input[before] == b'\xfa' =>
          Float::reinterpret_from_uint(h.arg.to_uint()).to_double()
        _ if self.input[before] == b'\xfb' => h.arg.reinterpret_as_double()
        _ =>
          raise @data.InvalidType(
            path=self.path,
            expected="a double",
            found="a simple value",
          )
      }
    0 => h.arg.to_double()
    1 => h.arg.reinterpret_as_int64().lnot().to_double()
    other =>
      raise @data.InvalidType(
        path=self.path,
        expected="a double",
        found=major_name(other),
      )
  }
}

// ---- strings and byte strings ----

///|
/// The payload of a definite- or indefinite-length string.
///
/// An indefinite string is a sequence of definite chunks closed by a break;
/// the chunks are concatenated, so the segmentation is invisible to the caller
/// exactly as the spec intends.
fn CborDeserializer::blob(
  self : CborDeserializer,
  major : Int,
  what : String,
) -> BytesView raise @data.DeError {
  let h = self.expect_head(major, what)
  if !h.indefinite {
    return self.take(h.arg)
  }
  let parts = Buffer(size_hint=32)
  while !self.at_break() {
    let chunk = self.expect_head(major, what)
    guard !chunk.indefinite else {
      raise @data.DeCustom(
        path=self.path,
        message="CBOR: nested indefinite string",
      )
    }
    parts.write_bytesview(self.take(chunk.arg))
  }
  let _ = self.byte()
  parts.to_bytes()[:]
}

///|
fn CborDeserializer::take(
  self : CborDeserializer,
  length : UInt64,
) -> BytesView raise @data.DeError {
  let left = (self.input.length() - self.pos).to_int64().reinterpret_as_uint64()
  guard length <= left else {
    raise @data.DeCustom(
      path=self.path,
      message="CBOR: length \{length} exceeds the \{left} byte(s) remaining",
    )
  }
  let n = length.to_uint().reinterpret_as_int()
  let view = self.input[self.pos:self.pos + n]
  self.pos = self.pos + n
  view
}

///|
fn CborDeserializer::decode_text(
  self : CborDeserializer,
  view : BytesView,
) -> String raise @data.DeError {
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
fn CborDeserializer::text(
  self : CborDeserializer,
) -> String raise @data.DeError {
  self.decode_text(self.blob(TEXT, "string"))
}

// ---- container bookkeeping ----

///|
fn CborDeserializer::open(
  self : CborDeserializer,
  major : Int,
  what : String,
  expected : ReadOnlyArray[String],
) -> Int? raise @data.DeError {
  let h = self.expect_head(major, what)
  let remaining = if h.indefinite {
    INDEFINITE
  } else {
    h.arg.to_uint().reinterpret_as_int()
  }
  self.scopes.push({ base: self.path, remaining, count: 0, expected })
  if h.indefinite {
    None
  } else {
    Some(remaining)
  }
}

///|
fn CborDeserializer::top(self : CborDeserializer) -> Scope raise @data.DeError {
  match self.scopes.last() {
    Some(scope) => scope
    None =>
      raise @data.DeCustom(
        path=self.path,
        message="CBOR: item outside a container",
      )
  }
}

///|
/// Whether another item follows, consuming the break byte if one closes an
/// indefinite container and restoring the path either way.
fn CborDeserializer::next_item(
  self : CborDeserializer,
) -> Bool raise @data.DeError {
  let scope = self.top()
  if scope.remaining == INDEFINITE {
    if self.at_break() {
      let _ = self.byte()
      let _ = self.scopes.pop()
      self.path = scope.base
      return false
    }
  } else if scope.remaining == 0 {
    let _ = self.scopes.pop()
    self.path = scope.base
    return false
  } else {
    scope.remaining = scope.remaining - 1
  }
  true
}

///|
pub impl @data.Deserializer for CborDeserializer with fn path(self) {
  self.path
}

// ---- primitives ----

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_unit(self) {
  let h = self.untagged_head()
  guard h.major == 7 && h.arg == 22 else {
    raise @data.InvalidType(
      path=self.path,
      expected="unit",
      found=major_name(h.major),
    )
  }
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_bool(self) {
  let h = self.untagged_head()
  match (h.major, h.arg) {
    (7, 20) => false
    (7, 21) => true
    _ =>
      raise @data.InvalidType(
        path=self.path,
        expected="boolean",
        found=major_name(h.major),
      )
  }
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_byte(self) {
  self.int_in_range(0, 255, "a byte").to_byte()
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_int16(self) {
  Int16::from_int64(self.int_in_range(-32768, 32767, "an int16"))
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_uint16(
  self,
) {
  self.int_in_range(0, 65535, "a uint16").to_uint16()
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_int(self) {
  self.int_in_range(-2147483648, 2147483647, "an int").to_int()
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_uint(self) {
  self.int_in_range(0, 4294967295, "a uint").reinterpret_as_uint64().to_uint()
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_int64(self) {
  self.as_int64()
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_uint64(
  self,
) {
  self.as_uint64()
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_float(self) {
  Float::from_double(self.as_double())
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_double(
  self,
) {
  self.as_double()
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_char(self) {
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
pub impl @data.Deserializer for CborDeserializer with fn deserialize_string(
  self,
) {
  self.text()
}

///|
/// Overridden: the bytes are already in hand, so a consumer that does not want
/// a `String` never pays for one.
pub impl @data.Deserializer for CborDeserializer with fn deserialize_str_bytes(
  self,
) {
  self.blob(TEXT, "string")
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_bytes(self) {
  Bytes::from_iter(self.blob(BYTES, "bytes").iter())
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_option(
  self,
) {
  if self.peek_byte() == b'\xf6' {
    let _ = self.byte()
    None
  } else {
    Some(@data.Deserialize::deserialize(self))
  }
}

// ---- sequences and maps ----

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_seq_begin(
  self,
) {
  self.open(ARRAY, "sequence", no_fields)
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_seq_next(
  self,
) {
  guard self.next_item() else { return None }
  let scope = self.top()
  self.path = scope.base.index(scope.count)
  scope.count = scope.count + 1
  Some(@data.Deserialize::deserialize(self))
}

///|
/// Overridden away from the sequence default, which would push a scope the
/// tuple protocol never pops. A CBOR tuple is an array, so the head still has
/// to be read — but its length comes from the type, and the elements are read
/// unconditionally.
pub impl @data.Deserializer for CborDeserializer with fn deserialize_tuple_begin(
  self,
  len,
) {
  let h = self.expect_head(ARRAY, "sequence")
  if !h.indefinite && h.arg != len.to_int64().reinterpret_as_uint64() {
    raise @data.InvalidLength(
      path=self.path,
      expected=len,
      found=h.arg.to_uint().reinterpret_as_int(),
    )
  }
  self.scopes.push({
    base: self.path,
    remaining: if h.indefinite {
      INDEFINITE
    } else {
      len
    },
    count: 0,
    expected: no_fields,
  })
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_tuple_next(
  self,
) {
  let scope = self.top()
  self.path = scope.base.index(scope.count)
  scope.count = scope.count + 1
  if scope.remaining != INDEFINITE {
    scope.remaining = scope.remaining - 1
  }
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_tuple_end(
  self,
) {
  let scope = self.top()
  let _ = self.scopes.pop()
  self.path = scope.base
  if scope.remaining == INDEFINITE {
    guard self.at_break() else {
      raise @data.DeCustom(
        path=self.path,
        message="CBOR: indefinite tuple did not end where the type does",
      )
    }
    let _ = self.byte()
  }
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_map_begin(
  self,
) {
  self.open(MAP, "map", no_fields)
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_map_next_key(
  self,
) {
  guard self.next_item() else { return None }
  Some(@data.Deserialize::deserialize(self))
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_map_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

// ---- structs ----

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_struct_begin(
  self,
  _name,
  fields,
) {
  let _ = self.open(MAP, "map", fields)
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_field_name(
  self,
) {
  guard self.next_item() else { return None }
  let scope = self.top()
  let name = self.text()
  let interned = match scope.expected.search(name) {
    Some(index) => scope.expected[index]
    None => name
  }
  self.path = scope.base.key(interned)
  scope.count = scope.count + 1
  Some(interned)
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_field(self) {
  guard self.next_item() else { return None }
  let scope = self.top()
  let key = self.blob(TEXT, "string")
  let field = @data.FieldIdentifier::from_bytes(key, scope.count)
  let name = match @data.FieldIdentifier::name(field) {
    Some(name) => name
    None => self.decode_text(key)
  }
  self.path = scope.base.key(name)
  scope.count = scope.count + 1
  Some(field)
}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_field_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
/// Implementable here, unlike in a non-self-describing format: every head says
/// how much follows it, so a value can be stepped over without knowing what it
/// was meant to be.
pub impl @data.Deserializer for CborDeserializer with fn skip_value(self) {
  let _ = self.parse_any()
}

// ---- enums ----

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_enum_begin(
  self,
  _name,
  variants,
) {
  let base = self.path
  let wrapped = self.peek_byte().to_int() >> 5 == MAP
  if wrapped {
    let h = self.expect_head(MAP, "map")
    guard !h.indefinite && h.arg == 1 else {
      raise @data.DeCustom(
        path=base,
        message="CBOR: an enum is a one-entry map, not \{h.arg}",
      )
    }
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
pub impl @data.Deserializer for CborDeserializer with fn deserialize_unit_variant(
  _self,
) {

}

///|
pub impl @data.Deserializer for CborDeserializer with fn deserialize_newtype_variant(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
/// A definite one-entry map needs nothing consumed on the way out, so this
/// restores the path and no more — the same shape the trait's default has, but
/// the path bookkeeping has to happen somewhere.
pub impl @data.Deserializer for CborDeserializer with fn deserialize_enum_end(
  self,
) {
  match self.enums.pop() {
    Some(scope) => self.path = scope.base
    None =>
      raise @data.DeCustom(
        path=self.path,
        message="CBOR: enum ended without a begin",
      )
  }
}

// ---- untyped ----

///|
/// Reads whatever is present. CBOR is self-describing, so this is total.
pub impl @data.Deserializer for CborDeserializer with fn deserialize_any(self) {
  self.parse_any()
}

///|
fn CborDeserializer::parse_any(
  self : CborDeserializer,
) -> @data.Value raise @data.DeError {
  let start = self.pos
  let h = self.untagged_head()
  match h.major {
    0 => @data.UInt(h.arg)
    1 => @data.Int(h.arg.reinterpret_as_int64().lnot())
    2 => {
      self.pos = start
      @data.Bytes(Bytes::from_iter(self.blob(BYTES, "bytes").iter()))
    }
    3 => {
      self.pos = start
      @data.Str(self.blob(TEXT, "string"))
    }
    4 => {
      let items = []
      if h.indefinite {
        while !self.at_break() {
          items.push(self.parse_any())
        }
        let _ = self.byte()
      } else {
        for _ in 0U..<h.arg.to_uint() {
          items.push(self.parse_any())
        }
      }
      @data.Seq(ReadOnlyArray::from_array(items))
    }
    5 => {
      let entries = []
      if h.indefinite {
        while !self.at_break() {
          let k = self.parse_any()
          entries.push((k, self.parse_any()))
        }
        let _ = self.byte()
      } else {
        for _ in 0U..<h.arg.to_uint() {
          let k = self.parse_any()
          entries.push((k, self.parse_any()))
        }
      }
      @data.Map(ReadOnlyArray::from_array(entries))
    }
    _ =>
      match h.arg {
        20 => @data.Boolean(false)
        21 => @data.Boolean(true)
        22 | 23 => @data.Null
        _ => {
          self.pos = start
          @data.Double(self.as_double())
        }
      }
  }
}

///|
pub impl @data.Deserializer for CborDeserializer with fn is_human_readable(
  _self,
) {
  false
}

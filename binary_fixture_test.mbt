// A non-self-describing binary format, for testing the abstraction only.
//
// This is deliberately not a product. The MoonBit registry has no postcard or
// bincode presence, so shipping a Rust-internal convention would be dead
// weight; it lives in a black-box test file, where it never reaches
// `pkg.generated.mbti`.
//
// What it is for: `json` and `Value` are the only implementations of the two
// traits, and neither exercises the half of the design that justifies the
// `deserialize_*` hints existing at all — a format where the bytes carry no
// structure and the type is the only schema. `Value` holds the whole document
// in memory, which is exactly the case the tuple and enum-end defaults are
// documented as being correct for. Something has to test the other case.
//
// The encoding, little-endian and fixed-width throughout. Compactness is not a
// goal; being unambiguously non-self-describing is.
//
//   unit, unit struct     nothing
//   bool, byte            one byte
//   int16 / uint16        two bytes
//   int / uint            four bytes
//   int64 / uint64        eight bytes
//   float                 widened to double, eight bytes
//   double                eight bytes, raw bits
//   char                  four bytes, the code point
//   string, bytes         u32 length, then the payload
//   option                one tag byte, then the value if present
//   seq, map              u32 count, then the items
//   struct                nothing — fields in declaration order, no names
//   tuple, tuple struct   nothing — elements in order
//   enum                  u32 variant index, then the payload
//   newtype struct        transparent
//
// Reading a struct back therefore depends entirely on `fields`, and reading an
// enum on `variants`. Those two arrays are what make a positional format
// possible without a `Visitor`, and until now nothing checked that they are
// enough.

// ---- writing ----

///|
/// Writes the encoding above.
///
/// Worth noting what is absent: there is no scope stack. `JsonSerializer` needs
/// one to know whether a comma is due and which bracket closes; here every
/// count is written up front from the length hint and no compound has a
/// terminator, so `_end` is genuinely nothing. The flattened protocol costs a
/// positional format nothing at all on the write side.
struct BinSerializer {
  out : @buffer.Buffer
}

///|
fn BinSerializer::new() -> BinSerializer {
  { out: Buffer(size_hint=256) }
}

///|
fn BinSerializer::finish(self : BinSerializer) -> Bytes {
  self.out.to_bytes()
}

///|
fn BinSerializer::u16(self : BinSerializer, v : Int) -> Unit {
  self.out.write_byte((v & 0xFF).to_byte())
  self.out.write_byte(((v >> 8) & 0xFF).to_byte())
}

///|
fn BinSerializer::u32(self : BinSerializer, v : UInt) -> Unit {
  self.out.write_byte((v & 0xFF).to_byte())
  self.out.write_byte(((v >> 8) & 0xFF).to_byte())
  self.out.write_byte(((v >> 16) & 0xFF).to_byte())
  self.out.write_byte(((v >> 24) & 0xFF).to_byte())
}

///|
fn BinSerializer::u64(self : BinSerializer, v : UInt64) -> Unit {
  self.u32((v & 0xFFFFFFFFUL).to_uint())
  self.u32((v >> 32).to_uint())
}

///|
/// A length prefix, and the bytes it counts.
fn BinSerializer::blob(self : BinSerializer, payload : BytesView) -> Unit {
  self.u32(payload.length().reinterpret_as_uint())
  self.out.write_bytesview(payload)
}

///|
/// The count a length-prefixed format has to have before it writes anything.
///
/// `serialize_seq_begin` takes `Int?`, so the trait permits a caller that does
/// not know its own length. This format cannot represent that — it would have
/// to buffer the whole sequence to discover the count, which is exactly the
/// streaming property it exists to have. `Array` and `Map` always pass `Some`,
/// so this never fires in practice; serde has the identical hole.
fn BinSerializer::count(
  self : BinSerializer,
  hint : Int?,
) -> Unit raise @data.SerError {
  match hint {
    Some(n) => self.u32(n.reinterpret_as_uint())
    None =>
      raise @data.UnsupportedType(
        format="bin", kind="a sequence of unknown length",
      )
  }
}

///|
impl @data.Serializer for BinSerializer with fn serialize_unit(_self) {

}

///|
impl @data.Serializer for BinSerializer with fn serialize_bool(self, v) {
  self.out.write_byte(if v { b'\x01' } else { b'\x00' })
}

///|
impl @data.Serializer for BinSerializer with fn serialize_byte(self, v) {
  self.out.write_byte(v)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_int16(self, v) {
  self.u16(v.to_int())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_uint16(self, v) {
  self.u16(v.to_int())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_int(self, v) {
  self.u32(v.reinterpret_as_uint())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_uint(self, v) {
  self.u32(v)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_int64(self, v) {
  self.u64(v.reinterpret_as_uint64())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_uint64(self, v) {
  self.u64(v)
}

///|
/// Widened rather than written as four bytes: every `Float` is exactly a
/// `Double`, and `Float::from_double` of that value returns it unchanged, so
/// the round trip is bit-exact without needing a 32-bit reinterpret.
impl @data.Serializer for BinSerializer with fn serialize_float(self, v) {
  self.u64(v.to_double().reinterpret_as_uint64())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_double(self, v) {
  self.u64(v.reinterpret_as_uint64())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_char(self, v) {
  self.u32(v.to_int().reinterpret_as_uint())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_string(self, v) {
  self.blob(@utf8.encode(v)[:])
}

///|
/// Overridden, unlike in JSON. The transport is bytes, so text that is already
/// UTF-8 should never be decoded into a `String` just to be encoded again.
impl @data.Serializer for BinSerializer with fn serialize_str_bytes(self, v) {
  self.blob(v)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_bytes(self, v) {
  self.blob(v[:])
}

///|
impl @data.Serializer for BinSerializer with fn serialize_none(self) {
  self.out.write_byte(b'\x00')
}

///|
impl @data.Serializer for BinSerializer with fn serialize_some(self, v) {
  self.out.write_byte(b'\x01')
  v.serialize(self)
}

///|
/// The index, not the name — which is the whole reason `VariantInfo` carries
/// one. Nothing about the variant's spelling reaches the wire.
impl @data.Serializer for BinSerializer with fn serialize_unit_variant(
  self,
  info,
) {
  self.u32(info.index.reinterpret_as_uint())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_newtype_variant(
  self,
  info,
  v,
) {
  self.u32(info.index.reinterpret_as_uint())
  v.serialize(self)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_seq_begin(self, hint) {
  self.count(hint)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_seq_element(self, v) {
  v.serialize(self)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_seq_end(_self) {

}

///|
/// Overridden away from the sequence default, which would write a count a
/// tuple's length already implies. Every real format has had to override these
/// three; only `Value` uses the defaults.
impl @data.Serializer for BinSerializer with fn serialize_tuple_begin(
  _self,
  _len,
) {

}

///|
impl @data.Serializer for BinSerializer with fn serialize_tuple_element(self, v) {
  v.serialize(self)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_tuple_end(_self) {

}

///|
impl @data.Serializer for BinSerializer with fn serialize_map_begin(self, hint) {
  self.count(hint)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_map_key(self, k) {
  k.serialize(self)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_map_value(self, v) {
  v.serialize(self)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_map_end(_self) {

}

///|
impl @data.Serializer for BinSerializer with fn serialize_struct_begin(
  _self,
  _name,
  _len,
) {

}

///|
/// The name is dropped on the floor. Reading it back depends on the type
/// handing the same `fields` array to `deserialize_struct_begin`.
impl @data.Serializer for BinSerializer with fn serialize_field(self, _name, v) {
  v.serialize(self)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_struct_end(_self) {

}

///|
impl @data.Serializer for BinSerializer with fn serialize_tuple_variant_begin(
  self,
  info,
  _len,
) {
  self.u32(info.index.reinterpret_as_uint())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_tuple_variant_element(
  self,
  v,
) {
  v.serialize(self)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_tuple_variant_end(
  _self,
) {

}

///|
impl @data.Serializer for BinSerializer with fn serialize_struct_variant_begin(
  self,
  info,
  _len,
) {
  self.u32(info.index.reinterpret_as_uint())
}

///|
impl @data.Serializer for BinSerializer with fn serialize_struct_variant_field(
  self,
  _name,
  v,
) {
  v.serialize(self)
}

///|
impl @data.Serializer for BinSerializer with fn serialize_struct_variant_end(
  _self,
) {

}

///|
impl @data.Serializer for BinSerializer with fn is_human_readable(_self) {
  false
}

// ---- reading ----

///|
/// One open struct, serving field names the wire never carried.
///
/// This is the `fields` trick that stands in for serde's `visit_seq` on a
/// struct visitor: the type declares the names, the format replays them in
/// order, and the generated `match` rediscovers an index the cursor already
/// had.
priv struct FieldCursor {
  names : Array[String]
  mut next : Int
}

///|
/// Reads the encoding above.
///
/// Unlike the serializer this does need stacks — not for delimiters, which do
/// not exist, but because `deserialize_seq_next` and `deserialize_field_name`
/// have to answer "is there more?" from a count rather than from a lookahead.
struct BinDeserializer {
  input : Bytes
  mut pos : Int
  counts : Array[Int]
  fields : Array[FieldCursor]
}

///|
fn BinDeserializer::new(input : Bytes) -> BinDeserializer {
  { input, pos: 0, counts: [], fields: [] }
}

///|
fn BinDeserializer::finish(
  self : BinDeserializer,
) -> Unit raise @data.DeError {
  if self.pos < self.input.length() {
    raise @data.DeCustom(path=Root, message="bin: trailing input after value")
  }
}

///|
fn BinDeserializer::byte(self : BinDeserializer) -> Byte raise @data.DeError {
  if self.pos >= self.input.length() {
    raise @data.Eof(path=Root)
  }
  let b = self.input[self.pos]
  self.pos = self.pos + 1
  b
}

///|
fn BinDeserializer::u16(self : BinDeserializer) -> Int raise @data.DeError {
  let a = self.byte().to_int()
  let b = self.byte().to_int()
  a | (b << 8)
}

///|
fn BinDeserializer::u32(self : BinDeserializer) -> UInt raise @data.DeError {
  let a = self.byte().to_uint()
  let b = self.byte().to_uint()
  let c = self.byte().to_uint()
  let d = self.byte().to_uint()
  a | (b << 8) | (c << 16) | (d << 24)
}

///|
fn BinDeserializer::u64(self : BinDeserializer) -> UInt64 raise @data.DeError {
  let lo = self.u32().to_uint64()
  let hi = self.u32().to_uint64()
  lo | (hi << 32)
}

///|
/// A count read from the input, checked against what is left of it.
///
/// A format that can do this should: it turns a corrupt length into an error at
/// the point of reading rather than an allocation. `cautious_capacity` in
/// `impls.mbt` is the backstop for formats that cannot.
fn BinDeserializer::count(self : BinDeserializer) -> Int raise @data.DeError {
  let n = self.u32().reinterpret_as_int()
  let left = self.input.length() - self.pos
  if n < 0 || n > left {
    // Not `InvalidLength`: that one means a sequence had the wrong number of
    // elements, which is a statement about the type. This is a statement about
    // the input — a count that cannot possibly be satisfied by the bytes left.
    raise @data.DeCustom(
      path=Root,
      message="bin: length \{n} exceeds the \{left} byte(s) remaining",
    )
  }
  n
}

///|
fn BinDeserializer::blob(
  self : BinDeserializer,
) -> BytesView raise @data.DeError {
  let n = self.count()
  let view = self.input[self.pos:self.pos + n]
  self.pos = self.pos + n
  view
}

///|
/// Always `Root`.
///
/// `path` has no default, so even a format with no interest in error paths must
/// implement it. The cost is one line, but it is a line every format pays.
impl @data.Deserializer for BinDeserializer with fn path(_self) {
  Root
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_unit(_self) {

}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_bool(self) {
  match self.byte() {
    b'\x00' => false
    b'\x01' => true
    other =>
      raise @data.InvalidValue(
        path=Root,
        expected="a boolean tag",
        found=other.to_int().to_string(),
      )
  }
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_byte(self) {
  self.byte()
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_int16(self) {
  let raw = self.u16()
  Int16::from_int64((if raw >= 0x8000 { raw - 0x10000 } else { raw }).to_int64())
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_uint16(self) {
  self.u16().to_int64().to_uint16()
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_int(self) {
  self.u32().reinterpret_as_int()
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_uint(self) {
  self.u32()
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_int64(self) {
  self.u64().reinterpret_as_int64()
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_uint64(self) {
  self.u64()
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_float(self) {
  Float::from_double(self.u64().reinterpret_as_double())
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_double(self) {
  self.u64().reinterpret_as_double()
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_char(self) {
  let code = self.u32().reinterpret_as_int()
  match Int::to_char(code) {
    Some(c) => c
    None =>
      raise @data.InvalidValue(
        path=Root,
        expected="a Unicode scalar value",
        found=code.to_string(),
      )
  }
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_string(self) {
  let view = self.blob()
  @utf8.decode(view) catch {
    _ => raise @data.InvalidValue(path=Root, expected="UTF-8", found="raw bytes")
  }
}

///|
/// Overridden, unlike in JSON: the bytes are already in hand, so a consumer
/// that does not want a `String` never pays for one.
impl @data.Deserializer for BinDeserializer with fn deserialize_str_bytes(self) {
  self.blob()
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_bytes(self) {
  Bytes::from_iter(self.blob().iter())
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_option(self) {
  match self.byte() {
    b'\x00' => None
    b'\x01' => Some(@data.Deserialize::deserialize(self))
    other =>
      raise @data.InvalidValue(
        path=Root,
        expected="an option tag",
        found=other.to_int().to_string(),
      )
  }
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_seq_begin(self) {
  let n = self.count()
  self.counts.push(n)
  Some(n)
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_seq_next(self) {
  let top = self.counts.length() - 1
  guard top >= 0 else {
    raise @data.DeCustom(path=Root, message="bin: sequence item outside a sequence")
  }
  if self.counts[top] == 0 {
    let _ = self.counts.pop()
    None
  } else {
    self.counts[top] = self.counts[top] - 1
    Some(@data.Deserialize::deserialize(self))
  }
}

///|
/// Overridden away from the sequence default, which would read a count the
/// tuple encoding never wrote. A tuple's length comes from the type, so the
/// wire carries nothing and these three are pure pass-throughs.
impl @data.Deserializer for BinDeserializer with fn deserialize_tuple_begin(
  _self,
  _len,
) {

}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_tuple_next(self) {
  @data.Deserialize::deserialize(self)
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_tuple_end(_self) {

}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_map_begin(self) {
  let n = self.count()
  self.counts.push(n)
  Some(n)
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_map_next_key(
  self,
) {
  let top = self.counts.length() - 1
  guard top >= 0 else {
    raise @data.DeCustom(path=Root, message="bin: map key outside a map")
  }
  if self.counts[top] == 0 {
    let _ = self.counts.pop()
    None
  } else {
    self.counts[top] = self.counts[top] - 1
    Some(@data.Deserialize::deserialize(self))
  }
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_map_value(self) {
  @data.Deserialize::deserialize(self)
}

///|
/// `fields` is the schema. Nothing in the input says how many fields there are
/// or what they are called; the type does, and that is enough.
impl @data.Deserializer for BinDeserializer with fn deserialize_struct_begin(
  self,
  _name,
  fields,
) {
  self.fields.push({ names: fields, next: 0 })
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_field_name(self) {
  let top = self.fields.length() - 1
  guard top >= 0 else {
    raise @data.DeCustom(path=Root, message="bin: field outside a struct")
  }
  let cursor = self.fields[top]
  if cursor.next >= cursor.names.length() {
    let _ = self.fields.pop()
    None
  } else {
    let name = cursor.names[cursor.next]
    cursor.next = cursor.next + 1
    Some(name)
  }
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_field_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
/// Unimplementable, and never called.
///
/// Skipping needs to know how many bytes a value occupies, which is precisely
/// what a non-self-describing format does not record. It stays unreachable
/// because `deserialize_field_name` only ever returns names drawn from the
/// type's own `fields`, so the generated `_ =>` arm has nothing to match.
impl @data.Deserializer for BinDeserializer with fn skip_value(_self) {
  raise @data.DeCustom(
    path=Root,
    message="bin: cannot skip a value in a non-self-describing format",
  )
}

///|
/// `variants` is to enums what `fields` is to structs: the wire carries an
/// index and the type supplies the spelling. Note that the index is right here
/// and is immediately discarded so the generated code can match on a string it
/// then maps back to an index.
impl @data.Deserializer for BinDeserializer with fn deserialize_enum_begin(
  self,
  _name,
  variants,
) {
  let index = self.u32().reinterpret_as_int()
  if index < 0 || index >= variants.length() {
    raise @data.UnknownVariant(
      path=Root,
      variant=index.to_string(),
      expected=variants,
    )
  }
  variants[index]
}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_unit_variant(
  _self,
) {

}

///|
impl @data.Deserializer for BinDeserializer with fn deserialize_newtype_variant(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
/// Not overridden: the default does nothing, and nothing is correct. An
/// external tag with no wrapper leaves no delimiter to close.
impl @data.Deserializer for BinDeserializer with fn deserialize_any(_self) {
  raise @data.DeCustom(
    path=Root,
    message="bin: not self-describing, deserialize_any is impossible",
  )
}

///|
impl @data.Deserializer for BinDeserializer with fn is_human_readable(_self) {
  false
}

// ---- entry points ----

///|
fn[T : @data.Serialize] bin_to_bytes(value : T) -> Bytes raise @data.SerError {
  let s = BinSerializer::new()
  value.serialize(s)
  s.finish()
}

///|
fn[T : @data.Deserialize] bin_from_bytes(
  input : Bytes,
) -> T raise @data.DeError {
  let d = BinDeserializer::new(input)
  let value = @data.Deserialize::deserialize(d)
  d.finish()
  value
}

// ---- what the fixture exists to establish ----

///|
/// The claim the whole file rests on: a struct survives a round trip through a
/// format that never wrote its field names.
test "a struct round-trips with no field names on the wire" {
  let p = Point::{ x: 7, y: -3, label: Some("origin") }
  let bytes = bin_to_bytes(p)
  assert_eq(bin_from_bytes(bytes), p)
  // `x` and `y` are four bytes each, `label` is a present-tag plus a length
  // plus six bytes of text: 4 + 4 + 1 + 4 + 6. Any name on the wire would show
  // up here.
  assert_eq(bytes.length(), 19)
}

///|
test "a struct with no label is shorter by exactly the absent payload" {
  let p = Point::{ x: 1, y: 2, label: None }
  assert_eq(bin_to_bytes(p).length(), 4 + 4 + 1)
  assert_eq(bin_from_bytes(bin_to_bytes(p)), p)
}

///|
/// Enums travel as an index. `Empty` is variant 0 and carries nothing, so the
/// entire encoding is four zero bytes.
test "an enum travels as a bare variant index" {
  assert_eq(bin_to_bytes(Shape::Empty), b"\x00\x00\x00\x00")
  assert_eq(bin_to_bytes(Shape::Circle(1.0)).length(), 4 + 8)
  for shape in [
      Shape::Empty,
      Shape::Circle(2.5),
      Shape::Rect(1.0, 2.0),
      Shape::Tagged(name="s", size=3),
    ] {
    assert_eq(bin_from_bytes(bin_to_bytes(shape)), shape)
  }
}

///|
test "a variant index outside the type's variants is rejected" {
  let bad : Bytes = b"\x63\x00\x00\x00"
  try (bin_from_bytes(bad) : Shape) catch {
    e => inspect(e, content=(
      #|$: unknown variant `99`, expected one of Empty, Circle, Rect, Tagged
    ))
  } noraise {
    _ => fail("expected an unknown-variant error")
  }
}

///|
/// The property that makes this file worth having: the format cannot answer
/// "what is here?", only "give me the thing I asked for".
test "deserialize_any is impossible and says so" {
  let bytes = bin_to_bytes(42)
  try (bin_from_bytes(bytes) : @data.Value) catch {
    e => inspect(e, content=(
      #|$: bin: not self-describing, deserialize_any is impossible
    ))
  } noraise {
    _ => fail("expected deserialize_any to be refused")
  }
}

///|
test "the format declares itself unreadable by people" {
  let s = BinSerializer::new()
  assert_false(@data.Serializer::is_human_readable(s))
  let d = BinDeserializer::new(b"")
  assert_false(@data.Deserializer::is_human_readable(d))
}

///|
/// A corrupt length is refused at the point of reading rather than turned into
/// an allocation. `cautious_capacity` backs this up for formats that cannot
/// check, but a format that can, should.
test "a length prefix larger than the input is refused" {
  let hostile : Bytes = b"\xff\xff\xff\x7f\x01\x02"
  try (bin_from_bytes(hostile) : Array[Int]) catch {
    e => inspect(e, content=(
      #|$: bin: length 2147483647 exceeds the 2 byte(s) remaining
    ))
  } noraise {
    _ => fail("expected a hostile length to be refused")
  }
}

///|
test "trailing input is an error, as it is for JSON" {
  let bytes = b"\x2a\x00\x00\x00\x99"
  try (bin_from_bytes(bytes) : Int) catch {
    e => inspect(e, content=(
      #|$: bin: trailing input after value
    ))
  } noraise {
    _ => fail("expected trailing input to be refused")
  }
}

// `Value` as a format: a `Serializer` that builds one and a `Deserializer`
// that reads one.
//
// This is the reference implementation of both protocols. It is also the
// bridge that makes `Value` usable as an intermediate representation, the way
// `serde_json::Value` is.

///|
/// Builds a `Value` in memory.
///
/// Nested values are serialized by `capture`, which hands each one a fresh
/// serializer. That keeps at most one compound open per instance, so no
/// explicit nesting stack is needed and a misplaced `_element` or `_end` call
/// raises rather than silently corrupting the result.
pub struct ValueSerializer {
  mut out : Value?
  mut items : Array[Value]?
  mut entries : Array[(Value, Value)]?
  mut pending_key : Value?
  mut variant : String?
}

///|
pub fn ValueSerializer::new() -> ValueSerializer {
  { out: None, items: None, entries: None, pending_key: None, variant: None }
}

///|
/// Serializes one value in isolation and returns it.
pub fn[T : Serialize] ValueSerializer::capture(
  value : T,
) -> Value raise SerError {
  let sub = ValueSerializer::new()
  value.serialize(sub)
  sub.finish()
}

///|
/// The completed value. Raises if nothing was serialized, or if a compound was
/// opened and never closed.
pub fn ValueSerializer::finish(self : ValueSerializer) -> Value raise SerError {
  if self.items is Some(_) || self.entries is Some(_) {
    raise SerCustom(message="a compound was opened but never ended")
  }
  match self.out {
    Some(v) => v
    None => raise SerCustom(message="serializer produced no value")
  }
}

///|
fn ValueSerializer::emit(self : ValueSerializer, value : Value) -> Unit {
  self.out = Some(value)
}

///|
fn ValueSerializer::open_seq(self : ValueSerializer, hint : Int?) -> Unit {
  self.items = Some(
    match hint {
      Some(n) => Array::new(capacity=n)
      None => []
    },
  )
}

///|
fn ValueSerializer::seq_items(
  self : ValueSerializer,
) -> Array[Value] raise SerError {
  match self.items {
    Some(items) => items
    None => raise SerCustom(message="element written outside an open sequence")
  }
}

///|
fn ValueSerializer::close_seq(
  self : ValueSerializer,
) -> Array[Value] raise SerError {
  let items = self.seq_items()
  self.items = None
  items
}

///|
fn ValueSerializer::map_entries(
  self : ValueSerializer,
) -> Array[(Value, Value)] raise SerError {
  match self.entries {
    Some(entries) => entries
    None => raise SerCustom(message="entry written outside an open map")
  }
}

///|
fn ValueSerializer::close_map(
  self : ValueSerializer,
) -> Array[(Value, Value)] raise SerError {
  let entries = self.map_entries()
  self.entries = None
  entries
}

///|
fn ValueSerializer::take_variant(
  self : ValueSerializer,
) -> String raise SerError {
  match self.variant {
    Some(name) => {
      self.variant = None
      name
    }
    None => raise SerCustom(message="variant ended without a matching begin")
  }
}

///|
pub impl Serializer for ValueSerializer with fn serialize_unit(self) {
  self.emit(Null)
}

///|
pub impl Serializer for ValueSerializer with fn serialize_bool(self, v) {
  self.emit(Boolean(v))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_byte(self, v) {
  self.emit(UInt(v.to_uint64()))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_int16(self, v) {
  self.emit(Int(v.to_int64()))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_uint16(self, v) {
  self.emit(UInt(v.to_uint64()))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_int(self, v) {
  self.emit(Int(v.to_int64()))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_uint(self, v) {
  self.emit(UInt(v.to_uint64()))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_int64(self, v) {
  self.emit(Int(v))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_uint64(self, v) {
  self.emit(UInt(v))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_float(self, v) {
  self.emit(Double(v.to_double()))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_double(self, v) {
  self.emit(Double(v))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_char(self, v) {
  self.emit(Str(v.to_string()))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_string(self, v) {
  self.emit(Str(v))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_bytes(self, v) {
  self.emit(Bytes(v))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_none(self) {
  self.emit(Null)
}

///|
pub impl Serializer for ValueSerializer with fn serialize_some(self, v) {
  self.emit(ValueSerializer::capture(v))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_unit_variant(
  self,
  info,
) {
  self.emit(Str(info.name))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_newtype_variant(
  self,
  info,
  v,
) {
  self.emit(Map([(Str(info.name), ValueSerializer::capture(v))]))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_seq_begin(self, hint) {
  self.open_seq(hint)
}

///|
pub impl Serializer for ValueSerializer with fn serialize_seq_element(self, v) {
  self.seq_items().push(ValueSerializer::capture(v))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_seq_end(self) {
  let items = self.close_seq()
  self.emit(Seq(items))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_map_begin(self, _hint) {
  self.entries = Some([])
  self.pending_key = None
}

///|
pub impl Serializer for ValueSerializer with fn serialize_map_key(self, k) {
  self.pending_key = Some(ValueSerializer::capture(k))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_map_value(self, v) {
  let key = match self.pending_key {
    Some(k) => k
    None => raise SerCustom(message="map value written without a key")
  }
  self.pending_key = None
  self.map_entries().push((key, ValueSerializer::capture(v)))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_map_end(self) {
  let entries = self.close_map()
  self.emit(Map(entries))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_struct_begin(
  self,
  _name,
  _len,
) {
  self.entries = Some([])
}

///|
pub impl Serializer for ValueSerializer with fn serialize_field(self, name, v) {
  self.map_entries().push((Str(name), ValueSerializer::capture(v)))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_struct_end(self) {
  let entries = self.close_map()
  self.emit(Map(entries))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_tuple_variant_begin(
  self,
  info,
  len,
) {
  self.variant = Some(info.name)
  self.open_seq(Some(len))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_tuple_variant_end(
  self,
) {
  let items = self.close_seq()
  let name = self.take_variant()
  self.emit(Map([(Str(name), Seq(items))]))
}

///|
pub impl Serializer for ValueSerializer with fn serialize_struct_variant_begin(
  self,
  info,
  _len,
) {
  self.variant = Some(info.name)
  self.entries = Some([])
}

///|
pub impl Serializer for ValueSerializer with fn serialize_struct_variant_end(
  self,
) {
  let entries = self.close_map()
  let name = self.take_variant()
  self.emit(Map([(Str(name), Map(entries))]))
}

///|
/// Reads from an in-memory `Value`.
///
/// Each nested value gets a child deserializer carrying its own `Path`, so
/// failures report where in the document they happened.
pub struct ValueDeserializer {
  mut value : Value
  mut path : Path
  mut cursor : Int
}

///|
pub fn ValueDeserializer::new(
  value : Value,
  path? : Path = Root,
) -> ValueDeserializer {
  { value, path, cursor: 0 }
}

///|
fn ValueDeserializer::child(
  self : ValueDeserializer,
  value : Value,
  path : Path,
) -> ValueDeserializer {
  ignore(self)
  { value, path, cursor: 0 }
}

///|
fn[T] ValueDeserializer::mismatch(
  self : ValueDeserializer,
  expected : String,
) -> T raise DeError {
  raise InvalidType(path=self.path, expected~, found=self.value.type_name())
}

///|
fn ValueDeserializer::as_int64(self : ValueDeserializer) -> Int64 raise DeError {
  match self.value {
    Int(i) => i
    UInt(u) => {
      let signed = u.reinterpret_as_int64()
      if signed < 0L {
        raise InvalidValue(
          path=self.path,
          expected="a signed integer",
          found=u.to_string(),
        )
      }
      signed
    }
    _ => self.mismatch("integer")
  }
}

///|
fn ValueDeserializer::int_in_range(
  self : ValueDeserializer,
  lo : Int64,
  hi : Int64,
  what : String,
) -> Int64 raise DeError {
  let i = self.as_int64()
  if i < lo || i > hi {
    raise InvalidValue(path=self.path, expected=what, found=i.to_string())
  }
  i
}

///|
fn ValueDeserializer::as_double(
  self : ValueDeserializer,
) -> Double raise DeError {
  match self.value {
    Double(d) => d
    Int(i) => i.to_double()
    UInt(u) => u.to_double()
    _ => self.mismatch("float")
  }
}

///|
fn ValueDeserializer::seq_items(
  self : ValueDeserializer,
) -> Array[Value] raise DeError {
  guard self.value is Seq(items) else { self.mismatch("sequence") }
  items
}

///|
fn ValueDeserializer::map_entries(
  self : ValueDeserializer,
) -> Array[(Value, Value)] raise DeError {
  guard self.value is Map(entries) else { self.mismatch("map") }
  entries
}

///|
fn known_variant(variants : Array[String], name : String) -> Bool {
  variants.is_empty() || variants.contains(name)
}

///|
pub impl Deserializer for ValueDeserializer with fn path(self) {
  self.path
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_unit(self) {
  guard self.value is Null else { self.mismatch("unit") }
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_bool(self) {
  guard self.value is Boolean(b) else { self.mismatch("boolean") }
  b
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_byte(self) {
  self.int_in_range(0L, 255L, "a byte").to_byte()
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_int16(self) {
  Int16::from_int64(self.int_in_range(-32768L, 32767L, "an int16"))
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_uint16(self) {
  self.int_in_range(0L, 65535L, "a uint16").to_uint16()
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_int(self) {
  self.int_in_range(-2147483648L, 2147483647L, "an int").to_int()
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_uint(self) {
  self.int_in_range(0L, 4294967295L, "a uint").reinterpret_as_uint64().to_uint()
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_int64(self) {
  self.as_int64()
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_uint64(self) {
  match self.value {
    UInt(u) => u
    Int(i) =>
      if i < 0L {
        raise InvalidValue(
          path=self.path,
          expected="an unsigned integer",
          found=i.to_string(),
        )
      } else {
        i.reinterpret_as_uint64()
      }
    _ => self.mismatch("unsigned integer")
  }
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_float(self) {
  Float::from_double(self.as_double())
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_double(self) {
  self.as_double()
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_char(self) {
  guard self.value is Str(s) else { self.mismatch("char") }
  let mut first : Char? = None
  let mut count = 0
  for c in s {
    if count == 0 {
      first = Some(c)
    }
    count = count + 1
  }
  match first {
    Some(c) if count == 1 => c
    _ =>
      raise InvalidValue(path=self.path, expected="a single character", found=s)
  }
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_string(self) {
  guard self.value is Str(s) else { self.mismatch("string") }
  s
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_bytes(self) {
  guard self.value is Bytes(b) else { self.mismatch("byte string") }
  b
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_option(self) {
  if self.value is Null {
    None
  } else {
    Some(Deserialize::deserialize(self))
  }
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_seq_begin(self) {
  let items = self.seq_items()
  self.cursor = 0
  Some(items.length())
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_seq_next(self) {
  let items = self.seq_items()
  if self.cursor >= items.length() {
    return None
  }
  let i = self.cursor
  self.cursor = i + 1
  Some(Deserialize::deserialize(self.child(items[i], self.path.index(i))))
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_map_begin(self) {
  let entries = self.map_entries()
  self.cursor = 0
  Some(entries.length())
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_map_next_key(
  self,
) {
  let entries = self.map_entries()
  if self.cursor >= entries.length() {
    return None
  }
  let entry = entries[self.cursor]
  Some(Deserialize::deserialize(self.child(entry.0, self.path)))
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_map_value(self) {
  let entries = self.map_entries()
  if self.cursor >= entries.length() {
    raise Eof(path=self.path)
  }
  let entry = entries[self.cursor]
  self.cursor = self.cursor + 1
  Deserialize::deserialize(self.child(entry.1, self.path))
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_struct_begin(
  self,
  _name,
  _fields,
) {
  let _ = self.map_entries()
  self.cursor = 0
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_field_name(self) {
  let entries = self.map_entries()
  if self.cursor >= entries.length() {
    return None
  }
  guard entries[self.cursor].0 is Str(name) else {
    raise InvalidType(
      path=self.path,
      expected="a string field name",
      found=entries[self.cursor].0.type_name(),
    )
  }
  Some(name)
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_field_value(
  self,
) {
  let entries = self.map_entries()
  if self.cursor >= entries.length() {
    raise Eof(path=self.path)
  }
  let entry = entries[self.cursor]
  self.cursor = self.cursor + 1
  let name = match entry.0 {
    Str(n) => n
    other => other.to_string()
  }
  Deserialize::deserialize(self.child(entry.1, self.path.key(name)))
}

///|
pub impl Deserializer for ValueDeserializer with fn skip_value(self) {
  self.cursor = self.cursor + 1
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_enum_begin(
  self,
  _name,
  variants,
) {
  match self.value {
    // A unit variant is just its name.
    Str(variant) => {
      guard known_variant(variants, variant) else {
        raise UnknownVariant(path=self.path, variant~, expected=variants)
      }
      self.value = Null
      variant
    }
    // Anything with a payload is externally tagged: { variant: payload }.
    Map([(Str(variant), payload)]) => {
      guard known_variant(variants, variant) else {
        raise UnknownVariant(path=self.path, variant~, expected=variants)
      }
      self.path = self.path.key(variant)
      self.value = payload
      self.cursor = 0
      variant
    }
    _ => self.mismatch("enum")
  }
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_unit_variant(
  self,
) {
  ignore(self)
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_newtype_variant(
  self,
) {
  Deserialize::deserialize(self)
}

///|
pub impl Deserializer for ValueDeserializer with fn deserialize_any(self) {
  self.value
}

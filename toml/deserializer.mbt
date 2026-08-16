// `TomlDeserializer`, matching what `toml::de::Deserializer` is in Rust.
//
// The easier direction. `Deserializer` is a pull protocol, so a format may do
// whatever it likes before the first question arrives — and parsing the whole
// document up front is what `ValueDeserializer` already does. Nothing is bent
// to fit here; TOML simply has to be read whole, because a sub-table may be
// defined before its parent:
//
//   [a.b]
//   x = 1
//
//   [a]
//   y = 2      # `a`'s own key, after the whole [a.b] block
//
// A forward-only reader would have to answer for `a` before it had seen `y`.
// Parsing first makes the question disappear.

///|
/// Reads TOML.
///
/// Unlike `JsonDeserializer::new`, construction parses and so can fail: there
/// is no partial state to hand back.
struct TomlDeserializer {
  inner : @data.ValueDeserializer
}

///|
pub fn TomlDeserializer::new(
  input : Bytes,
) -> TomlDeserializer raise @data.DeError {
  { inner: @data.ValueDeserializer::new(parse(input)) }
}

///|
/// Present for symmetry with the other formats, and trivially satisfied.
///
/// `JsonDeserializer::finish` exists to catch input after the value ends;
/// here the whole document was consumed by `new`, so trailing content was
/// already an error before any value was read.
pub fn TomlDeserializer::finish(_self : TomlDeserializer) -> Unit {

}

// ---- forwarding ----

///|
pub impl @data.Deserializer for TomlDeserializer with fn path(self) {
  @data.Deserializer::path(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_unit(self) {
  @data.Deserializer::deserialize_unit(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_bool(self) {
  @data.Deserializer::deserialize_bool(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_byte(self) {
  @data.Deserializer::deserialize_byte(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_int16(
  self,
) {
  @data.Deserializer::deserialize_int16(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_uint16(
  self,
) {
  @data.Deserializer::deserialize_uint16(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_int(self) {
  @data.Deserializer::deserialize_int(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_uint(self) {
  @data.Deserializer::deserialize_uint(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_int64(
  self,
) {
  @data.Deserializer::deserialize_int64(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_uint64(
  self,
) {
  @data.Deserializer::deserialize_uint64(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_float(
  self,
) {
  @data.Deserializer::deserialize_float(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_double(
  self,
) {
  @data.Deserializer::deserialize_double(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_char(self) {
  @data.Deserializer::deserialize_char(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_string(
  self,
) {
  @data.Deserializer::deserialize_string(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_str_bytes(
  self,
) {
  @data.Deserializer::deserialize_str_bytes(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_bytes(
  self,
) {
  @data.Deserializer::deserialize_bytes(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_option(
  self,
) {
  @data.Deserializer::deserialize_option(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_unit_struct(
  self,
  name,
) {
  @data.Deserializer::deserialize_unit_struct(self.inner, name)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_newtype_struct(
  self,
  name,
) {
  @data.Deserializer::deserialize_newtype_struct(self.inner, name)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_seq_begin(
  self,
) {
  @data.Deserializer::deserialize_seq_begin(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_seq_next(
  self,
) {
  @data.Deserializer::deserialize_seq_next(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_tuple_begin(
  self,
  len,
) {
  @data.Deserializer::deserialize_tuple_begin(self.inner, len)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_tuple_next(
  self,
) {
  @data.Deserializer::deserialize_tuple_next(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_tuple_end(
  self,
) {
  @data.Deserializer::deserialize_tuple_end(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_tuple_struct_begin(
  self,
  name,
  len,
) {
  @data.Deserializer::deserialize_tuple_struct_begin(self.inner, name, len)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_map_begin(
  self,
) {
  @data.Deserializer::deserialize_map_begin(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_map_next_key(
  self,
) {
  @data.Deserializer::deserialize_map_next_key(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_map_value(
  self,
) {
  @data.Deserializer::deserialize_map_value(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_struct_begin(
  self,
  name,
  fields,
) {
  @data.Deserializer::deserialize_struct_begin(self.inner, name, fields)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_field_name(
  self,
) {
  @data.Deserializer::deserialize_field_name(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_field_value(
  self,
) {
  @data.Deserializer::deserialize_field_value(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn skip_value(self) {
  @data.Deserializer::skip_value(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_enum_begin(
  self,
  name,
  variants,
) {
  @data.Deserializer::deserialize_enum_begin(self.inner, name, variants)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_unit_variant(
  self,
) {
  @data.Deserializer::deserialize_unit_variant(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_newtype_variant(
  self,
) {
  @data.Deserializer::deserialize_newtype_variant(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_enum_end(
  self,
) {
  @data.Deserializer::deserialize_enum_end(self.inner)
}

///|
pub impl @data.Deserializer for TomlDeserializer with fn deserialize_any(self) {
  @data.Deserializer::deserialize_any(self.inner)
}

///|
/// Declared rather than inherited, for the same reason as on the writing side.
pub impl @data.Deserializer for TomlDeserializer with fn is_human_readable(
  _self,
) {
  true
}

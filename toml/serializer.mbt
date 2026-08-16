// `TomlSerializer`, matching what `toml::ser::Serializer` is in Rust.
//
// Every method forwards to a `ValueSerializer`, and `finish` renders the tree
// it built. That is not a costume: `ValueSerializer` is itself a first-class
// `Serializer` that accumulates rather than streams, so the trait has never
// required emitting as you go. What TOML adds is that it *cannot* stream —
// within a table every scalar must precede the first sub-table header, and
// `serialize_field` hands over a `T` whose only capability is `Serialize`, so
// the serializer cannot tell a scalar from a table without writing it. The
// classification has to happen after the whole table is in hand.
//
// So this exists for uniformity rather than capability. `to_string` does not
// need it. What it buys is that TOML can be passed wherever a format is
// expected, and that `is_human_readable` is answered on purpose rather than
// inherited from `Value` and happening to be right.

///|
/// Writes TOML.
///
/// Unlike `JsonSerializer`, the output is not available incrementally: nothing
/// is rendered until `finish`.
struct TomlSerializer {
  inner : @data.ValueSerializer
}

///|
pub fn TomlSerializer::new() -> TomlSerializer {
  { inner: @data.ValueSerializer::new() }
}

///|
/// The document written so far. Raises if a container was never closed, or if
/// the value is one TOML cannot spell.
pub fn TomlSerializer::finish(
  self : TomlSerializer,
) -> String raise @data.SerError {
  render(self.inner.finish())
}

// ---- forwarding ----

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_unit(self) {
  @data.Serializer::serialize_unit(self.inner)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_bool(self, v) {
  @data.Serializer::serialize_bool(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_byte(self, v) {
  @data.Serializer::serialize_byte(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_int16(self, v) {
  @data.Serializer::serialize_int16(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_uint16(self, v) {
  @data.Serializer::serialize_uint16(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_int(self, v) {
  @data.Serializer::serialize_int(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_uint(self, v) {
  @data.Serializer::serialize_uint(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_int64(self, v) {
  @data.Serializer::serialize_int64(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_uint64(self, v) {
  @data.Serializer::serialize_uint64(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_float(self, v) {
  @data.Serializer::serialize_float(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_double(self, v) {
  @data.Serializer::serialize_double(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_char(self, v) {
  @data.Serializer::serialize_char(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_string(self, v) {
  @data.Serializer::serialize_string(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_str_bytes(
  self,
  v,
) {
  @data.Serializer::serialize_str_bytes(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_bytes(self, v) {
  @data.Serializer::serialize_bytes(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_none(self) {
  @data.Serializer::serialize_none(self.inner)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_some(self, v) {
  @data.Serializer::serialize_some(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_unit_struct(
  self,
  name,
) {
  @data.Serializer::serialize_unit_struct(self.inner, name)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_newtype_struct(
  self,
  name,
  v,
) {
  @data.Serializer::serialize_newtype_struct(self.inner, name, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_unit_variant(
  self,
  info,
) {
  @data.Serializer::serialize_unit_variant(self.inner, info)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_newtype_variant(
  self,
  info,
  v,
) {
  @data.Serializer::serialize_newtype_variant(self.inner, info, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_seq_begin(
  self,
  hint,
) {
  @data.Serializer::serialize_seq_begin(self.inner, hint)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_seq_element(
  self,
  v,
) {
  @data.Serializer::serialize_seq_element(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_seq_end(self) {
  @data.Serializer::serialize_seq_end(self.inner)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_begin(
  self,
  len,
) {
  @data.Serializer::serialize_tuple_begin(self.inner, len)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_element(
  self,
  v,
) {
  @data.Serializer::serialize_tuple_element(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_end(self) {
  @data.Serializer::serialize_tuple_end(self.inner)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_struct_begin(
  self,
  name,
  len,
) {
  @data.Serializer::serialize_tuple_struct_begin(self.inner, name, len)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_struct_field(
  self,
  v,
) {
  @data.Serializer::serialize_tuple_struct_field(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_struct_end(
  self,
) {
  @data.Serializer::serialize_tuple_struct_end(self.inner)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_map_begin(
  self,
  hint,
) {
  @data.Serializer::serialize_map_begin(self.inner, hint)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_map_key(self, k) {
  @data.Serializer::serialize_map_key(self.inner, k)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_map_value(
  self,
  v,
) {
  @data.Serializer::serialize_map_value(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_map_end(self) {
  @data.Serializer::serialize_map_end(self.inner)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_struct_begin(
  self,
  name,
  len,
) {
  @data.Serializer::serialize_struct_begin(self.inner, name, len)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_field(
  self,
  name,
  v,
) {
  @data.Serializer::serialize_field(self.inner, name, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_struct_end(self) {
  @data.Serializer::serialize_struct_end(self.inner)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_variant_begin(
  self,
  info,
  len,
) {
  @data.Serializer::serialize_tuple_variant_begin(self.inner, info, len)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_variant_element(
  self,
  v,
) {
  @data.Serializer::serialize_tuple_variant_element(self.inner, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_tuple_variant_end(
  self,
) {
  @data.Serializer::serialize_tuple_variant_end(self.inner)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_struct_variant_begin(
  self,
  info,
  len,
) {
  @data.Serializer::serialize_struct_variant_begin(self.inner, info, len)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_struct_variant_field(
  self,
  name,
  v,
) {
  @data.Serializer::serialize_struct_variant_field(self.inner, name, v)
}

///|
pub impl @data.Serializer for TomlSerializer with fn serialize_struct_variant_end(
  self,
) {
  @data.Serializer::serialize_struct_variant_end(self.inner)
}

///|
/// Declared rather than inherited. `ValueSerializer` answers `true` and TOML
/// is human-readable, so forwarding would give the right answer today — but
/// for the wrong reason, and it would follow `Value` if that ever changed.
pub impl @data.Serializer for TomlSerializer with fn is_human_readable(_self) {
  true
}

///|
/// Identifies one variant of an enum within the data model.
///
/// Serde passes `(name, variant_index, variant)` positionally to four separate
/// methods; bundling them keeps the `Serializer` signatures readable and makes
/// it impossible to transpose the two names by accident.
pub(all) struct VariantInfo {
  /// Name of the enum type, e.g. `"Shape"`.
  enum_name : String
  /// Zero-based declaration order of the variant.
  index : Int
  /// Name of the variant itself, e.g. `"Circle"`.
  name : String
}

///|
/// A data type that can describe itself to any `Serializer`.
///
/// This is half of serde's central idea: a type knows its own shape in terms of
/// the data model, and a format knows how to write the data model. Neither
/// knows about the other, so N types and M formats cost N + M implementations
/// instead of N * M.
///
/// `serialize` is polymorphic in the serializer, so this trait has no trait
/// object form — exactly as in Rust. Use `Value` when a heterogeneous
/// collection is needed.
pub(open) trait Serialize {
  fn[S : Serializer] serialize(Self, S) -> Unit raise SerError
}

///|
/// A format that can receive the data model.
///
/// Serde returns a distinct builder type from `serialize_seq`, `serialize_map`
/// and friends, which statically prevents mixing up two open compounds. MoonBit
/// has no associated types, so the compound protocols are flattened onto `Self`
/// as `_begin` / element / `_end` triples. That makes correct nesting a
/// contract rather than a type guarantee: every `_begin` must be matched by
/// exactly one `_end`, and implementations that nest must track their own depth.
///
/// Many methods have defaults that widen to a more general part of the data
/// model — tuples fall back to sequences, tuple structs to tuples — so a format
/// only overrides the ones it represents distinctly.
pub(open) trait Serializer {
  // ---- primitives ----
  fn serialize_unit(Self) -> Unit raise SerError
  fn serialize_bool(Self, Bool) -> Unit raise SerError
  fn serialize_byte(Self, Byte) -> Unit raise SerError
  fn serialize_int16(Self, Int16) -> Unit raise SerError
  fn serialize_uint16(Self, UInt16) -> Unit raise SerError
  fn serialize_int(Self, Int) -> Unit raise SerError
  fn serialize_uint(Self, UInt) -> Unit raise SerError
  fn serialize_int64(Self, Int64) -> Unit raise SerError
  fn serialize_uint64(Self, UInt64) -> Unit raise SerError
  fn serialize_float(Self, Float) -> Unit raise SerError
  fn serialize_double(Self, Double) -> Unit raise SerError
  fn serialize_char(Self, Char) -> Unit raise SerError
  fn serialize_string(Self, String) -> Unit raise SerError
  fn serialize_bytes(Self, Bytes) -> Unit raise SerError

  // ---- option ----
  fn serialize_none(Self) -> Unit raise SerError
  fn[T : Serialize] serialize_some(Self, T) -> Unit raise SerError

  // ---- named units and newtypes ----
  /// A struct with no fields, e.g. `struct Marker`. Defaults to unit.
  fn serialize_unit_struct(Self, String) -> Unit raise SerError = _
  /// A struct wrapping exactly one value, e.g. `struct Meters(Double)`.
  /// Defaults to serializing the inner value transparently.
  fn[T : Serialize] serialize_newtype_struct(Self, String, T) -> Unit raise SerError = _
  fn serialize_unit_variant(Self, VariantInfo) -> Unit raise SerError
  fn[T : Serialize] serialize_newtype_variant(Self, VariantInfo, T) -> Unit raise SerError

  // ---- sequences: length is a hint, absent when not known up front ----
  fn serialize_seq_begin(Self, Int?) -> Unit raise SerError
  fn[T : Serialize] serialize_seq_element(Self, T) -> Unit raise SerError
  fn serialize_seq_end(Self) -> Unit raise SerError

  // ---- tuples: fixed, heterogeneous, length always known ----
  fn serialize_tuple_begin(Self, Int) -> Unit raise SerError = _
  fn[T : Serialize] serialize_tuple_element(Self, T) -> Unit raise SerError = _
  fn serialize_tuple_end(Self) -> Unit raise SerError = _

  // ---- tuple structs, e.g. `struct Rgb(Int, Int, Int)` ----
  fn serialize_tuple_struct_begin(Self, String, Int) -> Unit raise SerError = _
  fn[T : Serialize] serialize_tuple_struct_field(Self, T) -> Unit raise SerError = _
  fn serialize_tuple_struct_end(Self) -> Unit raise SerError = _

  // ---- maps: keys need not be strings ----
  fn serialize_map_begin(Self, Int?) -> Unit raise SerError
  fn[K : Serialize] serialize_map_key(Self, K) -> Unit raise SerError
  fn[V : Serialize] serialize_map_value(Self, V) -> Unit raise SerError
  fn serialize_map_end(Self) -> Unit raise SerError

  // ---- structs: like a map, but keys are known statically ----
  fn serialize_struct_begin(Self, String, Int) -> Unit raise SerError
  fn[T : Serialize] serialize_field(Self, String, T) -> Unit raise SerError
  fn serialize_struct_end(Self) -> Unit raise SerError

  // ---- enum variants carrying payloads ----
  fn serialize_tuple_variant_begin(Self, VariantInfo, Int) -> Unit raise SerError
  fn[T : Serialize] serialize_tuple_variant_element(Self, T) -> Unit raise SerError = _
  fn serialize_tuple_variant_end(Self) -> Unit raise SerError
  fn serialize_struct_variant_begin(Self, VariantInfo, Int) -> Unit raise SerError
  fn[T : Serialize] serialize_struct_variant_field(Self, String, T) -> Unit raise SerError = _
  fn serialize_struct_variant_end(Self) -> Unit raise SerError

  /// Whether the target format is meant to be read by people.
  ///
  /// Types use this to choose between a readable and a compact encoding of the
  /// same value — an IP address as `"127.0.0.1"` for JSON, as four bytes for a
  /// binary format. Defaults to `true`.
  fn is_human_readable(Self) -> Bool = _
}

///|
impl Serializer with fn serialize_unit_struct(self, _name) {
  self.serialize_unit()
}

///|
impl Serializer with fn serialize_newtype_struct(self, _name, value) {
  value.serialize(self)
}

///|
impl Serializer with fn serialize_tuple_begin(self, len) {
  self.serialize_seq_begin(Some(len))
}

///|
impl Serializer with fn serialize_tuple_element(self, value) {
  self.serialize_seq_element(value)
}

///|
impl Serializer with fn serialize_tuple_end(self) {
  self.serialize_seq_end()
}

///|
impl Serializer with fn serialize_tuple_struct_begin(self, _name, len) {
  self.serialize_tuple_begin(len)
}

///|
impl Serializer with fn serialize_tuple_struct_field(self, value) {
  self.serialize_tuple_element(value)
}

///|
impl Serializer with fn serialize_tuple_struct_end(self) {
  self.serialize_tuple_end()
}

///|
impl Serializer with fn serialize_tuple_variant_element(self, value) {
  self.serialize_seq_element(value)
}

///|
impl Serializer with fn serialize_struct_variant_field(self, name, value) {
  self.serialize_field(name, value)
}

///|
impl Serializer with fn is_human_readable(_self) {
  true
}

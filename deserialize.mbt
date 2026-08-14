///|
/// A data type that can be reconstructed from any `Deserializer`.
///
/// The mirror of `Serialize`. Note there is no `self` parameter: the type is
/// produced, not consumed, so this is invoked as `T::deserialize(d)` or through
/// a `[T : Deserialize]` bound.
///
/// Serde routes this through a `Visitor` because `DeserializeSeed` has to
/// thread state through a generic callback. Here the recursion lives in the
/// type parameter of `deserialize_seq_next` and friends, so the deserializer
/// calls `T::deserialize` directly and no visitor is needed.
pub(open) trait Deserialize {
  fn[D : Deserializer] deserialize(D) -> Self raise DeError
}

///|
/// A format that can produce the data model.
///
/// The methods are *hints*, not commands: the type says what shape it expects
/// and a self-describing format is free to check that against what it actually
/// found. A non-self-describing format has no choice but to trust the hint,
/// which is exactly why the hints exist.
///
/// Compound protocols are flattened onto `Self` for the same reason as in
/// `Serializer`. Iteration terminates on `None` rather than an explicit `_end`,
/// so a well-formed read of a sequence, map or struct drains it fully.
pub(open) trait Deserializer {
  /// Where the deserializer currently is, for error reporting.
  fn path(Self) -> Path

  // ---- primitives ----
  fn deserialize_unit(Self) -> Unit raise DeError
  fn deserialize_bool(Self) -> Bool raise DeError
  fn deserialize_byte(Self) -> Byte raise DeError
  fn deserialize_int16(Self) -> Int16 raise DeError
  fn deserialize_uint16(Self) -> UInt16 raise DeError
  fn deserialize_int(Self) -> Int raise DeError
  fn deserialize_uint(Self) -> UInt raise DeError
  fn deserialize_int64(Self) -> Int64 raise DeError
  fn deserialize_uint64(Self) -> UInt64 raise DeError
  fn deserialize_float(Self) -> Float raise DeError
  fn deserialize_double(Self) -> Double raise DeError
  fn deserialize_char(Self) -> Char raise DeError
  fn deserialize_string(Self) -> String raise DeError
  fn deserialize_bytes(Self) -> Bytes raise DeError

  // ---- option ----
  fn[T : Deserialize] deserialize_option(Self) -> T? raise DeError

  // ---- named units and newtypes ----
  fn deserialize_unit_struct(Self, String) -> Unit raise DeError = _
  fn[T : Deserialize] deserialize_newtype_struct(Self, String) -> T raise DeError = _

  // ---- sequences: `None` from `next` terminates ----
  fn deserialize_seq_begin(Self) -> Int? raise DeError
  fn[T : Deserialize] deserialize_seq_next(Self) -> T? raise DeError

  // ---- tuples: length known, so reads are unconditional ----
  fn deserialize_tuple_begin(Self, Int) -> Unit raise DeError = _
  fn[T : Deserialize] deserialize_tuple_next(Self) -> T raise DeError = _
  /// Leaves a tuple.
  ///
  /// Unlike a sequence, a tuple is read a known number of times and so never
  /// observes its own end — nothing else will consume a closing delimiter.
  /// Any format that writes one **must** override this, along with
  /// `deserialize_tuple_begin` and `deserialize_tuple_next`; the defaults route
  /// through the sequence protocol, which is only correct for formats holding
  /// the whole value in memory.
  fn deserialize_tuple_end(Self) -> Unit raise DeError = _
  fn deserialize_tuple_struct_begin(Self, String, Int) -> Unit raise DeError = _

  // ---- maps ----
  fn deserialize_map_begin(Self) -> Int? raise DeError
  fn[K : Deserialize] deserialize_map_next_key(Self) -> K? raise DeError
  fn[V : Deserialize] deserialize_map_value(Self) -> V raise DeError

  // ---- structs: `fields` lists the names the type knows about ----
  fn deserialize_struct_begin(Self, String, Array[String]) -> Unit raise DeError
  fn deserialize_field_name(Self) -> String? raise DeError
  fn[T : Deserialize] deserialize_field_value(Self) -> T raise DeError
  /// Discards the current field's value, for tolerating unknown fields.
  fn skip_value(Self) -> Unit raise DeError

  // ---- enums ----
  /// Enters an enum and returns the variant name. The payload is then read
  /// with the ordinary unit / newtype / tuple / struct protocols, and the
  /// whole thing closed with `deserialize_enum_end`.
  fn deserialize_enum_begin(Self, String, Array[String]) -> String raise DeError
  fn deserialize_unit_variant(Self) -> Unit raise DeError
  fn[T : Deserialize] deserialize_newtype_variant(Self) -> T raise DeError
  /// Leaves an enum, consuming whatever wrapper the tagging scheme used.
  ///
  /// Serde's `VariantAccess` consumes the variant by construction. The
  /// flattened protocol cannot, so every `deserialize_enum_begin` must be
  /// matched by exactly one of these — including on the unit-variant path,
  /// where a format may still have a delimiter to close. Defaults to nothing,
  /// which is correct for formats that hold the whole value in memory.
  fn deserialize_enum_end(Self) -> Unit raise DeError = _

  /// Reads whatever is present without a type hint.
  ///
  /// Only self-describing formats can implement this; the rest should raise
  /// `DeCustom`. It is what makes `Value` and untagged enums possible.
  fn deserialize_any(Self) -> Value raise DeError
  fn is_human_readable(Self) -> Bool = _
}

///|
impl Deserializer with fn deserialize_unit_struct(self, _name) {
  self.deserialize_unit()
}

///|
impl Deserializer with fn deserialize_newtype_struct(self, _name) {
  Deserialize::deserialize(self)
}

///|
impl Deserializer with fn deserialize_tuple_begin(self, _len) {
  let _ = self.deserialize_seq_begin()
}

///|
impl Deserializer with fn deserialize_tuple_next(self) {
  match self.deserialize_seq_next() {
    Some(v) => v
    None => raise Eof(path=self.path())
  }
}

///|
impl Deserializer with fn deserialize_tuple_end(_self) {

}

///|
impl Deserializer with fn deserialize_tuple_struct_begin(self, _name, len) {
  self.deserialize_tuple_begin(len)
}

///|
impl Deserializer with fn is_human_readable(_self) {
  true
}

///|
impl Deserializer with fn deserialize_enum_end(_self) {

}

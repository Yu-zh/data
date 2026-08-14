// JSON, as a format for the `Yu-zh/data` data model.
//
// This is the package that proves the abstraction: `JsonSerializer` and
// `JsonDeserializer` know nothing about any particular type, and every
// `Serialize` / `Deserialize` implementation written against the core package
// works here without modification.
//
// The transport is UTF-8 `Bytes`, which is what JSON actually is on disk and
// on the wire. `to_string` / `from_string` are thin conveniences over that for
// when a `String` is what you have — the same split `serde_json` makes between
// `to_vec` / `from_slice` and `to_string` / `from_str`.
//
// Where JSON is narrower than the data model, it follows `serde_json`:
//
//   bytes           an array of numbers, since JSON has no byte string
//   char            a one-character string
//   tuples          arrays, since JSON has no fixed-length sequence
//   unit, unit      struct  null
//   newtype struct  its inner value, transparently
//   enums           externally tagged: `"Unit"` or `{"Variant": payload}`
//   object keys     always strings; a numeric key type is written and read
//                   through its string spelling
//
// Two places where it deliberately does not follow `serde_json`: NaN and
// infinity raise `UnsupportedType` rather than silently becoming `null`, and a
// non-string, non-numeric map key raises rather than being coerced.

///|
/// Serializes any value to compact JSON, as UTF-8 bytes.
pub fn[T : @data.Serialize] to_bytes(value : T) -> Bytes raise @data.SerError {
  let serializer = JsonSerializer::new()
  value.serialize(serializer)
  serializer.finish()
}

///|
/// Parses UTF-8 JSON bytes into any deserializable type.
///
/// Raises if the input has trailing content after the value, so a truncated or
/// doubled document is an error rather than a silently accepted prefix.
pub fn[T : @data.Deserialize] from_bytes(
  input : Bytes,
) -> T raise @data.DeError {
  let deserializer = JsonDeserializer::new(input)
  let value = @data.Deserialize::deserialize(deserializer)
  deserializer.finish()
  value
}

///|
/// `to_bytes`, decoded. Convenient for tests, logs and anywhere a `String` is
/// wanted; it costs one UTF-8 decode of the whole document.
pub fn[T : @data.Serialize] to_string(value : T) -> String raise @data.SerError {
  // Decoding cannot fail: these are bytes this package just produced.
  @utf8.decode_lossy(to_bytes(value))
}

///|
/// `from_bytes`, encoded. Costs one UTF-8 encode of the whole document.
pub fn[T : @data.Deserialize] from_string(
  text : String,
) -> T raise @data.DeError {
  from_bytes(@utf8.encode(text))
}

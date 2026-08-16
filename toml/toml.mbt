// TOML, as a format for the `Yu-zh/data` data model.
//
// The transport is UTF-8 `Bytes`, as it is for JSON: that is what a TOML file
// is on disk. `to_string` / `from_string` are thin conveniences over that.
//
// The one format here that cannot stream. Within a table every scalar key must
// precede the first sub-table header, because a header switches which table
// subsequent keys belong to — so a struct `{ a, sub, b }` emits `a`, `b`, then
// `[sub]`, and field order is not emission order. Worse, `serialize_field`
// hands over a `T` whose only capability is `Serialize`: the serializer cannot
// tell a scalar from a table without writing it, so classification cannot
// happen until the whole table is in hand.
//
// That does not put the traits out of reach, because they never required
// emitting as you go — `ValueSerializer` accumulates into a tree and hands it
// over at `finish`, and is a first-class `Serializer` for doing so. `toml-rs`
// reached the same conclusion the long way round: it streamed at first and
// raised `ValueAfterTable` ("values must be emitted before tables") on any
// struct whose fields were declared in an order TOML could not express, which
// pushed the constraint out into users' type definitions. Since 0.6 it builds
// a document internally instead.
//
// So `TomlSerializer` and `TomlDeserializer` are backed by `ValueSerializer`
// and `ValueDeserializer`, matching `toml::ser::Serializer` and
// `toml::de::Deserializer` in Rust. Reading is the easier direction: a pull
// protocol lets a format parse whatever it likes before the first question, so
// nothing is bent to fit — which matters, because a TOML sub-table may be
// defined before its parent and a forward-only reader could not cope.
//
// What TOML cannot represent, and what happens:
//
//   null              a table key with no value is omitted entirely; a null
//                     inside an array or inline table raises, since TOML has
//                     no way to spell a hole
//   byte strings      raises `UnsupportedType`; TOML has no byte type and
//                     inventing a hex convention would be a guess
//   non-string keys   raises; TOML table keys are strings
//   a non-table root  raises; a TOML document is a table, so `to_string(42)`
//                     has nowhere to put the 42
//
// Going the other way, datetimes are the one common TOML type with no
// counterpart in `Value`. They are refused with a clear message rather than
// coerced into a string, which would round-trip into something that is no
// longer a datetime.
//
// Infinity and NaN, unusually, survive: TOML spells them `inf`, `-inf` and
// `nan`, so unlike JSON this format does not have to raise on them.

///|
/// Serializes any value to a TOML document, as UTF-8 bytes.
///
/// The value must be a struct or map at the top level, because a TOML document
/// is a table.
pub fn[T : @data.Serialize] to_bytes(value : T) -> Bytes raise @data.SerError {
  let serializer = TomlSerializer::new()
  value.serialize(serializer)
  serializer.finish()
}

///|
/// Parses UTF-8 TOML bytes into any deserializable type.
pub fn[T : @data.Deserialize] from_bytes(
  input : Bytes,
) -> T raise @data.DeError {
  let deserializer = TomlDeserializer::new(input)
  let value = @data.Deserialize::deserialize(deserializer)
  deserializer.finish()
  value
}

///|
/// `to_bytes`, decoded. Convenient for tests and anywhere a `String` is
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

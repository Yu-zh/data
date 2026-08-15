// TOML, as a format for the `Yu-zh/data` data model.
//
// The odd one out, and the first that does not implement `Serializer` or
// `Deserializer` at all. That is not a shortcut — it is what TOML is.
//
// A TOML document cannot be written in one pass. Within a table, every scalar
// key must appear before any sub-table header, so field order is not emission
// order: a struct `{ a, sub, b }` has to emit `a`, `b`, then `[sub]`. A
// streaming `Serializer` receives `serialize_field` calls in declaration order
// with no way to look ahead, so it would have to buffer the whole document and
// reorder at `finish` — at which point it is a `Value` builder wearing a trait.
//
// So TOML goes through `Value` directly. `@data.to_value` already produces the
// tree, and `@data.from_value` already consumes one, so this package is a text
// codec for the data model rather than a protocol over it. Any type with
// `Serialize` and `Deserialize` still works, which is the only thing a caller
// cares about.
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
/// Serializes any value to a TOML document.
///
/// The value must be a struct or map at the top level, because a TOML document
/// is a table.
pub fn[T : @data.Serialize] to_string(
  value : T,
) -> String raise @data.SerError {
  render(@data.to_value(value))
}

///|
/// Parses a TOML document into any deserializable type.
pub fn[T : @data.Deserialize] from_string(
  text : String,
) -> T raise @data.DeError {
  @data.from_value(parse(text))
}

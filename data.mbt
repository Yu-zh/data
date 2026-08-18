// A serde-shaped serialization framework for MoonBit.
//
// The central idea is serde's: a data type describes itself in terms of a
// fixed *data model*, and a format knows how to read or write that data model.
// Neither knows about the other, so N types and M formats cost N + M
// implementations rather than N * M.
//
//   Serialize    — a type describing itself to any Serializer
//   Serializer   — a format receiving the data model
//   Deserialize  — a type reconstructing itself from any Deserializer
//   Deserializer — a format producing the data model
//   Value        — the data model made concrete, for self-describing use
//
// Two things differ from Rust's serde, both because MoonBit has no associated
// types. Serde's `Serializer` returns a distinct builder type from
// `serialize_seq` and friends; here the compound protocols are flattened onto
// `Self` as `_begin` / element / `_end` triples, so correct nesting is a
// contract rather than a type guarantee. And serde's `Error` associated type
// becomes the concrete `SerError` / `DeError` suberrors.
//
// Serde's `Visitor` has no counterpart at all: because trait methods may carry
// their own type parameters, `deserialize_seq_next` can be generic in the
// element type and call `T::deserialize` directly, which is the job the
// visitor and `DeserializeSeed` exist to do in Rust.

///|
/// Serializes any value into a `Value`.
pub fn[T : Serialize] to_value(value : T) -> Value raise SerError {
  ValueSerializer::capture(value)
}

///|
/// Reconstructs a value from a `Value`.
pub fn[T : Deserialize] from_value(value : Value) -> T raise DeError {
  Deserialize::deserialize(ValueDeserializer::new(value))
}

///|
/// Raises `MissingField` when a struct field was never seen.
///
/// Hand-written `Deserialize` implementations accumulate fields into options
/// and finish by unwrapping them through this.
pub fn[T] required(field : T?, name~ : String, path~ : Path) -> T raise DeError {
  match field {
    Some(v) => v
    None => raise MissingField(path~, field=name)
  }
}

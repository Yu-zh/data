// CBOR (RFC 8949), as a format for the `Yu-zh/data` data model.
//
// The second self-describing format, and the one that fits the data model most
// closely. Three things JSON has to fake, CBOR carries natively:
//
//   bytes           a byte string, not an array of numbers
//   map keys        any value, not only strings
//   integer widths  unsigned and negative integers are distinct major types,
//                   and a double is never confused with an integer
//
// Where it follows `serde_cbor`:
//
//   unit, unit struct  null
//   char               a one-character text string
//   tuples             arrays, since CBOR has no fixed-length sequence
//   newtype struct     its inner value, transparently
//   structs            maps with text keys
//   enums              externally tagged: `"Unit"` or `{"Variant": payload}`
//
// Two deliberate choices of its own:
//
// Writing is definite-length wherever a length is known, and integers use the
// shortest head that fits. That is not full canonical CBOR — map keys are
// written in declaration order rather than sorted — but it is deterministic
// for a given value, which is what round-trip tests need.
//
// Reading accepts what writing does not produce: indefinite-length arrays,
// maps and strings, half-precision floats, and semantic tags. Tags are read
// and discarded, so a tagged value decodes as its content. That is lossy and
// deliberate: `Value` has no case for a tag, and refusing them outright would
// reject ordinary documents from encoders that date their timestamps.

///|
/// Serializes any value to CBOR.
pub fn[T : @data.Serialize] to_bytes(value : T) -> Bytes raise @data.SerError {
  let serializer = CborSerializer::new()
  value.serialize(serializer)
  serializer.finish()
}

///|
/// Parses CBOR into any deserializable type.
///
/// Raises if the input has trailing content after the value, matching
/// `@json.from_bytes`.
pub fn[T : @data.Deserialize] from_bytes(
  input : Bytes,
) -> T raise @data.DeError {
  let deserializer = CborDeserializer::new(input)
  let value = @data.Deserialize::deserialize(deserializer)
  deserializer.finish()
  value
}

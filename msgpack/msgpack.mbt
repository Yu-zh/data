// MessagePack, as a format for the `Yu-zh/data` data model.
//
// The third format, and the closest sibling to CBOR: self-describing, binary,
// big-endian, with a byte string and non-string map keys as first-class
// members of the data model. The differences that matter here are two.
//
// Every length is explicit. MessagePack has no indefinite-length container, so
// `serialize_seq_begin(None)` cannot be honoured and raises. CBOR can spell
// that case; JSON does not need to, because it never knows a length up front.
// Three formats, three different answers to the same `Int?`.
//
// Extension types are refused rather than skipped. A CBOR tag wraps a value
// that can be decoded on its own, so dropping the tag leaves something
// meaningful; a MessagePack ext is a type byte and an opaque payload with no
// inner value to fall back to, and `Value` has no case for one.
//
// Where it follows `rmp-serde`:
//
//   unit, unit struct  nil
//   char               a one-character string
//   tuples             arrays, since there is no fixed-length sequence
//   newtype struct     its inner value, transparently
//   structs            maps with string keys
//   enums              externally tagged: `"Unit"` or `{"Variant": payload}`

///|
/// Serializes any value to MessagePack.
pub fn[T : @data.Serialize] to_bytes(value : T) -> Bytes raise @data.SerError {
  let serializer = MsgpackSerializer::new()
  value.serialize(serializer)
  serializer.finish()
}

///|
/// Parses MessagePack into any deserializable type.
///
/// Raises if the input has trailing content after the value, matching
/// `@json.from_bytes` and `@cbor.from_bytes`.
pub fn[T : @data.Deserialize] from_bytes(
  input : Bytes,
) -> T raise @data.DeError {
  let deserializer = MsgpackDeserializer::new(input)
  let value = @data.Deserialize::deserialize(deserializer)
  deserializer.finish()
  value
}

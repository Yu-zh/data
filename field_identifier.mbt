///|
/// A struct field identifier interpreted by the type being deserialized.
///
/// Derived implementations use a private enum with one case per known field
/// plus an unknown case. The representation stays entirely with the type:
/// formats supply whichever identifier representation they already have, and
/// receive a semantic value rather than a numeric field position.
///
/// `from_bytes` receives an `index_hint` because object keys commonly arrive
/// in declaration order. Implementations may try that field first before
/// falling back to their general lookup; the hint must not change the result.
/// `from_index` uses the order of the names passed to
/// `deserialize_struct_begin`, which supports positional binary formats.
/// `name` returns a canonical known name for error paths; unknown identifiers
/// return `None` so the format can retain the input name.
///
/// Implementations must keep these representations consistent. If `name`
/// returns `Some(canonical)` for a value produced by `from_bytes`, those bytes
/// must be exactly the UTF-8 encoding of `canonical`; a value produced by
/// `from_string` must likewise have matched that string. Byte-oriented formats
/// rely on this invariant to reuse `canonical` without decoding the input.
pub(open) trait FieldIdentifier {
  fn from_index(Int) -> Self
  fn from_bytes(BytesView, index_hint : Int) -> Self
  fn from_string(String) -> Self
  fn name(Self) -> String?
}

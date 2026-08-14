// Byte classification, shared by the writer and the reader.
//
// A JSON string is delimited by `"`, escaped by `\`, and may not contain a
// raw byte below 0x20. Those are the same three classes whether text is being
// written or read, so both directions share one classifier — and a
// whole-document stage-1 scan needs the same one over blocks rather than over
// a single string, which is why it lives here rather than inside either loop.

///|
/// The bytes a JSON string must escape: `"`, `\` and anything below 0x20.
/// Every byte of a multi-byte UTF-8 sequence is >= 0x80, so text passes
/// through without ever being examined as characters.
let quote_byte : V128 = @v128.i8x16_splat(b'"')

///|
let backslash_byte : V128 = @v128.i8x16_splat(b'\\')

///|
let first_printable : V128 = @v128.i8x16_splat(b' ')

///|
/// Classifies sixteen bytes at once, returning one bit per byte for those
/// needing an escape, so the next interesting position is a `ctz` away.
///
/// This is the classification step of simdjson's `copy_and_find`. It is
/// deliberately separate from the write loop below: a whole-document stage-1
/// scan needs exactly this, over blocks rather than over one string, and
/// should reuse it rather than restate it.
fn escape_mask(chunk : V128) -> Int {
  @v128.i8x16_bitmask(
    @v128.v128_or_(
      @v128.v128_or_(
        @v128.i8x16_eq(chunk, quote_byte),
        @v128.i8x16_eq(chunk, backslash_byte),
      ),
      @v128.i8x16_lt_u(chunk, first_printable),
    ),
  )
}

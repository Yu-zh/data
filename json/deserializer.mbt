///|
/// Mutable path state used by the streaming reader.
///
/// At each depth, a non-negative value in `indices` is a sequence index;
/// `-1` means the corresponding entry in `keys` is a struct field or map key.
/// Slots are reused and `depth` selects the active prefix, so advancing through
/// successful input does not allocate or resize once the maximum nesting depth
/// seen so far has been reached.
priv struct PathTracker {
  indices : Array[Int]
  keys : Array[String]
  mut depth : Int
}

///|
fn PathTracker::new() -> PathTracker {
  { indices: [], keys: [], depth: 0 }
}

///|
fn PathTracker::materialize(self : PathTracker) -> @data.Path {
  for i in 0..<self.depth; current = @data.Root {
    let index = self.indices[i]
    continue if index < 0 {
        current.key(self.keys[i])
      } else {
        current.index(index)
      }
  } nobreak {
    current
  }
}

///|
fn PathTracker::set_key(
  self : PathTracker,
  base_depth : Int,
  name : String,
) -> Unit {
  if base_depth < self.indices.length() {
    self.indices[base_depth] = -1
    self.keys[base_depth] = name
  } else {
    self.indices.push(-1)
    self.keys.push(name)
  }
  self.depth = base_depth + 1
}

///|
fn PathTracker::set_index(
  self : PathTracker,
  base_depth : Int,
  index : Int,
) -> Unit {
  if base_depth < self.indices.length() {
    self.indices[base_depth] = index
  } else {
    self.indices.push(index)
    self.keys.push("")
  }
  self.depth = base_depth + 1
}

///|
/// One open `[` or `{`, remembering the path to restore on the way out and how
/// many items have been read so far (which is what decides whether the next
/// item needs a leading comma).
priv struct Scope {
  base_depth : Int
  mut count : Int
  /// The field names the caller declared for this struct, empty for arrays
  /// and maps. Known raw keys reuse these canonical strings for paths.
  expected : ReadOnlyArray[String]
}

///|
/// One open enum. `wrapped` records whether it was written as
/// `{"Variant": payload}`, which has a `}` to consume, or as a bare
/// `"Variant"` string, which does not.
priv struct EnumScope {
  wrapped : Bool
  base_depth : Int
}

///|
/// Reads JSON from UTF-8 bytes.
///
/// A streaming parser, so lengths are never known in advance and
/// `deserialize_seq_begin` returns `None`. Iteration is driven by the type
/// being built, exactly as serde intends: the parser never decides what shape
/// the input has until asked.
struct JsonDeserializer {
  input : Bytes
  mut pos : Int
  path : PathTracker
  scopes : Array[Scope]
  enums : Array[EnumScope]
  /// Set on the throwaway deserializer used to read an object key: the
  /// already-decoded, already-unescaped key text. JSON keys are always
  /// strings, but the key *type* may be a number, so the token has to be
  /// re-read through whatever `Deserialize` the map's key type provides.
  /// Holding the text avoids re-encoding it just to parse it again.
  bare : BytesView?
}

///|
pub fn JsonDeserializer::new(input : Bytes) -> JsonDeserializer {
  { input, pos: 0, path: PathTracker::new(), scopes: [], enums: [], bare: None }
}

///|
/// Builds the public, persistent representation only for callers that need
/// to observe the path. The success path never calls this method.
#inline(never)
fn JsonDeserializer::current_path(self : JsonDeserializer) -> @data.Path {
  self.path.materialize()
}

///|
/// Cold error helpers keep path materialisation and error-object construction
/// out of the parser's successful machine-code paths.
#inline(never)
fn JsonDeserializer::eof_error(self : JsonDeserializer) -> @data.DeError {
  @data.Eof(path=self.current_path())
}

///|
#inline(never)
fn JsonDeserializer::custom_error(
  self : JsonDeserializer,
  message : String,
) -> @data.DeError {
  @data.DeCustom(path=self.current_path(), message~)
}

///|
#inline(never)
fn JsonDeserializer::invalid_value_error(
  self : JsonDeserializer,
  expected : String,
  found : String,
) -> @data.DeError {
  @data.InvalidValue(path=self.current_path(), expected~, found~)
}

///|
#inline(never)
fn JsonDeserializer::unknown_variant_error(
  self : JsonDeserializer,
  variant : String,
  expected : ReadOnlyArray[String],
) -> @data.DeError {
  @data.UnknownVariant(path=self.current_path(), variant~, expected~)
}

///|
fn JsonDeserializer::set_key(
  self : JsonDeserializer,
  base_depth : Int,
  name : String,
) -> Unit {
  self.path.set_key(base_depth, name)
}

///|
fn JsonDeserializer::set_index(
  self : JsonDeserializer,
  base_depth : Int,
  index : Int,
) -> Unit {
  self.path.set_index(base_depth, index)
}

///|
/// Checks that the whole input was consumed.
pub fn JsonDeserializer::finish(
  self : JsonDeserializer,
) -> Unit raise @data.DeError {
  self.skip_ws()
  if self.pos < self.input.length() {
    raise self.custom_error("trailing input after value")
  }
}

///|
fn JsonDeserializer::key_reader(
  self : JsonDeserializer,
  text : BytesView,
) -> JsonDeserializer {
  {
    input: b"",
    pos: 0,
    // The reader is consumed synchronously and successful bare-key decoding
    // cannot advance a container, so sharing the tracker is an immutable
    // snapshot for the duration of this call.
    path: self.path,
    scopes: [],
    enums: [],
    bare: Some(text),
  }
}

// ---- scanning ----

///|
/// The byte at `i`, widened for comparison against the ASCII structural
/// characters JSON is made of. Multi-byte UTF-8 sequences only ever appear
/// inside string literals, where `decode_chunk` handles them.
fn JsonDeserializer::code(self : JsonDeserializer, i : Int) -> Int {
  self.input[i].to_int()
}

///|
fn JsonDeserializer::at_end(self : JsonDeserializer) -> Bool {
  self.pos >= self.input.length()
}

///|
fn JsonDeserializer::skip_ws(self : JsonDeserializer) -> Unit {
  while self.pos < self.input.length() {
    let c = self.code(self.pos)
    if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      self.pos = self.pos + 1
    } else {
      break
    }
  }
}

///|
fn JsonDeserializer::peek_or_end(self : JsonDeserializer) -> Int {
  self.skip_ws()
  if self.at_end() {
    -1
  } else {
    self.code(self.pos)
  }
}

///|
fn JsonDeserializer::peek(self : JsonDeserializer) -> Int raise @data.DeError {
  let token = self.peek_or_end()
  if token < 0 {
    raise self.eof_error()
  }
  token
}

///|
fn describe(c : Int) -> String {
  match Int::to_char(c) {
    Some(ch) => ch.to_string()
    None => "U+" + c.to_string(radix=16)
  }
}

///|
/// Names the shape of whatever is at the cursor, in the same vocabulary
/// `Value::type_name` uses, so `InvalidType` messages read the same whichever
/// format produced them.
fn JsonDeserializer::found(self : JsonDeserializer) -> String {
  self.skip_ws()
  if self.at_end() {
    return "end of input"
  }
  match self.code(self.pos) {
    0x22 => "string"
    0x7B => "map"
    0x5B => "sequence"
    0x74 | 0x66 => "boolean"
    0x6E => "unit"
    0x5D => "end of sequence"
    0x7D => "end of map"
    _ => "a number"
  }
}

///|
fn JsonDeserializer::try_expect(self : JsonDeserializer, ch : Char) -> Bool {
  if self.peek_or_end() != ch.to_int() {
    return false
  }
  self.pos = self.pos + 1
  true
}

///|
fn JsonDeserializer::expect(
  self : JsonDeserializer,
  ch : Char,
) -> Unit raise @data.DeError {
  if self.try_expect(ch) {
    return
  }
  let c = self.peek()
  raise self.custom_error("expected `\{ch}`, found `\{describe(c)}`")
}

///|
fn JsonDeserializer::eat(self : JsonDeserializer, literal : String) -> Bool {
  self.skip_ws()
  if self.pos + literal.length() > self.input.length() {
    return false
  }
  for i in 0..<literal.length() {
    if self.code(self.pos + i) != literal[i].to_int() {
      return false
    }
  }
  self.pos = self.pos + literal.length()
  true
}

///|
/// A token that begins like `true` / `false` / `null` but does not finish that
/// way is a malformed literal, not a value of some other type. Saying so beats
/// "expected unit, found unit".
#inline(never)
fn[T] JsonDeserializer::bad_literal(
  self : JsonDeserializer,
  expected : String,
) -> T raise @data.DeError {
  raise self.custom_error("invalid literal, expected `\{expected}`")
}

///|
#inline(never)
fn[T] JsonDeserializer::mismatch(
  self : JsonDeserializer,
  expected : String,
) -> T raise @data.DeError {
  raise @data.InvalidType(
    path=self.current_path(),
    expected~,
    found=self.found(),
  )
}

// ---- strings ----

///|
fn JsonDeserializer::hex4(self : JsonDeserializer) -> Int raise @data.DeError {
  if self.pos + 4 > self.input.length() {
    raise self.eof_error()
  }
  let mut value = 0
  for i in 0..<4 {
    let c = self.code(self.pos + i)
    let digit = if c >= 0x30 && c <= 0x39 {
      c - 0x30
    } else if c >= 0x61 && c <= 0x66 {
      c - 0x61 + 10
    } else if c >= 0x41 && c <= 0x46 {
      c - 0x41 + 10
    } else {
      raise self.custom_error(
        "invalid `\\u` escape: `\{describe(c)}` is not a hex digit",
      )
    }
    value = value * 16 + digit
  }
  self.pos = self.pos + 4
  value
}

///|
/// Consumes a literal `\u` without skipping whitespace, for the second half of
/// a surrogate pair where nothing may intervene.
fn JsonDeserializer::eat_u_escape(self : JsonDeserializer) -> Bool {
  if self.pos + 1 >= self.input.length() {
    return false
  }
  if self.code(self.pos) != 0x5C || self.code(self.pos + 1) != 0x75 {
    return false
  }
  self.pos = self.pos + 2
  true
}

///|
fn JsonDeserializer::decode_escape(
  self : JsonDeserializer,
  out : @buffer.Buffer,
) -> Unit raise @data.DeError {
  if self.at_end() {
    raise self.eof_error()
  }
  let e = self.code(self.pos)
  self.pos = self.pos + 1
  match e {
    0x22 => out.write_byte(b'"')
    0x5C => out.write_byte(b'\\')
    0x2F => out.write_byte(b'/')
    0x62 => out.write_byte(b'\x08')
    0x66 => out.write_byte(b'\x0C')
    0x6E => out.write_byte(b'\n')
    0x72 => out.write_byte(b'\r')
    0x74 => out.write_byte(b'\t')
    0x75 => {
      let hi = self.hex4()
      if hi >= 0xD800 && hi <= 0xDBFF {
        guard self.eat_u_escape() else {
          raise self.custom_error(
            "high surrogate escape is not followed by a low surrogate",
          )
        }
        let lo = self.hex4()
        guard lo >= 0xDC00 && lo <= 0xDFFF else {
          raise self.custom_error(
            "high surrogate escape is not followed by a low surrogate",
          )
        }
        out.write_char_utf8(
          Int::unsafe_to_char(0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)),
        )
      } else if hi >= 0xDC00 && hi <= 0xDFFF {
        raise self.custom_error("unpaired low surrogate escape")
      } else {
        out.write_char_utf8(Int::unsafe_to_char(hi))
      }
    }
    _ => raise self.custom_error("unknown escape `\\\{describe(e)}`")
  }
}

///|
/// Locates the string literal at the cursor without consuming it, stopping at
/// the closing quote or at the first escape, whichever comes first.
///
/// Returns the range scanned and whether it ended cleanly at a quote. Stopping
/// early matters: an escaped string would otherwise be scanned twice, once to
/// discover the escape and again to build the result.
///
/// Sixteen bytes are classified at a time by the same `escape_mask` the writer
/// uses — a JSON string ends, escapes, or is malformed on exactly the classes
/// it identifies — with a scalar tail for the last partial chunk, since the
/// input belongs to the caller and may not be padded.
fn JsonDeserializer::string_extent(
  self : JsonDeserializer,
) -> (Int, Int, Bool) raise @data.DeError {
  guard self.peek() == 0x22 else { self.mismatch("string") }
  let start = self.pos + 1
  let limit = self.input.length()
  let mut view = self.input[start:]
  let mut base = start
  while view is [v128le(chunk), ..] {
    let mask = escape_mask(chunk)
    if mask != 0 {
      let at = base + mask.ctz()
      return self.classify_stop(start, at)
    }
    view = view[16:]
    base = base + 16
  }
  let mut i = base
  while i < limit {
    let c = self.code(i)
    if c == 0x22 || c == 0x5C || c < 0x20 {
      return self.classify_stop(start, i)
    }
    i = i + 1
  }
  raise self.eof_error()
}

///|
/// What the byte at `at` means for a string that began at `start`.
fn JsonDeserializer::classify_stop(
  self : JsonDeserializer,
  start : Int,
  at : Int,
) -> (Int, Int, Bool) raise @data.DeError {
  match self.code(at) {
    0x22 => (start, at, true)
    0x5C => (start, at, false)
    _ => raise self.custom_error("unescaped control character in string")
  }
}

///|
/// The string at the cursor, as UTF-8 bytes.
///
/// Nothing here ever leaves UTF-8. An unescaped string is a view straight into
/// the input — no copy at all. An escaped one is unescaped into a byte buffer
/// the way simdjson does it: literal runs are byte copies and `\uXXXX` becomes
/// UTF-8 directly, so the fragments never pay for a conversion each.
fn JsonDeserializer::parse_string_bytes(
  self : JsonDeserializer,
) -> BytesView raise @data.DeError {
  let (start, end, clean) = self.string_extent()
  if clean {
    self.pos = end + 1
    return self.input[start:end]
  }
  let out = Buffer(size_hint=(end - start) * 2 + 16)
  out.write_bytes(self.input[start:end])
  self.pos = end
  let mut chunk = end
  while true {
    if self.at_end() {
      raise self.eof_error()
    }
    let c = self.code(self.pos)
    if c == 0x22 {
      out.write_bytes(self.input[chunk:self.pos])
      self.pos = self.pos + 1
      break
    } else if c == 0x5C {
      out.write_bytes(self.input[chunk:self.pos])
      self.pos = self.pos + 1
      self.decode_escape(out)
      chunk = self.pos
    } else if c < 0x20 {
      raise self.custom_error("unescaped control character in string")
    } else {
      self.pos = self.pos + 1
    }
  }
  out.to_bytes()[:]
}

///|
/// The same string, decoded — for whoever actually asked for a `String`.
fn JsonDeserializer::parse_string(
  self : JsonDeserializer,
) -> String raise @data.DeError {
  let bytes = self.parse_string_bytes()
  @utf8.decode(bytes) catch {
    _ => raise self.custom_error("input is not valid UTF-8")
  }
}

///|
/// Whether the raw bytes in `start..end` spell an enum variant `name`.
///
/// A non-ASCII variant simply fails to match here and takes the decoded slow
/// path. Struct dispatch uses `FieldIdentifier::from_bytes` instead.
fn JsonDeserializer::spells(
  self : JsonDeserializer,
  start : Int,
  end : Int,
  name : String,
) -> Bool {
  if end - start != name.length() {
    return false
  }
  for k in 0..<name.length() {
    let unit = name[k].to_int()
    if unit >= 0x80 || unit != self.code(start + k) {
      return false
    }
  }
  true
}

///|
/// The position of the upcoming string within `variants`.
///
/// This returns where the byte-wise scan landed instead of what it found,
/// which is what `deserialize_enum_begin` wants. A string that is not among
/// them is still consumed, so the error can name it.
fn JsonDeserializer::variant_index(
  self : JsonDeserializer,
  variants : ReadOnlyArray[String],
) -> Int raise @data.DeError {
  let (start, end, clean) = self.string_extent()
  if clean {
    for i, name in variants {
      if self.spells(start, end, name) {
        self.pos = end + 1
        return i
      }
    }
  }
  // Either the token carries escapes, or the byte-wise scan matched nothing.
  // Decoding is the only way to tell `"Empty"` from a genuinely unknown
  // variant, so the slow path is a second lookup rather than an error.
  let found = self.parse_string()
  for i, name in variants {
    if name == found {
      return i
    }
  }
  raise self.unknown_variant_error(found, variants)
}

///|
/// Reads a struct identifier the caller has already named.
///
/// On a match the caller's canonical `String` is returned, so a known clean
/// field costs no allocation or transcoding. Only an unrecognised or escaped
/// name is materialised.
fn JsonDeserializer::identifier(
  self : JsonDeserializer,
  expected : ReadOnlyArray[String],
) -> String raise @data.DeError {
  let (start, end, clean) = self.string_extent()
  if clean {
    for name in expected {
      if self.spells(start, end, name) {
        self.pos = end + 1
        return name
      }
    }
  }
  self.parse_string()
}

// ---- numbers ----
//
// Core's number parsers all take a `StringView`, so reusing them means
// building a `String` for every number in the document. Both halves are
// avoidable:
//
//   integers  read straight from the bytes here — digits, a sign and an
//             overflow check are simple enough to get exactly right
//   doubles   converted by the Eisel-Lemire fast path in `eisel_lemire.mbt`,
//             fed by the same scan that finds the token, with core's exact
//             `parse_double` kept as the fallback for inputs the fast path
//             declines to certify
//
// The structure follows moonbitlang/core PR #3957, which added Eisel-Lemire to
// `internal/strconv` and fed it from the JSON lexer's own digit scan.

///|
/// One scanned number token: its extent, and the mantissa and exponent that a
/// float conversion needs, all from a single pass.
priv struct NumberScan {
  integral : Bool
  negative : Bool
  mantissa : UInt64
  exponent : Int64
  /// The mantissa dropped digits it could not hold, so only the exact
  /// converter may be trusted with this token.
  truncated : Bool
}

///|
/// Beyond 19 digits a `UInt64` mantissa may overflow, so further digits only
/// shift the exponent and mark the scan truncated.
const MANTISSA_DIGITS : Int = 19

///|
/// Anything this far outside the power-of-ten table is refused by the fast
/// path anyway; clamping keeps a huge literal exponent from overflowing.
const EXPONENT_CLAMP : Int = 100000

///|
/// Scans a JSON number at the start of `input`, returning the scan and how
/// many bytes it consumed. `None` when `input` does not begin with a number.
fn scan_number(input : BytesView) -> (NumberScan, Int)? {
  let len = input.length()
  let mut i = 0
  let negative = i < len && input[i].to_int() == 0x2D
  if negative || (i < len && input[i].to_int() == 0x2B) {
    i = i + 1
  }
  let mut mantissa = 0UL
  let mut digits = 0
  let mut exponent = 0
  let mut truncated = false
  let mut seen_dot = false
  let mut any_digit = false
  let mut integral = true
  while i < len {
    let c = input[i].to_int()
    if c == 0x2E && !seen_dot {
      seen_dot = true
      integral = false
      i = i + 1
      continue
    }
    if c < 0x30 || c > 0x39 {
      break
    }
    any_digit = true
    let d = (c - 0x30).to_uint64()
    if mantissa == 0UL && d == 0UL {
      // Leading zeros carry no significance, but a zero after the point still
      // moves the value down by a decimal place.
      if seen_dot {
        exponent = exponent - 1
      }
    } else if digits < MANTISSA_DIGITS {
      mantissa = mantissa * 10UL + d
      digits = digits + 1
      if seen_dot {
        exponent = exponent - 1
      }
    } else {
      truncated = true
      if !seen_dot {
        exponent = exponent + 1
      }
    }
    i = i + 1
  }
  if !any_digit {
    return None
  }
  if i < len && (input[i].to_int() == 0x65 || input[i].to_int() == 0x45) {
    let mut j = i + 1
    let mut exp_negative = false
    if j < len && (input[j].to_int() == 0x2D || input[j].to_int() == 0x2B) {
      exp_negative = input[j].to_int() == 0x2D
      j = j + 1
    }
    let mut exp_digits = 0
    let mut literal = 0
    while j < len {
      let c = input[j].to_int()
      if c < 0x30 || c > 0x39 {
        break
      }
      if literal < EXPONENT_CLAMP {
        literal = literal * 10 + (c - 0x30)
      }
      exp_digits = exp_digits + 1
      j = j + 1
    }
    // A bare `e` with no digits is not part of the number.
    if exp_digits > 0 {
      integral = false
      exponent = exponent + (if exp_negative { -literal } else { literal })
      i = j
    }
  }
  Some(
    (
      { integral, negative, mantissa, exponent: exponent.to_int64(), truncated },
      i,
    ),
  )
}

///|
/// Converts a scanned token to a `Double`.
///
/// Eisel-Lemire answers only when it can certify correct rounding, so anything
/// it declines — truncated mantissas, subnormals, overflow, exact ties — falls
/// through to core's exact converter. Results therefore match
/// `@string.parse_double` on every input.
fn scan_to_double(scan : NumberScan, text : () -> String) -> Double? {
  if !scan.truncated {
    let fast = try_eisel_lemire64(scan.mantissa, scan.exponent, scan.negative)
    if !fast.is_nan() {
      return Some(fast)
    }
  }
  let exact = @string.parse_double(text()) catch { _ => return None }
  Some(exact)
}

///|
/// Scans the number at the cursor, advancing past it.
fn JsonDeserializer::take_number(
  self : JsonDeserializer,
) -> (NumberScan, Int, Int) raise @data.DeError {
  self.skip_ws()
  let start = self.pos
  guard scan_number(self.input[start:]) is Some((scan, used)) else {
    self.mismatch("a number")
  }
  self.pos = start + used
  (scan, start, self.pos)
}

///|
fn JsonDeserializer::token_text(
  self : JsonDeserializer,
  start : Int,
  end : Int,
) -> String {
  @ascii.decode_lossy(self.input[start:end])
}

///|
/// Parses a signed integer straight from the input bytes.
///
/// The magnitude accumulates in a `UInt64` so that `Int64`'s asymmetric range
/// needs no special case: negating through two's complement lands exactly on
/// `Int64::min_value` when the digits say so.
fn JsonDeserializer::int64_in_span(
  self : JsonDeserializer,
  start : Int,
  end : Int,
) -> Int64 raise @data.DeError {
  let mut i = start
  let negative = self.code(i) == 0x2D
  if negative || self.code(i) == 0x2B {
    i = i + 1
  }
  guard i < end else {
    raise self.invalid_value_error("an integer", self.token_text(start, end))
  }
  let limit : UInt64 = if negative {
    9223372036854775808UL
  } else {
    9223372036854775807UL
  }
  let mut magnitude : UInt64 = 0UL
  while i < end {
    let digit = self.code(i) - 0x30
    guard digit >= 0 && digit <= 9 else {
      raise self.invalid_value_error("an integer", self.token_text(start, end))
    }
    let d = digit.to_uint64()
    guard magnitude <= (limit - d) / 10UL else {
      raise self.invalid_value_error(
        "an integer that fits in 64 bits",
        self.token_text(start, end),
      )
    }
    magnitude = magnitude * 10UL + d
    i = i + 1
  }
  if negative {
    (0UL - magnitude).reinterpret_as_int64()
  } else {
    magnitude.reinterpret_as_int64()
  }
}

///|
/// The unsigned counterpart, which simply has no sign to accept.
fn JsonDeserializer::uint64_in_span(
  self : JsonDeserializer,
  start : Int,
  end : Int,
) -> UInt64 raise @data.DeError {
  let mut i = start
  guard i < end && self.code(i) != 0x2D else {
    raise self.invalid_value_error(
      "an unsigned integer",
      self.token_text(start, end),
    )
  }
  if self.code(i) == 0x2B {
    i = i + 1
  }
  let mut magnitude : UInt64 = 0UL
  while i < end {
    let digit = self.code(i) - 0x30
    guard digit >= 0 && digit <= 9 else {
      raise self.invalid_value_error(
        "an unsigned integer",
        self.token_text(start, end),
      )
    }
    let d = digit.to_uint64()
    guard magnitude <= (18446744073709551615UL - d) / 10UL else {
      raise self.invalid_value_error(
        "an unsigned integer that fits in 64 bits",
        self.token_text(start, end),
      )
    }
    magnitude = magnitude * 10UL + d
    i = i + 1
  }
  magnitude
}

///|
fn JsonDeserializer::read_int64(
  self : JsonDeserializer,
) -> Int64 raise @data.DeError {
  if self.bare is Some(raw) {
    let text = @ascii.decode_lossy(raw)
    return @string.parse_int64(text) catch {
      _ => raise self.invalid_value_error("an integer", text)
    }
  }
  let (scan, start, end) = self.take_number()
  guard scan.integral else {
    raise self.invalid_value_error("an integer", self.token_text(start, end))
  }
  self.int64_in_span(start, end)
}

///|
fn JsonDeserializer::read_double(
  self : JsonDeserializer,
) -> Double raise @data.DeError {
  if self.bare is Some(raw) {
    let text = @ascii.decode_lossy(raw)
    return @string.parse_double(text) catch {
      _ => raise self.invalid_value_error("a number", text)
    }
  }
  let (scan, start, end) = self.take_number()
  match scan_to_double(scan, () => self.token_text(start, end)) {
    Some(value) => value
    None =>
      raise self.invalid_value_error("a number", self.token_text(start, end))
  }
}

///|
fn JsonDeserializer::int_in_range(
  self : JsonDeserializer,
  lo : Int64,
  hi : Int64,
  what : String,
) -> Int64 raise @data.DeError {
  let value = self.read_int64()
  if value < lo || value > hi {
    raise self.invalid_value_error(what, value.to_string())
  }
  value
}

// ---- scopes ----

///|
let no_fields : ReadOnlyArray[String] = []

///|
fn JsonDeserializer::push_scope(
  self : JsonDeserializer,
  expected : ReadOnlyArray[String],
) -> Unit {
  self.scopes.push({ base_depth: self.path.depth, count: 0, expected })
}

///|
fn JsonDeserializer::top_scope(
  self : JsonDeserializer,
) -> Scope raise @data.DeError {
  guard self.scopes.length() > 0 else {
    raise self.custom_error("JSON: container read without a begin")
  }
  self.scopes[self.scopes.length() - 1]
}

///|
fn JsonDeserializer::pop_scope(
  self : JsonDeserializer,
) -> Unit raise @data.DeError {
  guard self.scopes.pop() is Some(scope) else {
    raise self.custom_error("JSON: container ended without a begin")
  }
  self.path.depth = scope.base_depth
}

///|
/// Advances to the next item of an open container, or closes it.
///
/// Returns `false` when the closing delimiter was consumed and the scope
/// popped, `true` when a further item follows. The caller then appends the
/// field name or element index to the saved base depth.
fn JsonDeserializer::next_item(
  self : JsonDeserializer,
  closing : Int,
) -> Bool raise @data.DeError {
  let scope = self.top_scope()
  if self.peek() == closing {
    self.pos = self.pos + 1
    self.pop_scope()
    return false
  }
  if scope.count > 0 {
    self.expect(',')
  }
  true
}

// ---- the untyped fallback ----

///|
fn JsonDeserializer::parse_any(
  self : JsonDeserializer,
) -> @data.Value raise @data.DeError {
  if self.bare is Some(raw) {
    return Str(raw)
  }
  let token = self.peek_or_end()
  if token < 0 {
    raise self.eof_error()
  }
  match token {
    0x7B => {
      self.pos = self.pos + 1
      let entries = []
      while self.peek_or_end() != 0x7D {
        if entries.length() > 0 {
          guard self.try_expect(',') else { self.expect(',') }
        }
        // The key goes into the data model as the bytes it already is.
        let key = self.parse_string_bytes()
        guard self.try_expect(':') else { self.expect(':') }
        entries.push((@data.Str(key), self.parse_any()))
      }
      self.pos = self.pos + 1
      Map(ReadOnlyArray::from_array(entries))
    }
    0x5B => {
      self.pos = self.pos + 1
      let items = []
      while self.peek_or_end() != 0x5D {
        if items.length() > 0 {
          guard self.try_expect(',') else { self.expect(',') }
        }
        items.push(self.parse_any())
      }
      self.pos = self.pos + 1
      Seq(ReadOnlyArray::from_array(items))
    }
    0x22 => Str(self.parse_string_bytes())
    0x74 => {
      guard self.eat("true") else { self.bad_literal("true") }
      Boolean(true)
    }
    0x66 => {
      guard self.eat("false") else { self.bad_literal("false") }
      Boolean(false)
    }
    0x6E => {
      guard self.eat("null") else { self.bad_literal("null") }
      Null
    }
    _ => {
      let (scan, from, to) = self.take_number()
      let text = () => self.token_text(from, to)
      if scan.integral {
        // Prefer the narrowest representation that holds the digits, then fall
        // back to a float the way most JSON readers do.
        @data.Int(self.int64_in_span(from, to)) catch {
          _ =>
            @data.UInt(self.uint64_in_span(from, to)) catch {
              _ =>
                match scan_to_double(scan, text) {
                  Some(value) => @data.Double(value)
                  None => raise self.invalid_value_error("a number", text())
                }
            }
        }
      } else {
        match scan_to_double(scan, text) {
          Some(value) => @data.Double(value)
          None => raise self.invalid_value_error("a number", text())
        }
      }
    }
  }
}

// ---- Deserializer ----

///|
pub impl @data.Deserializer for JsonDeserializer with fn path(self) {
  self.current_path()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_unit(self) {
  if self.eat("null") {
    return
  }
  if self.peek() == 0x6E {
    self.bad_literal("null")
  }
  self.mismatch("unit")
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_bool(self) {
  if self.eat("true") {
    true
  } else if self.eat("false") {
    false
  } else if self.peek() == 0x74 || self.peek() == 0x66 {
    self.bad_literal("true` or `false")
  } else {
    self.mismatch("boolean")
  }
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_byte(self) {
  self.int_in_range(0L, 255L, "a byte").to_byte()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_int16(self) {
  Int16::from_int64(self.int_in_range(-32768L, 32767L, "an int16"))
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_uint16(
  self,
) {
  self.int_in_range(0L, 65535L, "a uint16").to_uint16()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_int(self) {
  self.int_in_range(-2147483648L, 2147483647L, "an int").to_int()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_uint(self) {
  self.int_in_range(0L, 4294967295L, "a uint").reinterpret_as_uint64().to_uint()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_int64(self) {
  self.read_int64()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_uint64(
  self,
) {
  if self.bare is Some(raw) {
    let text = @ascii.decode_lossy(raw)
    return @string.parse_uint64(text) catch {
      _ => raise self.invalid_value_error("an unsigned integer", text)
    }
  }
  let (scan, start, end) = self.take_number()
  guard scan.integral else {
    raise self.invalid_value_error(
      "an unsigned integer",
      self.token_text(start, end),
    )
  }
  self.uint64_in_span(start, end)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_float(self) {
  Float::from_double(self.read_double())
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_double(
  self,
) {
  self.read_double()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_char(self) {
  let text = self.deserialize_string()
  if text.char_length() != 1 {
    raise self.invalid_value_error("a single character", text)
  }
  text.to_array()[0]
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_string(
  self,
) {
  if self.bare is Some(raw) {
    @utf8.decode(raw) catch {
      _ => raise self.custom_error("input is not valid UTF-8")
    }
  } else {
    self.parse_string()
  }
}

///|
/// The read counterpart of `serialize_str_bytes`, handing back the input's own
/// bytes instead of decoding them into a `String`. Mirrors `deserialize_string`
/// exactly, minus the decode.
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_str_bytes(
  self,
) {
  if self.bare is Some(raw) {
    raw
  } else {
    self.parse_string_bytes()
  }
}

///|
/// The mirror of writing bytes as an array of numbers.
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_bytes(self) {
  guard self.peek() == 0x5B else { self.mismatch("byte string") }
  self.pos = self.pos + 1
  let out = []
  while self.peek() != 0x5D {
    if out.length() > 0 {
      self.expect(',')
    }
    out.push(self.int_in_range(0L, 255L, "a byte").to_byte())
  }
  self.pos = self.pos + 1
  Bytes::from_array(out)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_option(
  self,
) {
  if self.eat("null") {
    None
  } else {
    Some(@data.Deserialize::deserialize(self))
  }
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_seq_begin(
  self,
) {
  self.expect('[')
  self.push_scope(no_fields)
  // A streaming parser cannot know the length without scanning ahead.
  None
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_seq_next(
  self,
) {
  guard self.next_item(0x5D) else { return None }
  let scope = self.top_scope()
  self.set_index(scope.base_depth, scope.count)
  scope.count = scope.count + 1
  Some(@data.Deserialize::deserialize(self))
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_map_begin(
  self,
) {
  self.expect('{')
  self.push_scope(no_fields)
  None
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_map_next_key(
  self,
) {
  guard self.next_item(0x7D) else { return None }
  let scope = self.top_scope()
  let key = self.parse_string_bytes()
  self.expect(':')
  self.set_key(scope.base_depth, @ascii.decode_lossy(key))
  scope.count = scope.count + 1
  Some(@data.Deserialize::deserialize(self.key_reader(key)))
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_map_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_struct_begin(
  self,
  _name,
  fields,
) {
  self.expect('{')
  self.push_scope(fields)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_field_name(
  self,
) {
  guard self.next_item(0x7D) else { return None }
  let scope = self.top_scope()
  let name = self.identifier(scope.expected)
  self.expect(':')
  self.set_key(scope.base_depth, name)
  scope.count = scope.count + 1
  Some(name)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_field(self) {
  guard self.next_item(0x7D) else { return None }
  let scope = self.top_scope()
  let (start, end, clean) = self.string_extent()
  if clean {
    let key = self.input[start:end]
    let field = @data.FieldIdentifier::from_bytes(key, scope.count)
    match @data.FieldIdentifier::name(field) {
      Some(name) => {
        self.pos = end + 1
        self.expect(':')
        self.set_key(scope.base_depth, name)
        scope.count = scope.count + 1
        return Some(field)
      }
      None => ()
    }
  }
  let name = self.parse_string()
  let field = @data.FieldIdentifier::from_string(name)
  self.expect(':')
  match @data.FieldIdentifier::name(field) {
    Some(canonical) => self.set_key(scope.base_depth, canonical)
    None => self.set_key(scope.base_depth, name)
  }
  scope.count = scope.count + 1
  Some(field)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_field_value(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn skip_value(self) {
  let _ = self.parse_any()
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_enum_begin(
  self,
  _name,
  variants,
) {
  let base_depth = self.path.depth
  let wrapped = self.peek() == 0x7B
  if wrapped {
    self.pos = self.pos + 1
  }
  let index = self.variant_index(variants)
  if wrapped {
    self.expect(':')
  }
  self.enums.push({ wrapped, base_depth })
  self.set_key(base_depth, variants[index])
  index
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_unit_variant(
  self,
) {
  ignore(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_newtype_variant(
  self,
) {
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_enum_end(
  self,
) {
  guard self.enums.pop() is Some(scope) else {
    raise self.custom_error("JSON: enum ended without a begin")
  }
  if scope.wrapped {
    self.expect('}')
  }
  self.path.depth = scope.base_depth
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_any(self) {
  self.parse_any()
}

///|
/// Tuples get their own handling rather than riding on the sequence protocol,
/// because a JSON array has a closing `]` that something has to consume and
/// `deserialize_tuple_next` — reading a known number of elements — never sees
/// the end of the array.
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_tuple_begin(
  self,
  _len,
) {
  self.expect('[')
  self.push_scope(no_fields)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_tuple_next(
  self,
) {
  let scope = self.top_scope()
  if self.peek() == 0x5D {
    raise self.eof_error()
  }
  if scope.count > 0 {
    self.expect(',')
  }
  self.set_index(scope.base_depth, scope.count)
  scope.count = scope.count + 1
  @data.Deserialize::deserialize(self)
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_tuple_end(
  self,
) {
  self.expect(']')
  self.pop_scope()
}

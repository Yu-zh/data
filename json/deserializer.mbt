///|
/// One open `[` or `{`, remembering the path to restore on the way out and how
/// many items have been read so far (which is what decides whether the next
/// item needs a leading comma).
priv struct Scope {
  base : @data.Path
  mut count : Int
  /// The field names the caller declared for this struct, empty for arrays
  /// and maps. Matching a key against these lets `deserialize_field_name`
  /// hand back the caller's own `String` rather than building a new one.
  expected : Array[String]
}

///|
/// One open enum. `wrapped` records whether it was written as
/// `{"Variant": payload}`, which has a `}` to consume, or as a bare
/// `"Variant"` string, which does not.
priv struct EnumScope {
  wrapped : Bool
  base : @data.Path
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
  mut path : @data.Path
  scopes : Array[Scope]
  enums : Array[EnumScope]
  /// Set on the throwaway deserializer used to read an object key: the
  /// already-decoded, already-unescaped key text. JSON keys are always
  /// strings, but the key *type* may be a number, so the token has to be
  /// re-read through whatever `Deserialize` the map's key type provides.
  /// Holding the text avoids re-encoding it just to parse it again.
  bare : String?
}

///|
pub fn JsonDeserializer::new(input : Bytes) -> JsonDeserializer {
  { input, pos: 0, path: @data.Root, scopes: [], enums: [], bare: None }
}

///|
/// Checks that the whole input was consumed.
pub fn JsonDeserializer::finish(
  self : JsonDeserializer,
) -> Unit raise @data.DeError {
  self.skip_ws()
  if self.pos < self.input.length() {
    raise @data.DeCustom(path=self.path, message="trailing input after value")
  }
}

///|
fn JsonDeserializer::key_reader(
  self : JsonDeserializer,
  text : String,
) -> JsonDeserializer {
  {
    input: b"",
    pos: 0,
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
/// Decodes a byte range that came from inside a string literal or a number.
fn JsonDeserializer::decode_chunk(
  self : JsonDeserializer,
  start : Int,
  end : Int,
) -> String raise @data.DeError {
  @utf8.decode(self.input[start:end]) catch {
    _ =>
      raise @data.DeCustom(path=self.path, message="input is not valid UTF-8")
  }
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
fn JsonDeserializer::peek(self : JsonDeserializer) -> Int raise @data.DeError {
  self.skip_ws()
  if self.at_end() {
    raise @data.Eof(path=self.path)
  }
  self.code(self.pos)
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
fn JsonDeserializer::expect(
  self : JsonDeserializer,
  ch : Char,
) -> Unit raise @data.DeError {
  let c = self.peek()
  guard c == ch.to_int() else {
    raise @data.DeCustom(
      path=self.path,
      message="expected `\{ch}`, found `\{describe(c)}`",
    )
  }
  self.pos = self.pos + 1
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
fn[T] JsonDeserializer::bad_literal(
  self : JsonDeserializer,
  expected : String,
) -> T raise @data.DeError {
  raise @data.DeCustom(
    path=self.path,
    message="invalid literal, expected `\{expected}`",
  )
}

///|
fn[T] JsonDeserializer::mismatch(
  self : JsonDeserializer,
  expected : String,
) -> T raise @data.DeError {
  raise @data.InvalidType(path=self.path, expected~, found=self.found())
}

// ---- strings ----

///|
fn JsonDeserializer::hex4(self : JsonDeserializer) -> Int raise @data.DeError {
  if self.pos + 4 > self.input.length() {
    raise @data.Eof(path=self.path)
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
      raise @data.DeCustom(
        path=self.path,
        message="invalid `\\u` escape: `\{describe(c)}` is not a hex digit",
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
  out : StringBuilder,
) -> Unit raise @data.DeError {
  if self.at_end() {
    raise @data.Eof(path=self.path)
  }
  let e = self.code(self.pos)
  self.pos = self.pos + 1
  match e {
    0x22 => out.write_char('"')
    0x5C => out.write_char('\\')
    0x2F => out.write_char('/')
    0x62 => out.write_char(Int::unsafe_to_char(0x08))
    0x66 => out.write_char(Int::unsafe_to_char(0x0C))
    0x6E => out.write_char('\n')
    0x72 => out.write_char('\r')
    0x74 => out.write_char('\t')
    0x75 => {
      let hi = self.hex4()
      if hi >= 0xD800 && hi <= 0xDBFF {
        guard self.eat_u_escape() else {
          raise @data.DeCustom(
            path=self.path,
            message="high surrogate escape is not followed by a low surrogate",
          )
        }
        let lo = self.hex4()
        guard lo >= 0xDC00 && lo <= 0xDFFF else {
          raise @data.DeCustom(
            path=self.path,
            message="high surrogate escape is not followed by a low surrogate",
          )
        }
        out.write_char(
          Int::unsafe_to_char(0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)),
        )
      } else if hi >= 0xDC00 && hi <= 0xDFFF {
        raise @data.DeCustom(
          path=self.path,
          message="unpaired low surrogate escape",
        )
      } else {
        out.write_char(Int::unsafe_to_char(hi))
      }
    }
    _ =>
      raise @data.DeCustom(
        path=self.path,
        message="unknown escape `\\\{describe(e)}`",
      )
  }
}

///|
/// Locates the string literal at the cursor without consuming it, stopping at
/// the closing quote or at the first escape, whichever comes first.
///
/// Returns the range scanned and whether it ended cleanly at a quote. Stopping
/// early matters: an escaped string would otherwise be scanned twice, once to
/// discover the escape and again to build the result.
fn JsonDeserializer::string_extent(
  self : JsonDeserializer,
) -> (Int, Int, Bool) raise @data.DeError {
  guard self.peek() == 0x22 else { self.mismatch("string") }
  let start = self.pos + 1
  let limit = self.input.length()
  let mut i = start
  while i < limit {
    let c = self.code(i)
    if c == 0x22 {
      return (start, i, true)
    } else if c == 0x5C {
      return (start, i, false)
    } else if c < 0x20 {
      raise @data.DeCustom(
        path=self.path,
        message="unescaped control character in string",
      )
    } else {
      i = i + 1
    }
  }
  raise @data.Eof(path=self.path)
}

///|
fn JsonDeserializer::parse_string(
  self : JsonDeserializer,
) -> String raise @data.DeError {
  let (start, end, clean) = self.string_extent()
  if clean {
    // The common case: the value is one contiguous span of the input, so it
    // needs neither a builder nor a copy — just the decode.
    let text = self.decode_chunk(start, end)
    self.pos = end + 1
    return text
  }
  // Escaped. Carry over the prefix already scanned rather than walking it a
  // second time, and resume at the escape.
  let out = StringBuilder::new()
  out.write_string(self.decode_chunk(start, end))
  self.pos = end
  let mut chunk = end
  while true {
    if self.at_end() {
      raise @data.Eof(path=self.path)
    }
    let c = self.code(self.pos)
    if c == 0x22 {
      out.write_string(self.decode_chunk(chunk, self.pos))
      self.pos = self.pos + 1
      break
    } else if c == 0x5C {
      out.write_string(self.decode_chunk(chunk, self.pos))
      self.pos = self.pos + 1
      self.decode_escape(out)
      chunk = self.pos
    } else if c < 0x20 {
      raise @data.DeCustom(
        path=self.path,
        message="unescaped control character in string",
      )
    } else {
      self.pos = self.pos + 1
    }
  }
  out.to_string()
}

///|
/// Whether the raw bytes in `start..end` spell `name`.
///
/// Declared field and variant names are ASCII in practice; a non-ASCII one
/// simply fails to match here and takes the decoding path.
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
/// Reads an identifier the caller has already named.
///
/// On a match the caller's own `String` is returned — the same object, not a
/// copy — so a known field or variant costs no allocation at all. Only an
/// unrecognised or escaped name is materialised.
fn JsonDeserializer::identifier(
  self : JsonDeserializer,
  expected : Array[String],
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
/// Parses a JSON number from UTF-8 bytes.
///
/// The byte-oriented counterpart to `@string.parse_double`, which core does
/// not provide. Returns `None` if `input` is not a single JSON number.
pub fn parse_double_bytes(input : BytesView) -> Double? {
  guard scan_number(input) is Some((scan, used)) else { return None }
  guard used == input.length() else { return None }
  scan_to_double(scan, () => @ascii.decode_lossy(input))
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
    raise @data.InvalidValue(
      path=self.path,
      expected="an integer",
      found=self.token_text(start, end),
    )
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
      raise @data.InvalidValue(
        path=self.path,
        expected="an integer",
        found=self.token_text(start, end),
      )
    }
    let d = digit.to_uint64()
    guard magnitude <= (limit - d) / 10UL else {
      raise @data.InvalidValue(
        path=self.path,
        expected="an integer that fits in 64 bits",
        found=self.token_text(start, end),
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
    raise @data.InvalidValue(
      path=self.path,
      expected="an unsigned integer",
      found=self.token_text(start, end),
    )
  }
  if self.code(i) == 0x2B {
    i = i + 1
  }
  let mut magnitude : UInt64 = 0UL
  while i < end {
    let digit = self.code(i) - 0x30
    guard digit >= 0 && digit <= 9 else {
      raise @data.InvalidValue(
        path=self.path,
        expected="an unsigned integer",
        found=self.token_text(start, end),
      )
    }
    let d = digit.to_uint64()
    guard magnitude <= (18446744073709551615UL - d) / 10UL else {
      raise @data.InvalidValue(
        path=self.path,
        expected="an unsigned integer that fits in 64 bits",
        found=self.token_text(start, end),
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
  if self.bare is Some(text) {
    return @string.parse_int64(text) catch {
      _ =>
        raise @data.InvalidValue(
          path=self.path,
          expected="an integer",
          found=text,
        )
    }
  }
  let (scan, start, end) = self.take_number()
  guard scan.integral else {
    raise @data.InvalidValue(
      path=self.path,
      expected="an integer",
      found=self.token_text(start, end),
    )
  }
  self.int64_in_span(start, end)
}

///|
fn JsonDeserializer::read_double(
  self : JsonDeserializer,
) -> Double raise @data.DeError {
  if self.bare is Some(text) {
    return @string.parse_double(text) catch {
      _ =>
        raise @data.InvalidValue(
          path=self.path,
          expected="a number",
          found=text,
        )
    }
  }
  let (scan, start, end) = self.take_number()
  match scan_to_double(scan, () => self.token_text(start, end)) {
    Some(value) => value
    None =>
      raise @data.InvalidValue(
        path=self.path,
        expected="a number",
        found=self.token_text(start, end),
      )
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
    raise @data.InvalidValue(
      path=self.path,
      expected=what,
      found=value.to_string(),
    )
  }
  value
}

// ---- scopes ----

///|
let no_fields : Array[String] = []

///|
fn JsonDeserializer::push_scope(
  self : JsonDeserializer,
  expected : Array[String],
) -> Unit {
  self.scopes.push({ base: self.path, count: 0, expected })
}

///|
fn JsonDeserializer::top_scope(
  self : JsonDeserializer,
) -> Scope raise @data.DeError {
  guard self.scopes.length() > 0 else {
    raise @data.DeCustom(
      path=self.path,
      message="JSON: container read without a begin",
    )
  }
  self.scopes[self.scopes.length() - 1]
}

///|
fn JsonDeserializer::pop_scope(
  self : JsonDeserializer,
) -> Unit raise @data.DeError {
  guard self.scopes.pop() is Some(scope) else {
    raise @data.DeCustom(
      path=self.path,
      message="JSON: container ended without a begin",
    )
  }
  self.path = scope.base
}

///|
/// Advances to the next item of an open container, or closes it.
///
/// Returns `false` when the closing delimiter was consumed and the scope
/// popped, `true` when a further item follows and the path has been set to it.
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
  if self.bare is Some(text) {
    return Str(text)
  }
  match self.peek() {
    0x7B => {
      self.pos = self.pos + 1
      let entries = []
      while self.peek() != 0x7D {
        if entries.length() > 0 {
          self.expect(',')
        }
        let key = self.parse_string()
        self.expect(':')
        entries.push((@data.Str(key), self.parse_any()))
      }
      self.pos = self.pos + 1
      Map(entries)
    }
    0x5B => {
      self.pos = self.pos + 1
      let items = []
      while self.peek() != 0x5D {
        if items.length() > 0 {
          self.expect(',')
        }
        items.push(self.parse_any())
      }
      self.pos = self.pos + 1
      Seq(items)
    }
    0x22 => Str(self.parse_string())
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
                  None =>
                    raise @data.InvalidValue(
                      path=self.path,
                      expected="a number",
                      found=text(),
                    )
                }
            }
        }
      } else {
        match scan_to_double(scan, text) {
          Some(value) => @data.Double(value)
          None =>
            raise @data.InvalidValue(
              path=self.path,
              expected="a number",
              found=text(),
            )
        }
      }
    }
  }
}

// ---- Deserializer ----

///|
pub impl @data.Deserializer for JsonDeserializer with fn path(self) {
  self.path
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
  if self.bare is Some(text) {
    return @string.parse_uint64(text) catch {
      _ =>
        raise @data.InvalidValue(
          path=self.path,
          expected="an unsigned integer",
          found=text,
        )
    }
  }
  let (scan, start, end) = self.take_number()
  guard scan.integral else {
    raise @data.InvalidValue(
      path=self.path,
      expected="an unsigned integer",
      found=self.token_text(start, end),
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
    raise @data.InvalidValue(
      path=self.path,
      expected="a single character",
      found=text,
    )
  }
  text.to_array()[0]
}

///|
pub impl @data.Deserializer for JsonDeserializer with fn deserialize_string(
  self,
) {
  if self.bare is Some(text) {
    text
  } else {
    self.parse_string()
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
  self.path = scope.base.index(scope.count)
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
  let text = self.parse_string()
  self.expect(':')
  self.path = scope.base.key(text)
  scope.count = scope.count + 1
  Some(@data.Deserialize::deserialize(self.key_reader(text)))
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
  self.path = scope.base.key(name)
  scope.count = scope.count + 1
  Some(name)
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
  let base = self.path
  let wrapped = self.peek() == 0x7B
  if wrapped {
    self.pos = self.pos + 1
  }
  let variant = self.identifier(variants)
  guard variants.is_empty() || variants.contains(variant) else {
    raise @data.UnknownVariant(path=base, variant~, expected=variants)
  }
  if wrapped {
    self.expect(':')
  }
  self.enums.push({ wrapped, base })
  self.path = base.key(variant)
  variant
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
    raise @data.DeCustom(
      path=self.path,
      message="JSON: enum ended without a begin",
    )
  }
  if scope.wrapped {
    self.expect('}')
  }
  self.path = scope.base
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
    raise @data.Eof(path=self.path)
  }
  if scope.count > 0 {
    self.expect(',')
  }
  self.path = scope.base.index(scope.count)
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

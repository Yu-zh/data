// Whitebox tests: the JSON writer's own bookkeeping, and the parser internals
// that the public API only reaches indirectly.

///|
test "the writer tracks its own nesting depth" {
  let s = JsonSerializer::new()
  s.serialize_struct_begin("Outer", 2)
  s.serialize_field("xs", [1, 2])
  s.serialize_field("inner", { "k": "v" })
  s.serialize_struct_end()
  inspect(
    @utf8.decode_lossy(s.finish()),
    content="{\"xs\":[1,2],\"inner\":{\"k\":\"v\"}}",
  )
}

///|
test "finishing with an unclosed container raises" {
  let s = JsonSerializer::new()
  s.serialize_seq_begin(None)
  s.serialize_seq_element(1)
  try s.finish() catch {
    e => inspect(e, content="JSON: 1 container(s) opened but never ended")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "closing the wrong kind of container raises" {
  let s = JsonSerializer::new()
  s.serialize_seq_begin(None)
  try s.serialize_struct_end() catch {
    e => inspect(e, content="JSON: mismatched container end")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "closing a container that was never opened raises" {
  let s = JsonSerializer::new()
  try s.serialize_seq_end() catch {
    e => inspect(e, content="JSON: container ended without a begin")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "a field written outside an object raises" {
  let s = JsonSerializer::new()
  s.serialize_seq_begin(None)
  try s.serialize_field("x", 1) catch {
    e => inspect(e, content="JSON: object key written outside an object")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "describe names printable and unprintable code units" {
  inspect(describe(0x61), content="a")
  inspect(describe(0x7B), content="{")
  inspect(describe(0xD800), content="U+d800")
}

///|
test "the parser names what it found in the data model's vocabulary" {
  inspect(JsonDeserializer::new(b"\"s\"").found(), content="string")
  inspect(JsonDeserializer::new(b" {").found(), content="map")
  inspect(JsonDeserializer::new(b"[").found(), content="sequence")
  inspect(JsonDeserializer::new(b"true").found(), content="boolean")
  inspect(JsonDeserializer::new(b"false").found(), content="boolean")
  inspect(JsonDeserializer::new(b"null").found(), content="unit")
  inspect(JsonDeserializer::new(b"-1").found(), content="a number")
  inspect(JsonDeserializer::new(b"]").found(), content="end of sequence")
  inspect(JsonDeserializer::new(b"}").found(), content="end of map")
  inspect(JsonDeserializer::new(b"   ").found(), content="end of input")
}

///|
test "a sequence reports no length hint, since nothing has been scanned yet" {
  let d = JsonDeserializer::new(b"[1,2,3]")
  assert_eq(d.deserialize_seq_begin(), None)
}

///|
test "ending a container the parser never entered raises" {
  let d = JsonDeserializer::new(b"[]")
  try d.deserialize_tuple_end() catch {
    e => inspect(e, content="$: expected `]`, found `[`")
  } noraise {
    _ => fail("expected a protocol error")
  }
  let e = JsonDeserializer::new(b"")
  try e.deserialize_enum_end() catch {
    err => inspect(err, content="$: JSON: enum ended without a begin")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "the parser rejects a truncated escape" {
  try (JsonDeserializer::new(b"\"\\u00").deserialize_string() : String) catch {
    e => inspect(e, content="$: unexpected end of input")
  } noraise {
    _ => fail("expected an end of input error")
  }
  try (JsonDeserializer::new(b"\"\\").deserialize_string() : String) catch {
    e => inspect(e, content="$: unexpected end of input")
  } noraise {
    _ => fail("expected an end of input error")
  }
}

///|
test "an object key is read through the key type's own Deserialize" {
  // The sub-deserializer holds one already-unescaped token, so a numeric key
  // type parses the digits and a string key type takes them verbatim.
  let d = JsonDeserializer::new(b"{\"12\":true}")
  let _ = d.deserialize_map_begin()
  assert_eq((d.deserialize_map_next_key() : Int?), Some(12))
  assert_eq((d.deserialize_map_value() : Bool), true)
  assert_eq((d.deserialize_map_next_key() : Int?), None)
}

///|
test "deserialize_any on a key sub-deserializer yields the raw token" {
  let d = JsonDeserializer::new(b"{\"k\":1}")
  let _ = d.deserialize_map_begin()
  assert_eq((d.deserialize_map_next_key() : @data.Value?), Some(Str(b"k")))
}

///|
test "reading a container item without a begin raises" {
  let d = JsonDeserializer::new(b"[1]")
  try (d.deserialize_seq_next() : Int?) catch {
    e => inspect(e, content="$: JSON: container read without a begin")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
/// A fast float path that is subtly wrong is worse than none, so it is checked
/// differentially: every input must produce the *same bits* as core's exact
/// `@string.parse_double`, not merely a close value.
fn same_bits(text : String) -> Bool {
  // Composed here rather than behind a helper in the parser, so the test
  // exercises exactly the pair `read_double` uses and the library exports
  // nothing extra to make itself testable.
  let input = @utf8.encode(text)[:]
  let mine = match scan_number(input) {
    Some((scan, used)) =>
      if used == input.length() {
        scan_to_double(scan, () => @ascii.decode_lossy(input))
      } else {
        None
      }
    None => None
  }
  let theirs : Double? = Some(@string.parse_double(text)) catch { _ => None }
  match (mine, theirs) {
    // Bit equality, not approximate equality: rounding must match exactly,
    // and -0.0 must not pass as 0.0.
    (Some(a), Some(b)) => a.reinterpret_as_int64() == b.reinterpret_as_int64()
    // Agreeing to reject an input counts as agreeing.
    (None, None) => true
    _ => false
  }
}

///|
test "the float fast path agrees with core bit for bit" {
  let cases = [
    // Canada-style coordinates: 17 significant digits, which is exactly the
    // range that defeats the older exact-only fast paths.
    "-65.613616999999977", "43.420273000000009", "-65.619720000000029",
    // Ordinary values.
     "0", "-0", "1", "-1", "1.5", "3.14159265358979", "2.2250738585072014e-308",
    // Exponent forms.
     "1e0", "1E5", "1e-5", "1.25e10", "-1.25E-10", "5e-324", "1.7976931348623157e308",
    // Boundaries the fast path must decline rather than guess.
     "1e309", "1e-400", "4.9e-324", "2.2250738585072011e-308",
    // Long and truncated mantissas.
     "1234567890123456789", "12345678901234567890", "123456789012345678901234567890",
    "0.1000000000000000055511151231257827021181583404541015625",
    // Exact ties and near-ties.
     "9007199254740993", "0.5", "0.125", "1.0000000000000002",
    // Leading and trailing zeros.
     "000123", "0.000000000000000000001", "1000000000000000000000",
  ]
  let disagreed = cases.filter(t => !same_bits(t))
  debug_inspect(disagreed, content="[]")
}

///|
test "the float fast path agrees across a systematic sweep" {
  // A deterministic sweep over mantissas and exponents, covering the table's
  // whole range including where it hands off to the exact converter.
  let mut seed = 0x2545F4914F6CDD1DUL
  let mut checked = 0
  for _ in 0..<4000 {
    // xorshift64*, so the sweep is reproducible without an RNG dependency.
    seed = seed ^ (seed >> 12)
    seed = seed ^ (seed << 25)
    seed = seed ^ (seed >> 27)
    let r = seed * 0x2545F4914F6CDD1DUL
    // Mantissas up to 19 digits, spanning both the fast path and the
    // truncated case that must defer to the exact converter.
    let mantissa = r % 9999999999999999999UL
    let exponent = (r >> 40).to_int() % 400 - 200
    let text = "\{mantissa}e\{exponent}"
    assert_true(same_bits(text))
    checked = checked + 1
  }
  inspect(checked, content="4000")
}

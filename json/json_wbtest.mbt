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
  assert_eq((d.deserialize_map_next_key() : @data.Value?), Some(Str("k")))
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

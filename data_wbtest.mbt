// Whitebox tests: internal invariants and the protocol contracts that the
// flattened compound API cannot enforce in the type system.

///|
test "paths render as JSONPath" {
  inspect(Root, content="$")
  inspect(Root.key("user").key("tags").index(2), content="$.user.tags[2]")
  inspect(Root.index(0).key("x"), content="$[0].x")
}

///|
test "Value::get looks up string keys and ignores other shapes" {
  let v : Value = Map([(Str("a"), Int(1L)), (Int(2L), Str("keyed"))])
  assert_eq(v.get("a"), Some(Int(1L)))
  assert_eq(v.get("missing"), None)
  assert_eq(Seq([]).get("a"), None)
}

///|
test "type_name covers every constructor" {
  debug_inspect(
    [
      Null,
      Boolean(true),
      Int(1L),
      UInt(1UL),
      Double(1.0),
      Str(""),
      Bytes(b""),
      Seq([]),
      Map([]),
    ].map(v => v.type_name()),
    content=(
      #|[
      #|  "unit",
      #|  "boolean",
      #|  "integer",
      #|  "unsigned integer",
      #|  "float",
      #|  "string",
      #|  "byte string",
      #|  "sequence",
      #|  "map",
      #|]
    ),
  )
}

///|
/// The `_begin` / element / `_end` triples replace serde's builder types, so
/// misuse is caught at runtime instead of by the compiler. These check that it
/// is caught loudly rather than silently producing a wrong value.
test "an element written outside an open sequence raises" {
  let s = ValueSerializer::new()
  try s.serialize_seq_element(1) catch {
    e => inspect(e, content="element written outside an open sequence")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "a map value written without a key raises" {
  let s = ValueSerializer::new()
  s.serialize_map_begin(None)
  try s.serialize_map_value(1) catch {
    e => inspect(e, content="map value written without a key")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "finishing with an unclosed compound raises" {
  let s = ValueSerializer::new()
  s.serialize_seq_begin(None)
  s.serialize_seq_element(1)
  try s.finish() catch {
    e => inspect(e, content="a compound was opened but never ended")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "a serializer that wrote nothing raises rather than inventing a value" {
  let s = ValueSerializer::new()
  try s.finish() catch {
    e => inspect(e, content="serializer produced no value")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
test "a variant ended without a begin raises" {
  let s = ValueSerializer::new()
  s.serialize_seq_begin(Some(0))
  try s.serialize_tuple_variant_end() catch {
    e => inspect(e, content="variant ended without a matching begin")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

///|
/// Tuples, tuple structs and unit structs have no distinct representation in
/// `Value`; they reach it through the trait's default implementations.
test "defaults widen tuples to sequences and unit structs to unit" {
  let s = ValueSerializer::new()
  s.serialize_tuple_struct_begin("Rgb", 2)
  s.serialize_tuple_struct_field(1)
  s.serialize_tuple_struct_field(2)
  s.serialize_tuple_struct_end()
  inspect(s.finish(), content="[1, 2]")
  let u = ValueSerializer::new()
  u.serialize_unit_struct("Marker")
  inspect(u.finish(), content="null")
  let n = ValueSerializer::new()
  n.serialize_newtype_struct("Meters", 5.5)
  inspect(n.finish(), content="5.5")
}

///|
test "is_human_readable defaults to true" {
  assert_true(ValueSerializer::new().is_human_readable())
  assert_true(ValueDeserializer::new(Null).is_human_readable())
}

///|
test "a child deserializer carries its own path" {
  let d = ValueDeserializer::new(Seq([Str("a"), Int(1L)]))
  inspect(d.path(), content="$")
  let _ = d.deserialize_seq_begin()
  let first : String = match d.deserialize_seq_next() {
    Some(v) => v
    None => fail("expected an element")
  }
  assert_eq(first, "a")
  // The parent's own path is unchanged by iterating its children.
  inspect(d.path(), content="$")
}

///|
test "deserialize_any hands back the value untouched" {
  let v : Value = Map([(Str("k"), Seq([Int(1L)]))])
  assert_eq(ValueDeserializer::new(v).deserialize_any(), v)
}

///|
/// Every error variant is part of the public contract, so every rendering is
/// pinned. `one_of` degrades when a type declares no valid names.
test "error messages render for every variant" {
  inspect(
    UnsupportedType(format="JSON", kind="a map with non-string keys"),
    content="JSON cannot serialize a map with non-string keys",
  )
  inspect(SerCustom(message="sink closed"), content="sink closed")
  inspect(
    InvalidLength(path=Root.key("xs"), expected=3, found=2),
    content="$.xs: invalid length: expected 3 elements, found 2",
  )
  inspect(
    UnknownField(path=Root, field="z", expected=["x", "y"]),
    content="$: unknown field `z`, expected one of x, y",
  )
  inspect(
    UnknownField(path=Root, field="z", expected=[]),
    content="$: unknown field `z`, there are no valid values",
  )
  inspect(Eof(path=Root.index(1)), content="$[1]: unexpected end of input")
  inspect(
    DeCustom(path=Root, message="trailing input"),
    content="$: trailing input",
  )
  assert_eq(
    InvalidType(path=Root.key("a"), expected="int", found="string").path(),
    Root.key("a"),
  )
}

///|
test "reading a map value past the end reports end of input" {
  let d = ValueDeserializer::new(Map([]))
  let _ = d.deserialize_map_begin()
  try (d.deserialize_map_value() : Int) catch {
    e => inspect(e, content="$: unexpected end of input")
  } noraise {
    _ => fail("expected an end of input error")
  }
}

///|
test "reading a field value past the end reports end of input" {
  let d = ValueDeserializer::new(Map([]))
  d.deserialize_struct_begin("X", [])
  try (d.deserialize_field_value() : Int) catch {
    e => inspect(e, content="$: unexpected end of input")
  } noraise {
    _ => fail("expected an end of input error")
  }
}

///|
/// Map keys need not be strings, so a non-string key reaching the struct
/// protocol still has to produce a usable path segment.
test "a non-string map key still yields a path segment" {
  let d = ValueDeserializer::new(Map([(Int(7L), Str("oops"))]))
  d.deserialize_struct_begin("X", [])
  try (d.deserialize_field_value() : Int) catch {
    e => inspect(e, content="$.7: invalid type: expected integer, found string")
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
test "a sequence with no length hint still deserializes" {
  let d = ValueDeserializer::new(Seq([Int(1L), Int(2L)]))
  let items : Array[Int] = Deserialize::deserialize(d)
  assert_eq(items, [1, 2])
}

///|
test "a struct field written outside an open struct raises" {
  let s = ValueSerializer::new()
  try s.serialize_field("x", 1) catch {
    e => inspect(e, content="entry written outside an open map")
  } noraise {
    _ => fail("expected a protocol error")
  }
}

// Blackbox tests for the JSON format.
//
// `Point` and `Shape` are deliberately the same shapes used in the core
// package's tests, with the same hand-written implementations. Nothing in them
// mentions JSON — that is the point of the whole design, and the test at the
// bottom checks the identical impls drive both formats.

///|
pub(all) struct Point {
  x : Int
  y : Int
  label : String?
} derive(Eq, Debug)

///|
pub impl @data.Serialize for Point with fn serialize(self, s) {
  s.serialize_struct_begin("Point", 3)
  s.serialize_field("x", self.x)
  s.serialize_field("y", self.y)
  s.serialize_field("label", self.label)
  s.serialize_struct_end()
}

///|
pub impl @data.Deserialize for Point with fn deserialize(d) {
  d.deserialize_struct_begin("Point", ["x", "y", "label"])
  let mut x : Int? = None
  let mut y : Int? = None
  let mut label : String? = None
  while d.deserialize_field_name() is Some(name) {
    match name {
      "x" => x = Some(d.deserialize_field_value())
      "y" => y = Some(d.deserialize_field_value())
      "label" => label = d.deserialize_field_value()
      _ => d.skip_value()
    }
  }
  {
    x: @data.required(x, "x", d.path()),
    y: @data.required(y, "y", d.path()),
    label,
  }
}

///|
pub(all) enum Shape {
  Empty
  Circle(Double)
  Rect(Double, Double)
  Tagged(name~ : String, size~ : Int)
} derive(Eq, Debug)

///|
fn shape_variant(index : Int, name : String) -> @data.VariantInfo {
  { enum_name: "Shape", index, name }
}

///|
pub impl @data.Serialize for Shape with fn serialize(self, s) {
  match self {
    Empty => s.serialize_unit_variant(shape_variant(0, "Empty"))
    Circle(r) => s.serialize_newtype_variant(shape_variant(1, "Circle"), r)
    Rect(w, h) => {
      s.serialize_tuple_variant_begin(shape_variant(2, "Rect"), 2)
      s.serialize_tuple_variant_element(w)
      s.serialize_tuple_variant_element(h)
      s.serialize_tuple_variant_end()
    }
    Tagged(name~, size~) => {
      s.serialize_struct_variant_begin(shape_variant(3, "Tagged"), 2)
      s.serialize_struct_variant_field("name", name)
      s.serialize_struct_variant_field("size", size)
      s.serialize_struct_variant_end()
    }
  }
}

///|
pub impl @data.Deserialize for Shape with fn deserialize(d) {
  let variants = ["Empty", "Circle", "Rect", "Tagged"]
  let shape = match d.deserialize_enum_begin("Shape", variants) {
    "Empty" => {
      d.deserialize_unit_variant()
      Empty
    }
    "Circle" => Circle(d.deserialize_newtype_variant())
    "Rect" => {
      d.deserialize_tuple_begin(2)
      let w : Double = d.deserialize_tuple_next()
      let h : Double = d.deserialize_tuple_next()
      d.deserialize_tuple_end()
      Rect(w, h)
    }
    "Tagged" => {
      d.deserialize_struct_begin("Tagged", ["name", "size"])
      let mut name : String? = None
      let mut size : Int? = None
      while d.deserialize_field_name() is Some(f) {
        match f {
          "name" => name = Some(d.deserialize_field_value())
          "size" => size = Some(d.deserialize_field_value())
          _ => d.skip_value()
        }
      }
      Tagged(
        name=@data.required(name, "name", d.path()),
        size=@data.required(size, "size", d.path()),
      )
    }
    other =>
      raise @data.UnknownVariant(
        path=d.path(),
        variant=other,
        expected=variants,
      )
  }
  d.deserialize_enum_end()
  shape
}

///|
test "primitives write as JSON" {
  inspect(@json.to_string(()), content="null")
  inspect(@json.to_string(true), content="true")
  inspect(@json.to_string(false), content="false")
  inspect(@json.to_string(-42), content="-42")
  inspect(@json.to_string((42 : UInt)), content="42")
  inspect(@json.to_string(-9000000000L), content="-9000000000")
  inspect(@json.to_string(b'\x2a'), content="42")
  inspect(@json.to_string(1.25), content="1.25")
  inspect(@json.to_string("hi"), content="\"hi\"")
  inspect(@json.to_string('x'), content="\"x\"")
}

///|
test "primitives round-trip" {
  assert_eq((@json.from_string(@json.to_string(true)) : Bool), true)
  assert_eq((@json.from_string(@json.to_string(-42)) : Int), -42)
  assert_eq((@json.from_string(@json.to_string((7 : UInt))) : UInt), 7)
  assert_eq(
    (@json.from_string(@json.to_string(-9000000000L)) : Int64),
    -9000000000L,
  )
  assert_eq(
    (@json.from_string(@json.to_string((9000000000 : UInt64))) : UInt64),
    9000000000UL,
  )
  assert_eq((@json.from_string(@json.to_string(1.25)) : Double), 1.25)
  assert_eq((@json.from_string(@json.to_string((1.5 : Float))) : Float), 1.5)
  assert_eq((@json.from_string(@json.to_string('q')) : Char), 'q')
  assert_eq((@json.from_string(@json.to_string("hi")) : String), "hi")
  assert_eq((@json.from_string(@json.to_string(())) : Unit), ())
  assert_eq((@json.from_string(@json.to_string(b'\x2a')) : Byte), b'\x2a')
  assert_eq((@json.from_string(@json.to_string((-7 : Int16))) : Int16), -7)
  assert_eq((@json.from_string(@json.to_string((7 : UInt16))) : UInt16), 7)
}

///|
test "sequences nest and round-trip" {
  let nested : Array[Array[Int]] = [[1, 2], [3], []]
  inspect(@json.to_string(nested), content="[[1,2],[3],[]]")
  assert_eq(
    (@json.from_string(@json.to_string(nested)) : Array[Array[Int]]),
    nested,
  )
  inspect(@json.to_string(([] : Array[Int])), content="[]")
  assert_eq((@json.from_string("[]") : Array[Int]), [])
}

///|
test "options become null" {
  inspect(@json.to_string((None : Int?)), content="null")
  inspect(@json.to_string((Some(3) : Int?)), content="3")
  assert_eq((@json.from_string("null") : Int?), None)
  assert_eq((@json.from_string("3") : Int?), Some(3))
}

///|
test "tuples become arrays" {
  inspect(@json.to_string((1, "two")), content="[1,\"two\"]")
  assert_eq((@json.from_string("[1,\"two\"]") : (Int, String)), (1, "two"))
  assert_eq(
    (@json.from_string(@json.to_string((1, 2.5, false))) : (Int, Double, Bool)),
    (1, 2.5, false),
  )
}

///|
test "bytes become an array of numbers" {
  inspect(@json.to_string(b"\x00\x01\xff"), content="[0,1,255]")
  assert_eq((@json.from_string("[0,1,255]") : Bytes), b"\x00\x01\xff")
  assert_eq((@json.from_string("[]") : Bytes), b"")
}

///|
test "maps become objects, with numeric keys spelled as strings" {
  let m : Map[String, Int] = { "a": 1, "b": 2 }
  inspect(@json.to_string(m), content="{\"a\":1,\"b\":2}")
  assert_eq((@json.from_string(@json.to_string(m)) : Map[String, Int]), m)
  let keyed : Map[Int, String] = { 7: "seven" }
  inspect(@json.to_string(keyed), content="{\"7\":\"seven\"}")
  assert_eq(
    (@json.from_string(@json.to_string(keyed)) : Map[Int, String]),
    keyed,
  )
}

///|
test "structs become objects" {
  let p = Point::{ x: 1, y: 2, label: Some("origin") }
  inspect(@json.to_string(p), content="{\"x\":1,\"y\":2,\"label\":\"origin\"}")
  assert_eq((@json.from_string(@json.to_string(p)) : Point), p)
  let bare = Point::{ x: 0, y: 0, label: None }
  inspect(@json.to_string(bare), content="{\"x\":0,\"y\":0,\"label\":null}")
  assert_eq((@json.from_string(@json.to_string(bare)) : Point), bare)
}

///|
test "structs tolerate missing optional and unknown fields" {
  assert_eq((@json.from_string("{\"x\":1,\"y\":2}") : Point), Point::{
    x: 1,
    y: 2,
    label: None,
  })
  assert_eq(
    (
      @json.from_string("{\"x\":1,\"extra\":[1,{\"deep\":true}],\"y\":2}") :
      Point),
    Point::{ x: 1, y: 2, label: None },
  )
}

///|
test "enums are externally tagged" {
  inspect(@json.to_string(Empty), content="\"Empty\"")
  inspect(@json.to_string(Circle(2.0)), content="{\"Circle\":2}")
  inspect(@json.to_string(Rect(3.0, 4.0)), content="{\"Rect\":[3,4]}")
  inspect(
    @json.to_string(Tagged(name="a", size=1)),
    content="{\"Tagged\":{\"name\":\"a\",\"size\":1}}",
  )
  for shape in [Empty, Circle(2.0), Rect(3.0, 4.0), Tagged(name="a", size=1)] {
    assert_eq((@json.from_string(@json.to_string(shape)) : Shape), shape)
  }
}

///|
test "enums nest inside other containers" {
  let shapes = [Empty, Circle(1.0)]
  inspect(@json.to_string(shapes), content="[\"Empty\",{\"Circle\":1}]")
  assert_eq((@json.from_string(@json.to_string(shapes)) : Array[Shape]), shapes)
  let m : Map[String, Shape] = { "a": Rect(1.0, 2.0) }
  inspect(@json.to_string(m), content="{\"a\":{\"Rect\":[1,2]}}")
  assert_eq((@json.from_string(@json.to_string(m)) : Map[String, Shape]), m)
}

///|
test "strings escape what JSON requires" {
  inspect(
    @json.to_string("quote\" back\\ slash"),
    content="\"quote\\\" back\\\\ slash\"",
  )
  inspect(@json.to_string("a\nb\tc\rd"), content="\"a\\nb\\tc\\rd\"")
  inspect(@json.to_string("\u{0000}\u{001f}"), content="\"\\u0000\\u001f\"")
  // Non-ASCII needs no escape in JSON and is written through.
  inspect(@json.to_string("héllo ☃"), content="\"héllo ☃\"")
}

///|
test "escapes decode, including surrogate pairs" {
  assert_eq((@json.from_string("\"a\\nb\"") : String), "a\nb")
  assert_eq((@json.from_string("\"\\\"\\\\\\/\"") : String), "\"\\/")
  assert_eq((@json.from_string("\"\\u00e9\"") : String), "é")
  assert_eq((@json.from_string("\"\\ud83d\\ude00\"") : String), "😀")
  assert_eq((@json.from_string("\"\\u0008\\u000c\"") : String), "\u{08}\u{0c}")
  // Round-tripping the control characters the writer escapes.
  let tricky = "\u{0000}\u{001f}\"\\\n\t"
  assert_eq((@json.from_string(@json.to_string(tricky)) : String), tricky)
}

///|
test "whitespace between tokens is ignored" {
  assert_eq((@json.from_string("  {\n \"x\" : 1 ,\n \"y\" : 2\n}  ") : Point), Point::{
    x: 1,
    y: 2,
    label: None,
  })
  assert_eq((@json.from_string(" [ 1 , 2 ] ") : Array[Int]), [1, 2])
}

///|
test "Value carries any JSON document, untyped" {
  let text = "{\"a\":[1,-2.5,true,null,\"s\"],\"b\":{}}"
  let value : @data.Value = @json.from_string(text)
  inspect(value, content="{\"a\": [1, -2.5, true, null, \"s\"], \"b\": {}}")
  inspect(@json.to_string(value), content=text)
}

///|
test "large integers widen to unsigned, and overflow is refused" {
  inspect(
    (@json.from_string("18446744073709551615") : @data.Value),
    content="18446744073709551615",
  )
  inspect(
    (@json.from_string("1.7e308") : @data.Value),
    content=(
      #|1.7e+308
    ),
  )
  // Symmetric with refusing to *write* infinity: a literal that overflows a
  // Double is an error rather than a silent Infinity.
  try (@json.from_string("1e400") : @data.Value) catch {
    e => inspect(e, content="$: invalid value: expected a number, found 1e400")
  } noraise {
    _ => fail("expected an overflow error")
  }
}

///|
/// The thesis of the whole design: one pair of hand-written implementations,
/// two formats, no format-specific code in the type.
test "the same implementation drives both formats" {
  let p = Point::{ x: 5, y: 6, label: None }
  inspect(@data.to_value(p), content="{\"x\": 5, \"y\": 6, \"label\": null}")
  inspect(@json.to_string(p), content="{\"x\":5,\"y\":6,\"label\":null}")
  assert_eq((@data.from_value(@data.to_value(p)) : Point), p)
  assert_eq((@json.from_string(@json.to_string(p)) : Point), p)
}

///|
test "errors report the path into the document" {
  try (@json.from_string("[1,\"nope\"]") : Array[Int]) catch {
    e =>
      inspect(e, content="$[1]: invalid type: expected a number, found string")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@json.from_string("[{\"x\":1,\"y\":\"oops\"}]") : Array[Point]) catch {
    e =>
      inspect(
        e,
        content="$[0].y: invalid type: expected a number, found string",
      )
  } noraise {
    _ => fail("expected a type error")
  }
  try
    (
      @json.from_string("{\"a\":{\"b\":[0,false]}}") :
      Map[String, Map[String, Array[Int]]])
  catch {
    e =>
      inspect(
        e,
        content="$.a.b[1]: invalid type: expected a number, found boolean",
      )
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
test "malformed input is rejected" {
  try (@json.from_string("{\"x\":1,\"y\":2} trailing") : Point) catch {
    e => inspect(e, content="$: trailing input after value")
  } noraise {
    _ => fail("expected a trailing input error")
  }
  try (@json.from_string("[1,2") : Array[Int]) catch {
    e =>
      inspect(
        e,
        content=(
          #|$[1]: unexpected end of input
        ),
      )
  } noraise {
    _ => fail("expected an end of input error")
  }
  try (@json.from_string("[1 2]") : Array[Int]) catch {
    e =>
      inspect(
        e,
        content=(
          #|$[0]: expected `,`, found `2`
        ),
      )
  } noraise {
    _ => fail("expected a syntax error")
  }
  try (@json.from_string("nul") : Unit) catch {
    e => inspect(e, content="$: invalid literal, expected `null`")
  } noraise {
    _ => fail("expected a syntax error")
  }
}

///|
test "bad string escapes are rejected" {
  try (@json.from_string("\"\\q\"") : String) catch {
    e => inspect(e, content="$: unknown escape `\\q`")
  } noraise {
    _ => fail("expected an escape error")
  }
  try (@json.from_string("\"\\u00zz\"") : String) catch {
    e => inspect(e, content="$: invalid `\\u` escape: `z` is not a hex digit")
  } noraise {
    _ => fail("expected an escape error")
  }
  try (@json.from_string("\"\\ud83d\"") : String) catch {
    e =>
      inspect(
        e,
        content="$: high surrogate escape is not followed by a low surrogate",
      )
  } noraise {
    _ => fail("expected a surrogate error")
  }
  try (@json.from_string("\"\\udc00\"") : String) catch {
    e => inspect(e, content="$: unpaired low surrogate escape")
  } noraise {
    _ => fail("expected a surrogate error")
  }
  try (@json.from_string("\"raw\u{0001}\"") : String) catch {
    e => inspect(e, content="$: unescaped control character in string")
  } noraise {
    _ => fail("expected a control character error")
  }
}

///|
test "what JSON cannot represent is refused rather than mangled" {
  try @json.to_string(@double.not_a_number) catch {
    e => inspect(e, content="JSON cannot serialize NaN or infinity")
  } noraise {
    _ => fail("expected an unsupported type error")
  }
  try @json.to_string(@double.infinity) catch {
    e => inspect(e, content="JSON cannot serialize NaN or infinity")
  } noraise {
    _ => fail("expected an unsupported type error")
  }
  let bad_keys : Map[Bool, Int] = { true: 1 }
  try @json.to_string(bad_keys) catch {
    e => inspect(e, content="JSON cannot serialize a boolean as an object key")
  } noraise {
    _ => fail("expected an unsupported type error")
  }
}

///|
test "unknown enum variants name the ones that exist" {
  try (@json.from_string("\"Triangle\"") : Shape) catch {
    e =>
      inspect(
        e,
        content="$: unknown variant `Triangle`, expected one of Empty, Circle, Rect, Tagged",
      )
  } noraise {
    _ => fail("expected an unknown variant error")
  }
  try (@json.from_string("{\"Hexagon\":1}") : Shape) catch {
    e =>
      inspect(
        e,
        content="$: unknown variant `Hexagon`, expected one of Empty, Circle, Rect, Tagged",
      )
  } noraise {
    _ => fail("expected an unknown variant error")
  }
}

///|
test "a missing required field is reported by name" {
  try (@json.from_string("{\"x\":1}") : Point) catch {
    e => inspect(e, content="$: missing field `y`")
  } noraise {
    _ => fail("expected a missing field error")
  }
}

///|
test "integers out of range for the target width are rejected" {
  try (@json.from_string("300") : Byte) catch {
    e => inspect(e, content="$: invalid value: expected a byte, found 300")
  } noraise {
    _ => fail("expected a range error")
  }
  try (@json.from_string("-1") : UInt) catch {
    e => inspect(e, content="$: invalid value: expected a uint, found -1")
  } noraise {
    _ => fail("expected a range error")
  }
}

///|
test "the remaining escape forms decode" {
  assert_eq((@json.from_string("\"\\b\\f\\r\"") : String), "\u{08}\u{0c}\r")
  // Hex digits are accepted in either case.
  assert_eq((@json.from_string("\"\\u00E9\"") : String), "é")
}

///|
test "broken surrogate pairs are rejected in every form" {
  try (@json.from_string("\"\\ud83dab\"") : String) catch {
    e =>
      inspect(
        e,
        content="$: high surrogate escape is not followed by a low surrogate",
      )
  } noraise {
    _ => fail("expected a surrogate error")
  }
  try (@json.from_string("\"\\ud83d\\u0041\"") : String) catch {
    e =>
      inspect(
        e,
        content="$: high surrogate escape is not followed by a low surrogate",
      )
  } noraise {
    _ => fail("expected a surrogate error")
  }
}

///|
test "an unterminated or mistyped string is rejected" {
  try (@json.from_string("\"abc") : String) catch {
    e => inspect(e, content="$: unexpected end of input")
  } noraise {
    _ => fail("expected an end of input error")
  }
  try (@json.from_string("123") : String) catch {
    e => inspect(e, content="$: invalid type: expected string, found a number")
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
test "numbers that do not fit the requested type are rejected" {
  try (@json.from_string("1.5") : Int64) catch {
    e => inspect(e, content="$: invalid value: expected an integer, found 1.5")
  } noraise {
    _ => fail("expected a value error")
  }
  try (@json.from_string("1e400") : Double) catch {
    e => inspect(e, content="$: invalid value: expected a number, found 1e400")
  } noraise {
    _ => fail("expected a value error")
  }
  try (@json.from_string("-1") : UInt64) catch {
    e =>
      inspect(
        e,
        content="$: invalid value: expected an unsigned integer, found -1",
      )
  } noraise {
    _ => fail("expected a value error")
  }
}

///|
test "an integer too large for any integer type widens to a float" {
  inspect(
    (@json.from_string("999999999999999999999999999999") : @data.Value),
    content="1e+30",
  )
}

///|
test "an integer too large even for a float is refused" {
  let huge = StringBuilder::new()
  huge.write_char('1')
  for _ in 0..<400 {
    huge.write_char('0')
  }
  let text = huge.to_string()
  try (@json.from_string(text) : @data.Value) catch {
    e =>
      inspect(e, content="$: invalid value: expected a number, found \{text}")
  } noraise {
    _ => fail("expected an overflow error")
  }
}

///|
test "the remaining primitives report their expected type on mismatch" {
  try (@json.from_string("1") : Bool) catch {
    e => inspect(e, content="$: invalid type: expected boolean, found a number")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@json.from_string("1") : Bytes) catch {
    e =>
      inspect(
        e,
        content="$: invalid type: expected byte string, found a number",
      )
  } noraise {
    _ => fail("expected a type error")
  }
  try (@json.from_string("\"ab\"") : Char) catch {
    e =>
      inspect(
        e,
        content="$: invalid value: expected a single character, found ab",
      )
  } noraise {
    _ => fail("expected a value error")
  }
}

///|
test "a tuple with too few elements reports end of input" {
  try (@json.from_string("[1]") : (Int, Int)) catch {
    e =>
      inspect(
        e,
        content=(
          #|$[0]: unexpected end of input
        ),
      )
  } noraise {
    _ => fail("expected an end of input error")
  }
}

///|
test "malformed literals say so instead of guessing a type" {
  inspect((@json.from_string("false") : @data.Value), content="false")
  for text in ["tru", "fals", "nul"] {
    try (@json.from_string(text) : @data.Value) catch {
      e => inspect(e is @data.DeCustom(..), content="true")
    } noraise {
      _ => fail("expected a literal error")
    }
  }
  try (@json.from_string("nul") : Unit) catch {
    e => inspect(e, content="$: invalid literal, expected `null`")
  } noraise {
    _ => fail("expected a literal error")
  }
  try (@json.from_string("tru") : Bool) catch {
    e => inspect(e, content="$: invalid literal, expected `true` or `false`")
  } noraise {
    _ => fail("expected a literal error")
  }
}

///|
test "a non-null value is not a unit" {
  try (@json.from_string("1") : Unit) catch {
    e => inspect(e, content="$: invalid type: expected unit, found a number")
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
/// The byte API is the real one; `to_string` / `from_string` are conveniences
/// layered on it. These check the bytes directly.
test "the transport is UTF-8 bytes" {
  assert_eq(@json.to_bytes(42), b"42")
  assert_eq(@json.to_bytes("hi"), b"\x22hi\x22")
  assert_eq((@json.from_bytes(b"42") : Int), 42)
  assert_eq((@json.from_bytes(b"[1,2]") : Array[Int]), [1, 2])
}

///|
test "non-ASCII text survives as UTF-8, not UTF-16" {
  // é is two UTF-8 bytes, ☃ is three, 😀 is four (a surrogate pair in UTF-16).
  let text = "é☃😀"
  let bytes = @json.to_bytes(text)
  assert_eq(bytes.length(), 1 + 2 + 3 + 4 + 1)
  assert_eq((@json.from_bytes(bytes) : String), text)
  // And the same text arriving as an escape sequence decodes identically.
  assert_eq(
    (@json.from_bytes(b"\x22\\u00e9\\u2603\\ud83d\\ude00\x22") : String),
    text,
  )
}

///|
test "invalid UTF-8 in the input is rejected" {
  // 0xFF is not a legal UTF-8 lead byte.
  try (@json.from_bytes(b"\x22a\xffb\x22") : String) catch {
    e => inspect(e, content="$: input is not valid UTF-8")
  } noraise {
    _ => fail("expected an encoding error")
  }
}

///|
test "a document round-trips through bytes without a String anywhere" {
  let p = Point::{ x: 1, y: 2, label: Some("é") }
  let bytes = @json.to_bytes(p)
  assert_eq(bytes, b"{\x22x\x22:1,\x22y\x22:2,\x22label\x22:\x22\xc3\xa9\x22}")
  assert_eq((@json.from_bytes(bytes) : Point), p)
}

///|
/// Integers are parsed from the input bytes rather than through a `String`,
/// so the boundary cases are ours to get right rather than core's.
test "integers parse exactly at the limits of their width" {
  assert_eq(
    (@json.from_string("9223372036854775807") : Int64),
    9223372036854775807L,
  )
  // The asymmetric end: the magnitude does not fit in a positive Int64, so it
  // is only reachable through two's complement negation.
  assert_eq(
    (@json.from_string("-9223372036854775808") : Int64),
    -9223372036854775807L - 1L,
  )
  assert_eq(
    (@json.from_string("18446744073709551615") : UInt64),
    18446744073709551615UL,
  )
  assert_eq((@json.from_string("0") : Int64), 0L)
  assert_eq((@json.from_string("-0") : Int64), 0L)
}

///|
test "integers beyond 64 bits are refused, not truncated" {
  try (@json.from_string("9223372036854775808") : Int64) catch {
    e =>
      inspect(
        e,
        content="$: invalid value: expected an integer that fits in 64 bits, found 9223372036854775808",
      )
  } noraise {
    _ => fail("expected an overflow error")
  }
  try (@json.from_string("-9223372036854775809") : Int64) catch {
    e =>
      inspect(
        e,
        content="$: invalid value: expected an integer that fits in 64 bits, found -9223372036854775809",
      )
  } noraise {
    _ => fail("expected an overflow error")
  }
  try (@json.from_string("18446744073709551616") : UInt64) catch {
    e =>
      inspect(
        e,
        content="$: invalid value: expected an unsigned integer that fits in 64 bits, found 18446744073709551616",
      )
  } noraise {
    _ => fail("expected an overflow error")
  }
}

///|
test "a float literal is not accepted where an integer is asked for" {
  try (@json.from_string("1.5") : Int64) catch {
    e => inspect(e, content="$: invalid value: expected an integer, found 1.5")
  } noraise {
    _ => fail("expected a value error")
  }
  try (@json.from_string("-1") : UInt64) catch {
    e =>
      inspect(
        e,
        content="$: invalid value: expected an unsigned integer, found -1",
      )
  } noraise {
    _ => fail("expected a value error")
  }
}

///|
/// A fast float path that is subtly wrong is worse than none, so it is checked
/// differentially: every input must produce the *same bits* as core's exact
/// `@string.parse_double`, not merely a close value.
fn same_bits(text : String) -> Bool {
  let mine = @json.parse_double_bytes(@utf8.encode(text))
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

///|
/// Escapes are ASCII while the text around them may not be, so these put an
/// escape immediately either side of a surrogate pair.
test "escapes adjacent to a surrogate pair" {
  let cases = [
    "😀", "a😀b", "\"😀\"", "\\😀\\", "\n😀\n", "\u{0000}😀\u{001f}",
    "😀😀😀", "é☃😀", "\t😀", "😀\r",
  ]
  for text in cases {
    assert_eq((@json.from_string(@json.to_string(text)) : String), text)
  }
  // And the bytes are the ones a reader would expect, not a mangled pair.
  inspect(@json.to_string("\"😀\""), content="\"\\\"😀\\\"\"")
  assert_eq(@json.to_bytes("😀"), b"\x22\xf0\x9f\x98\x80\x22")
}

///|
test "escaping is unchanged by the run-based writer" {
  inspect(@json.to_string("a\"b\\c"), content="\"a\\\"b\\\\c\"")
  inspect(@json.to_string("\n\r\t"), content="\"\\n\\r\\t\"")
  // Control characters with no short escape take the \u00XX long form.
  inspect(
    @json.to_string("\u{0000}\u{0001}\u{001f}"),
    content="\"\\u0000\\u0001\\u001f\"",
  )
  inspect(@json.to_string(""), content="\"\"")
  // A string that needs no escaping at all: the common case, one run.
  inspect(@json.to_string("plain ascii"), content="\"plain ascii\"")
}

///|
/// Known field and variant names are returned by identity from the caller's
/// own array rather than allocated. These check the paths that makes possible,
/// including the ones that must still fall back.
test "identifiers resolve however they are spelled" {
  // Plain match against a declared name.
  assert_eq((@json.from_string("{\"x\":1,\"y\":2}") : Point), Point::{
    x: 1,
    y: 2,
    label: None,
  })
  // An escaped key spells the same field, so it must still be recognised even
  // though a raw byte comparison cannot see it.
  assert_eq((@json.from_string("{\"\\u0078\":1,\"y\":2}") : Point), Point::{
    x: 1,
    y: 2,
    label: None,
  })
  // A key that is a prefix or extension of a declared one must not match.
  try (@json.from_string("{\"x\":1,\"yy\":2}") : Point) catch {
    e => inspect(e, content="$: missing field `y`")
  } noraise {
    _ => fail("expected a missing field error")
  }
  // Unknown fields are still skipped, and non-ASCII keys do not crash.
  assert_eq(
    (@json.from_string("{\"x\":1,\"héllo\":0,\"\":0,\"y\":2}") : Point),
    Point::{ x: 1, y: 2, label: None },
  )
}

///|
test "variant names resolve however they are spelled" {
  assert_eq((@json.from_string("\"Empty\"") : Shape), Empty)
  assert_eq((@json.from_string("\"\\u0045mpty\"") : Shape), Empty)
  assert_eq((@json.from_string("{\"Circle\":2}") : Shape), Circle(2.0))
  try (@json.from_string("\"Empt\"") : Shape) catch {
    e =>
      inspect(
        e,
        content="$: unknown variant `Empt`, expected one of Empty, Circle, Rect, Tagged",
      )
  } noraise {
    _ => fail("expected an unknown variant error")
  }
}

///|
test "strings with and without escapes both round-trip" {
  // The no-escape path returns one contiguous span; the escape path builds.
  for
    text in [
      "", "plain", "a\"b", "a\\b", "\\", "\"", "tab\there", "nl\nhere", "\u{0000}",
      "é☃😀", "mixed é \" and 😀 \\ escapes", "trailing\\",
    ] {
    let encoded = @json.to_string(text)
    assert_eq((@json.from_string(encoded) : String), text)
  }
}

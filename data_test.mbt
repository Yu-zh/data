// Blackbox tests: everything here goes through the public `@data` API.
//
// `Point` and `Shape` double as the worked examples of what a hand-written
// implementation looks like — they are what a derive macro would emit if
// MoonBit had user-defined derives.

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
  let fields = ["x", "y", "label"]
  d.deserialize_struct_begin("Point", fields)
  let mut x : Int? = None
  let mut y : Int? = None
  // An absent `label` and an explicit null are both `None`, matching serde's
  // treatment of `Option` fields.
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
/// Exercises all four payload shapes an enum variant can take.
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
    0 => {
      d.deserialize_unit_variant()
      Empty
    }
    1 => Circle(d.deserialize_newtype_variant())
    2 => {
      d.deserialize_tuple_begin(2)
      let w : Double = d.deserialize_tuple_next()
      let h : Double = d.deserialize_tuple_next()
      d.deserialize_tuple_end()
      Rect(w, h)
    }
    3 => {
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
    index =>
      raise @data.UnknownVariant(
        path=d.path(),
        variant=index.to_string(),
        expected=variants,
      )
  }
  d.deserialize_enum_end()
  shape
}

///|
test "primitives round-trip through the data model" {
  assert_eq(@data.from_value(@data.to_value(true)), true)
  assert_eq(@data.from_value(@data.to_value(b'\x2a')), b'\x2a')
  assert_eq(@data.from_value(@data.to_value((-7 : Int16))), (-7 : Int16))
  assert_eq(@data.from_value(@data.to_value((7 : UInt16))), (7 : UInt16))
  assert_eq(@data.from_value(@data.to_value(-42)), -42)
  assert_eq(@data.from_value(@data.to_value((42 : UInt))), (42 : UInt))
  assert_eq(@data.from_value(@data.to_value(-9000000000L)), -9000000000L)
  assert_eq(
    @data.from_value(@data.to_value((9000000000 : UInt64))),
    (9000000000 : UInt64),
  )
  assert_eq(@data.from_value(@data.to_value((1.5 : Float))), (1.5 : Float))
  assert_eq(@data.from_value(@data.to_value(1.25)), 1.25)
  assert_eq(@data.from_value(@data.to_value('x')), 'x')
  assert_eq(@data.from_value(@data.to_value("hello")), "hello")
  assert_eq(@data.from_value(@data.to_value(b"\x01\x02")), b"\x01\x02")
  assert_eq(@data.from_value(@data.to_value(())), ())
}

///|
test "primitives land on the expected data model shapes" {
  inspect(@data.to_value(true), content="true")
  inspect(@data.to_value(-42), content="-42")
  inspect(@data.to_value((42 : UInt)), content="42")
  inspect(@data.to_value(1.25), content="1.25")
  inspect(@data.to_value("hi"), content="\"hi\"")
  inspect(@data.to_value('x'), content="\"x\"")
  inspect(@data.to_value(()), content="null")
  inspect(@data.to_value(b"\x01\xff"), content="b\"01ff\"")
}

///|
test "sequences nest" {
  let nested : Array[Array[Int]] = [[1, 2], [3], []]
  inspect(@data.to_value(nested), content="[[1, 2], [3], []]")
  let back : Array[Array[Int]] = @data.from_value(@data.to_value(nested))
  assert_eq(back, nested)
}

///|
test "options distinguish present from absent" {
  let some : Int? = Some(3)
  let none : Int? = None
  inspect(@data.to_value(some), content="3")
  inspect(@data.to_value(none), content="null")
  assert_eq(@data.from_value(@data.to_value(some)), some)
  assert_eq(@data.from_value(@data.to_value(none)), none)
}

///|
test "maps keep insertion order and allow non-string keys" {
  let m = { "a": 1, "b": 2 }
  inspect(@data.to_value(m), content="{\"a\": 1, \"b\": 2}")
  let back : Map[String, Int] = @data.from_value(@data.to_value(m))
  assert_eq(back, m)
  let keyed : Map[Int, String] = { 1: "one" }
  inspect(@data.to_value(keyed), content="{1: \"one\"}")
}

///|
test "tuples are fixed-length sequences" {
  let pair = (1, "two")
  inspect(@data.to_value(pair), content="[1, \"two\"]")
  assert_eq(@data.from_value(@data.to_value(pair)), pair)
  let triple = (1, 2.5, false)
  assert_eq(@data.from_value(@data.to_value(triple)), triple)
}

///|
test "structs round-trip" {
  let p = Point::{ x: 1, y: 2, label: Some("origin") }
  inspect(
    @data.to_value(p),
    content="{\"x\": 1, \"y\": 2, \"label\": \"origin\"}",
  )
  assert_eq(@data.from_value(@data.to_value(p)), p)
  let bare = Point::{ x: 0, y: 0, label: None }
  inspect(@data.to_value(bare), content="{\"x\": 0, \"y\": 0, \"label\": null}")
  assert_eq(@data.from_value(@data.to_value(bare)), bare)
}

///|
test "structs tolerate a missing option field and an unknown field" {
  let partial : @data.Value = Map([(Str(b"x"), Int(1L)), (Str(b"y"), Int(2L))])
  assert_eq(@data.from_value(partial), Point::{ x: 1, y: 2, label: None })
  let extra : @data.Value = Map([
    (Str(b"x"), Int(1L)),
    (Str(b"nope"), Str(b"ignored")),
    (Str(b"y"), Int(2L)),
  ])
  assert_eq(@data.from_value(extra), Point::{ x: 1, y: 2, label: None })
}

///|
test "all four enum variant shapes round-trip, externally tagged" {
  inspect(@data.to_value(Empty), content="\"Empty\"")
  inspect(@data.to_value(Circle(2.0)), content="{\"Circle\": 2}")
  inspect(@data.to_value(Rect(3.0, 4.0)), content="{\"Rect\": [3, 4]}")
  inspect(
    @data.to_value(Tagged(name="a", size=1)),
    content="{\"Tagged\": {\"name\": \"a\", \"size\": 1}}",
  )
  for shape in [Empty, Circle(2.0), Rect(3.0, 4.0), Tagged(name="a", size=1)] {
    assert_eq(@data.from_value(@data.to_value(shape)), shape)
  }
}

///|
test "Value is itself part of the data model" {
  let v : @data.Value = Map([(Str(b"xs"), Seq([Int(1L), Null, Boolean(true)]))])
  assert_eq(@data.from_value(@data.to_value(v)), v)
}

///|
test "type mismatch reports the path where it happened" {
  let bad : @data.Value = Seq([Int(1L), Str(b"nope")])
  try (@data.from_value(bad) : Array[Int]) catch {
    e =>
      inspect(e, content="$[1]: invalid type: expected integer, found string")
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
test "nested paths accumulate through structs and sequences" {
  let bad : @data.Value = Seq([
    Map([(Str(b"x"), Int(1L)), (Str(b"y"), Str(b"oops"))]),
  ])
  try (@data.from_value(bad) : Array[Point]) catch {
    e =>
      inspect(e, content="$[0].y: invalid type: expected integer, found string")
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
test "a missing required field is reported by name" {
  let bad : @data.Value = Map([(Str(b"x"), Int(1L))])
  try (@data.from_value(bad) : Point) catch {
    e => inspect(e, content="$: missing field `y`")
  } noraise {
    _ => fail("expected a missing field error")
  }
}

///|
test "an unknown variant lists the ones that exist" {
  let bad : @data.Value = Str(b"Triangle")
  try (@data.from_value(bad) : Shape) catch {
    e =>
      inspect(
        e,
        content="$: unknown variant `Triangle`, expected one of Empty, Circle, Rect, Tagged",
      )
  } noraise {
    _ => fail("expected an unknown variant error")
  }
}

///|
test "integers that do not fit the target width are rejected" {
  try (@data.from_value(Int(300L)) : Byte) catch {
    e => inspect(e, content="$: invalid value: expected a byte, found 300")
  } noraise {
    _ => fail("expected a range error")
  }
  try (@data.from_value(Int(-1L)) : UInt) catch {
    e => inspect(e, content="$: invalid value: expected a uint, found -1")
  } noraise {
    _ => fail("expected a range error")
  }
}

///|
/// A unit struct and a newtype struct, to exercise the two `Serializer`
/// defaults that widen to unit and to the inner value.
pub(all) struct Marker {} derive(Eq, Debug)

///|
pub impl @data.Serialize for Marker with fn serialize(_self, s) {
  s.serialize_unit_struct("Marker")
}

///|
pub impl @data.Deserialize for Marker with fn deserialize(d) {
  d.deserialize_unit_struct("Marker")
  Marker::{  }
}

///|
pub(all) struct Meters(Double) derive(Eq, Debug)

///|
pub impl @data.Serialize for Meters with fn serialize(self, s) {
  s.serialize_newtype_struct("Meters", self.0)
}

///|
pub impl @data.Deserialize for Meters with fn deserialize(d) {
  Meters(d.deserialize_newtype_struct("Meters"))
}

///|
test "unit and newtype structs are transparent" {
  inspect(@data.to_value(Marker::{  }), content="null")
  assert_eq(@data.from_value(@data.to_value(Marker::{  })), Marker::{  })
  inspect(@data.to_value(Meters(2.5)), content="2.5")
  assert_eq(@data.from_value(@data.to_value(Meters(2.5))), Meters(2.5))
}

///|
test "FixedArray round-trips as a sequence" {
  let fa : FixedArray[Int] = [1, 2, 3]
  inspect(@data.to_value(fa), content="[1, 2, 3]")
  let back : FixedArray[Int] = @data.from_value(@data.to_value(fa))
  assert_eq(back, fa)
}

///|
test "every Value constructor survives a round-trip" {
  let v : @data.Value = Seq([
    Null,
    Boolean(false),
    Int(-1L),
    UInt(18446744073709551615UL),
    Double(0.5),
    Str(b"s"),
    Bytes(b"\x00\xff"),
    Map([(Int(1L), Str(b"keyed"))]),
  ])
  assert_eq(@data.from_value(@data.to_value(v)), v)
}

///|
test "wrong primitive shapes are reported with the expected type" {
  try (@data.from_value(Int(1L)) : String) catch {
    e => inspect(e, content="$: invalid type: expected string, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@data.from_value(Int(1L)) : Bytes) catch {
    e =>
      inspect(e, content="$: invalid type: expected byte string, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@data.from_value(Str(b"ab")) : Char) catch {
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
test "a tuple that runs out of elements reports end of input" {
  try (@data.from_value(Seq([Int(1L)])) : (Int, Int)) catch {
    e => inspect(e, content="$: unexpected end of input")
  } noraise {
    _ => fail("expected an end of input error")
  }
}

///|
test "enums reject unknown payload variants and non-enum shapes" {
  try (@data.from_value(Map([(Str(b"Hexagon"), Int(1L))])) : Shape) catch {
    e =>
      inspect(
        e,
        content="$: unknown variant `Hexagon`, expected one of Empty, Circle, Rect, Tagged",
      )
  } noraise {
    _ => fail("expected an unknown variant error")
  }
  try (@data.from_value(Int(1L)) : Shape) catch {
    e => inspect(e, content="$: invalid type: expected enum, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
test "a struct with a non-string key is rejected" {
  try (@data.from_value(Map([(Int(1L), Int(2L))])) : Point) catch {
    e =>
      inspect(
        e,
        content="$: invalid type: expected a string field name, found integer",
      )
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
/// A tuple struct, exercising the defaults that route tuple structs through
/// the tuple protocol and on to sequences.
pub(all) struct Rgb(Int, Int, Int) derive(Eq, Debug)

///|
pub impl @data.Serialize for Rgb with fn serialize(self, s) {
  s.serialize_tuple_struct_begin("Rgb", 3)
  s.serialize_tuple_struct_field(self.0)
  s.serialize_tuple_struct_field(self.1)
  s.serialize_tuple_struct_field(self.2)
  s.serialize_tuple_struct_end()
}

///|
pub impl @data.Deserialize for Rgb with fn deserialize(d) {
  d.deserialize_tuple_struct_begin("Rgb", 3)
  let r : Int = d.deserialize_tuple_next()
  let g : Int = d.deserialize_tuple_next()
  let b : Int = d.deserialize_tuple_next()
  d.deserialize_tuple_end()
  Rgb(r, g, b)
}

///|
test "tuple structs round-trip as sequences" {
  let c = Rgb(1, 2, 3)
  inspect(@data.to_value(c), content="[1, 2, 3]")
  assert_eq(@data.from_value(@data.to_value(c)), c)
}

///|
test "integers widen into floats but not across the signed boundary" {
  assert_eq((@data.from_value(Int(3L)) : Double), 3.0)
  assert_eq((@data.from_value(UInt(3UL)) : Double), 3.0)
  try (@data.from_value(UInt(18446744073709551615UL)) : Int64) catch {
    e =>
      inspect(
        e,
        content="$: invalid value: expected a signed integer, found 18446744073709551615",
      )
  } noraise {
    _ => fail("expected a value error")
  }
  try (@data.from_value(Int(-1L)) : UInt64) catch {
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
test "containers reject values of the wrong shape" {
  try (@data.from_value(Int(1L)) : Array[Int]) catch {
    e => inspect(e, content="$: invalid type: expected sequence, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@data.from_value(Int(1L)) : Map[String, Int]) catch {
    e => inspect(e, content="$: invalid type: expected map, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@data.from_value(Int(1L)) : Point) catch {
    e => inspect(e, content="$: invalid type: expected map, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
test "remaining primitives report their expected type on mismatch" {
  try (@data.from_value(Int(1L)) : Unit) catch {
    e => inspect(e, content="$: invalid type: expected unit, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@data.from_value(Int(1L)) : Bool) catch {
    e => inspect(e, content="$: invalid type: expected boolean, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@data.from_value(Int(1L)) : Char) catch {
    e => inspect(e, content="$: invalid type: expected char, found integer")
  } noraise {
    _ => fail("expected a type error")
  }
  try (@data.from_value(Str(b"x")) : UInt64) catch {
    e =>
      inspect(
        e,
        content="$: invalid type: expected unsigned integer, found string",
      )
  } noraise {
    _ => fail("expected a type error")
  }
  try (@data.from_value(Str(b"x")) : Double) catch {
    e => inspect(e, content="$: invalid type: expected float, found string")
  } noraise {
    _ => fail("expected a type error")
  }
  assert_eq((@data.from_value(Int(5L)) : UInt64), 5UL)
}

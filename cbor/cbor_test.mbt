// Tests for the CBOR codec.
//
// The encoding tests check against RFC 8949 Appendix A rather than against
// this package's own decoder: a codec that agrees with itself proves nothing
// about interoperating, which is the only reason to prefer CBOR over the
// ad-hoc binary format in the root package's tests.

///|
fn hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder::new()
  for b in bytes {
    let v = b.to_int()
    out.write_char(digits.to_array()[v >> 4])
    out.write_char(digits.to_array()[v & 0xF])
  }
  out.to_string()
}

///|
fn unhex(text : String) -> Bytes {
  let chars = text.to_array()
  let out = Array::new(capacity=chars.length() / 2)
  fn nibble(c : Char) -> Int {
    let v = c.to_int()
    if v >= 0x30 && v <= 0x39 {
      v - 0x30
    } else {
      v - 0x61 + 10
    }
  }

  for i = 0; i < chars.length(); i = i + 2 {
    out.push(((nibble(chars[i]) << 4) | nibble(chars[i + 1])).to_byte())
  }
  Bytes::from_array(out[:])
}

// ---- RFC 8949 Appendix A, the encoding half ----

///|
test "integers encode as the RFC's examples" {
  inspect(hex(@cbor.to_bytes(0)), content="00")
  inspect(hex(@cbor.to_bytes(1)), content="01")
  inspect(hex(@cbor.to_bytes(10)), content="0a")
  inspect(hex(@cbor.to_bytes(23)), content="17")
  inspect(hex(@cbor.to_bytes(24)), content="1818")
  inspect(hex(@cbor.to_bytes(25)), content="1819")
  inspect(hex(@cbor.to_bytes(100)), content="1864")
  inspect(hex(@cbor.to_bytes(1000)), content="1903e8")
  inspect(hex(@cbor.to_bytes(1000000)), content="1a000f4240")
  inspect(hex(@cbor.to_bytes(1000000000000L)), content="1b000000e8d4a51000")
  inspect(hex(@cbor.to_bytes(-1)), content="20")
  inspect(hex(@cbor.to_bytes(-10)), content="29")
  inspect(hex(@cbor.to_bytes(-100)), content="3863")
  inspect(hex(@cbor.to_bytes(-1000)), content="3903e7")
}

///|
test "the integer boundaries encode without overflowing" {
  inspect(
    hex(@cbor.to_bytes(18446744073709551615UL)),
    content="1bffffffffffffffff",
  )
  inspect(
    hex(@cbor.to_bytes(-9223372036854775808L)),
    content="3b7fffffffffffffff",
  )
  inspect(
    hex(@cbor.to_bytes(9223372036854775807L)),
    content="1b7fffffffffffffff",
  )
}

///|
test "simple values and floats encode as the RFC's examples" {
  inspect(hex(@cbor.to_bytes(false)), content="f4")
  inspect(hex(@cbor.to_bytes(true)), content="f5")
  inspect(hex(@cbor.to_bytes(())), content="f6")
  inspect(hex(@cbor.to_bytes(1.5)), content="fb3ff8000000000000")
  inspect(hex(@cbor.to_bytes(1.0e300)), content="fb7e37e43c8800759c")
  inspect(hex(@cbor.to_bytes((100000.0 : Float))), content="fa47c35000")
}

///|
test "strings and byte strings encode as the RFC's examples" {
  inspect(hex(@cbor.to_bytes("")), content="60")
  inspect(hex(@cbor.to_bytes("a")), content="6161")
  inspect(hex(@cbor.to_bytes("IETF")), content="6449455446")
  inspect(hex(@cbor.to_bytes("ü")), content="62c3bc")
  inspect(hex(@cbor.to_bytes("水")), content="63e6b0b4")
  inspect(hex(@cbor.to_bytes(b"")), content="40")
  inspect(hex(@cbor.to_bytes(b"\x01\x02\x03\x04")), content="4401020304")
}

///|
/// The one that JSON cannot do. A byte string is its own major type, so it
/// survives as bytes rather than as an array of small integers.
test "bytes stay bytes rather than becoming an array of numbers" {
  inspect(hex(@cbor.to_bytes(b"\x01\x02\x03\x04")), content="4401020304")
  inspect(hex(@cbor.to_bytes([1, 2, 3, 4])), content="8401020304")
  assert_eq(
    (@cbor.from_bytes(@cbor.to_bytes(b"\x01\x02\x03\x04")) : Bytes),
    b"\x01\x02\x03\x04",
  )
}

///|
test "arrays and maps encode as the RFC's examples" {
  inspect(hex(@cbor.to_bytes(([] : Array[Int]))), content="80")
  inspect(hex(@cbor.to_bytes([1, 2, 3])), content="83010203")
  inspect(
    hex(
      @cbor.to_bytes([
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
        22, 23, 24, 25,
      ]),
    ),
    content="98190102030405060708090a0b0c0d0e0f101112131415161718181819",
  )
}

///|
/// The other thing JSON cannot do: a map key that is not a string.
test "map keys need not be strings" {
  let m : Map[Int, String] = { 1: "a", 2: "b" }
  let round : Map[Int, String] = @cbor.from_bytes(@cbor.to_bytes(m))
  assert_eq(round, m)
  inspect(hex(@cbor.to_bytes(m)), content="a2016161026162")
}

// ---- RFC 8949 Appendix A, the decoding half ----

///|
test "the RFC's encodings decode to the values they denote" {
  assert_eq((@cbor.from_bytes(unhex("00")) : Int), 0)
  assert_eq((@cbor.from_bytes(unhex("1903e8")) : Int), 1000)
  assert_eq((@cbor.from_bytes(unhex("3903e7")) : Int), -1000)
  assert_eq((@cbor.from_bytes(unhex("f5")) : Bool), true)
  assert_eq((@cbor.from_bytes(unhex("6449455446")) : String), "IETF")
  assert_eq((@cbor.from_bytes(unhex("83010203")) : Array[Int]), [1, 2, 3])
  assert_eq((@cbor.from_bytes(unhex("fb3ff8000000000000")) : Double), 1.5)
}

///|
/// Half precision, which this encoder never writes and many others do.
/// Assembled from bits rather than computed, so these are exact.
test "half-precision floats decode exactly" {
  assert_eq((@cbor.from_bytes(unhex("f90000")) : Double), 0.0)
  assert_eq((@cbor.from_bytes(unhex("f93c00")) : Double), 1.0)
  assert_eq((@cbor.from_bytes(unhex("f93e00")) : Double), 1.5)
  assert_eq((@cbor.from_bytes(unhex("f97bff")) : Double), 65504.0)
  assert_eq((@cbor.from_bytes(unhex("f9c400")) : Double), -4.0)
  // The smallest subnormal, 2^-24, and the largest, just under 2^-14.
  assert_eq((@cbor.from_bytes(unhex("f90001")) : Double), 5.960464477539063e-8)
  assert_eq((@cbor.from_bytes(unhex("f90400")) : Double), 6.103515625e-5)
  assert_true((@cbor.from_bytes(unhex("f97c00")) : Double).is_inf())
  assert_true((@cbor.from_bytes(unhex("f97e00")) : Double).is_nan())
}

///|
test "single precision decodes as itself" {
  assert_eq((@cbor.from_bytes(unhex("fa47c35000")) : Double), 100000.0)
  assert_eq((@cbor.from_bytes(unhex("fa47c35000")) : Float), (100000.0 : Float))
}

///|
/// Written by other encoders for streaming, never by this one. The decoder has
/// to accept them or it cannot read what it is meant to interoperate with.
test "indefinite-length containers decode" {
  assert_eq(
    (@cbor.from_bytes(unhex("9f018202039f0405ffff")) : @data.Value),
    Seq([UInt(1), Seq([UInt(2), UInt(3)]), Seq([UInt(4), UInt(5)])]),
  )
  assert_eq((@cbor.from_bytes(unhex("9f010203ff")) : Array[Int]), [1, 2, 3])
  assert_eq(
    (
      @cbor.from_bytes(unhex("bf61610161628202 03ff".replace(old=" ", new=""))) :
      @data.Value),
    Map([(Str(b"a"), UInt(1)), (Str(b"b"), Seq([UInt(2), UInt(3)]))]),
  )
}

///|
/// An indefinite string is chunks plus a break; the segmentation is the
/// encoder's business, not the reader's.
test "indefinite-length strings decode as one string" {
  assert_eq(
    (@cbor.from_bytes(unhex("7f657374726561646d696e67ff")) : String),
    "streaming",
  )
  assert_eq(
    (@cbor.from_bytes(unhex("5f42010243030405ff")) : Bytes),
    b"\x01\x02\x03\x04\x05",
  )
}

///|
/// Tags are read and dropped: a tagged value decodes as its content. `Value`
/// has no case for a tag, and refusing them would reject ordinary documents.
test "semantic tags are stepped over" {
  // Tag 1 (epoch time) wrapping 1363896240.
  assert_eq((@cbor.from_bytes(unhex("c11a514b67b0")) : Int), 1363896240)
  // Tag 0 (date string) wrapping text.
  assert_eq(
    (
      @cbor.from_bytes(unhex("c074323031332d30332d32315432303a30343a30305a")) :
      String),
    "2013-03-21T20:04:00Z",
  )
}

// ---- the data model ----

///|
pub(all) struct Point {
  x : Int
  y : Int
  label : String?
} derive(Eq, Debug)

///|
let point_fields : ReadOnlyArray[String] = ["x", "y", "label"]

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
  d.deserialize_struct_begin("Point", point_fields)
  let mut x : Int? = None
  let mut y : Int? = None
  let mut label : String? = None
  while d.deserialize_field_name() is Some(field) {
    match field {
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
pub impl @data.Serialize for Shape with fn serialize(self, s) {
  let enum_name = "Shape"
  match self {
    Empty => s.serialize_unit_variant({ enum_name, index: 0, name: "Empty" })
    Circle(r) =>
      s.serialize_newtype_variant({ enum_name, index: 1, name: "Circle" }, r)
    Rect(w, h) => {
      s.serialize_tuple_variant_begin({ enum_name, index: 2, name: "Rect" }, 2)
      s.serialize_tuple_variant_element(w)
      s.serialize_tuple_variant_element(h)
      s.serialize_tuple_variant_end()
    }
    Tagged(name~, size~) => {
      s.serialize_struct_variant_begin(
        { enum_name, index: 3, name: "Tagged" },
        2,
      )
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
test "structs are maps with text keys" {
  let p = Point::{ x: 1, y: 2, label: None }
  inspect(hex(@cbor.to_bytes(p)), content="a3617801617902656c6162656cf6")
  assert_eq((@cbor.from_bytes(@cbor.to_bytes(p)) : Point), p)
  let q = Point::{ x: -1, y: 300, label: Some("hi") }
  assert_eq((@cbor.from_bytes(@cbor.to_bytes(q)) : Point), q)
}

///|
test "every enum variant shape round-trips, externally tagged" {
  inspect(hex(@cbor.to_bytes(Shape::Empty)), content="65456d707479")
  inspect(
    hex(@cbor.to_bytes(Shape::Circle(1.5))),
    content="a166436972636c65fb3ff8000000000000",
  )
  for
    shape in [
      Shape::Empty,
      Shape::Circle(2.5),
      Shape::Rect(1.0, 2.0),
      Shape::Tagged(name="s", size=3),
    ] {
    assert_eq((@cbor.from_bytes(@cbor.to_bytes(shape)) : Shape), shape)
  }
}

///|
test "unknown fields are skipped, which a self-describing format can do" {
  // A Point with an extra `extra` key holding a nested array.
  let with_extra = unhex(
    "a4617801617902656c6162656cf6656578747261830102 03".replace(old=" ", new=""),
  )
  assert_eq((@cbor.from_bytes(with_extra) : Point), Point::{
    x: 1,
    y: 2,
    label: None,
  })
}

///|
test "an unknown variant names the ones that exist" {
  let bad = @cbor.to_bytes("Nope")
  try (@cbor.from_bytes(bad) : Shape) catch {
    e =>
      inspect(
        e,
        content=(
          #|$: unknown variant `Nope`, expected one of Empty, Circle, Rect, Tagged
        ),
      )
  } noraise {
    _ => fail("expected an unknown-variant error")
  }
}

///|
test "trailing input is refused" {
  let bytes = unhex("0101")
  try (@cbor.from_bytes(bytes) : Int) catch {
    e =>
      inspect(
        e,
        content=(
          #|$: trailing input after value
        ),
      )
  } noraise {
    _ => fail("expected trailing input to be refused")
  }
}

///|
test "a length longer than the input is refused rather than allocated" {
  // A text string claiming 2^32-1 bytes with none following.
  let hostile = unhex("7affffffff")
  try (@cbor.from_bytes(hostile) : String) catch {
    e =>
      inspect(
        e,
        content=(
          #|$: CBOR: length 4294967295 exceeds the 0 byte(s) remaining
        ),
      )
  } noraise {
    _ => fail("expected a hostile length to be refused")
  }
}

///|
test "the format declares itself unreadable by people" {
  assert_false(@data.Serializer::is_human_readable(@cbor.CborSerializer::new()))
  assert_false(
    @data.Deserializer::is_human_readable(@cbor.CborDeserializer::new(b"")),
  )
}

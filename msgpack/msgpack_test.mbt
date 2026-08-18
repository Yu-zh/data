// Tests for the MessagePack codec.
//
// As with CBOR, the encoding tests check against the published spec rather
// than against this package's own decoder — a codec that agrees with itself
// proves nothing about interoperating.

///|
fn hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef".to_array()
  let out = StringBuilder::new()
  for b in bytes {
    let v = b.to_int()
    out.write_char(digits[v >> 4])
    out.write_char(digits[v & 0xF])
  }
  out.to_string()
}

///|
/// The first `n` bytes, in hex. Used where only the marker matters.
fn first(bytes : Bytes, n : Int) -> String {
  hex(Bytes::from_iter(bytes.iter().take(n)))
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

// ---- the spec's marker layout ----

///|
/// Positive fixint runs to 127, negative fixint down to -32, and everything
/// wider picks the narrowest form that holds it.
test "integers take the narrowest form" {
  inspect(hex(@msgpack.to_bytes(0)), content="00")
  inspect(hex(@msgpack.to_bytes(127)), content="7f")
  inspect(hex(@msgpack.to_bytes(128)), content="cc80")
  inspect(hex(@msgpack.to_bytes(255)), content="ccff")
  inspect(hex(@msgpack.to_bytes(256)), content="cd0100")
  inspect(hex(@msgpack.to_bytes(65536)), content="ce00010000")
  inspect(hex(@msgpack.to_bytes(4294967296L)), content="cf0000000100000000")
  inspect(hex(@msgpack.to_bytes(-1)), content="ff")
  inspect(hex(@msgpack.to_bytes(-32)), content="e0")
  inspect(hex(@msgpack.to_bytes(-33)), content="d0df")
  inspect(hex(@msgpack.to_bytes(-128)), content="d080")
  inspect(hex(@msgpack.to_bytes(-129)), content="d1ff7f")
  inspect(hex(@msgpack.to_bytes(-32769)), content="d2ffff7fff")
}

///|
test "the integer boundaries encode without overflowing" {
  inspect(
    hex(@msgpack.to_bytes(18446744073709551615UL)),
    content="cfffffffffffffffff",
  )
  inspect(
    hex(@msgpack.to_bytes(-9223372036854775808L)),
    content="d38000000000000000",
  )
  inspect(
    hex(@msgpack.to_bytes(9223372036854775807L)),
    content="cf7fffffffffffffff",
  )
}

///|
test "simple values and floats take their markers" {
  inspect(hex(@msgpack.to_bytes(())), content="c0")
  inspect(hex(@msgpack.to_bytes(false)), content="c2")
  inspect(hex(@msgpack.to_bytes(true)), content="c3")
  inspect(hex(@msgpack.to_bytes(1.5)), content="cb3ff8000000000000")
  inspect(hex(@msgpack.to_bytes((1.5 : Float))), content="ca3fc00000")
}

///|
test "strings use fixstr where they fit" {
  inspect(hex(@msgpack.to_bytes("")), content="a0")
  inspect(hex(@msgpack.to_bytes("a")), content="a161")
  inspect(hex(@msgpack.to_bytes("水")), content="a3e6b0b4")
  // 31 bytes is the last fixstr; 32 moves to str8.
  let thirtyone = "0123456789012345678901234567890"
  let thirtytwo = thirtyone + "1"
  inspect(first(@msgpack.to_bytes(thirtyone), 1), content="bf")
  inspect(first(@msgpack.to_bytes(thirtytwo), 2), content="d920")
}

///|
/// The distinction JSON cannot make. MessagePack gained `bin` in 2013 for
/// exactly this reason: before that, byte strings and text shared a marker.
test "bytes are a bin, not an array of numbers" {
  inspect(hex(@msgpack.to_bytes(b"\x01\x02")), content="c4020102")
  inspect(hex(@msgpack.to_bytes([1, 2])), content="920102")
  assert_eq(
    (@msgpack.from_bytes(@msgpack.to_bytes(b"\x01\x02")) : Bytes),
    b"\x01\x02",
  )
}

///|
test "arrays and maps use the fix forms where they fit" {
  inspect(hex(@msgpack.to_bytes(([] : Array[Int]))), content="90")
  inspect(hex(@msgpack.to_bytes([1, 2, 3])), content="93010203")
  let m : Map[Int, String] = { 1: "a" }
  inspect(hex(@msgpack.to_bytes(m)), content="8101a161")
}

///|
/// The other thing JSON cannot do.
test "map keys need not be strings" {
  let m : Map[Int, String] = { 1: "a", 2: "b" }
  assert_eq((@msgpack.from_bytes(@msgpack.to_bytes(m)) : Map[Int, String]), m)
}

// ---- decoding ----

///|
test "the wider forms decode to the values they denote" {
  // The same 1 written five different ways, as five encoders might.
  assert_eq((@msgpack.from_bytes(unhex("01")) : Int), 1)
  assert_eq((@msgpack.from_bytes(unhex("cc01")) : Int), 1)
  assert_eq((@msgpack.from_bytes(unhex("cd0001")) : Int), 1)
  assert_eq((@msgpack.from_bytes(unhex("ce00000001")) : Int), 1)
  assert_eq((@msgpack.from_bytes(unhex("d001")) : Int), 1)
  assert_eq((@msgpack.from_bytes(unhex("d10001")) : Int), 1)
}

///|
test "signed forms sign-extend correctly" {
  assert_eq((@msgpack.from_bytes(unhex("d0ff")) : Int), -1)
  assert_eq((@msgpack.from_bytes(unhex("d1ffff")) : Int), -1)
  assert_eq((@msgpack.from_bytes(unhex("d2ffffffff")) : Int), -1)
  assert_eq((@msgpack.from_bytes(unhex("d3ffffffffffffffff")) : Int64), -1L)
  assert_eq((@msgpack.from_bytes(unhex("d180ff")) : Int), -32513)
}

///|
test "str8, str16 and the fix form all decode as strings" {
  assert_eq((@msgpack.from_bytes(unhex("a3616263")) : String), "abc")
  assert_eq((@msgpack.from_bytes(unhex("d903616263")) : String), "abc")
  assert_eq((@msgpack.from_bytes(unhex("da0003616263")) : String), "abc")
}

///|
test "an extension type is refused rather than guessed at" {
  // fixext1: type 5, one byte of payload.
  let ext = unhex("d40501")
  try (@msgpack.from_bytes(ext) : @data.Value) catch {
    e =>
      inspect(
        e,
        content=(
          #|$: MessagePack: extension types are not part of the data model
        ),
      )
  } noraise {
    _ => fail("expected an extension to be refused")
  }
}

///|
/// MessagePack has no indefinite-length container, so a sequence whose length
/// is unknown simply cannot be written. Nothing in the library passes `None`,
/// so this is reached only by asking directly.
test "a sequence of unknown length cannot be written" {
  let s = @msgpack.MsgpackSerializer::new()
  try @data.Serializer::serialize_seq_begin(s, None) catch {
    e =>
      inspect(
        e,
        content=(
          #|MessagePack cannot serialize a sequence of unknown length
        ),
      )
  } noraise {
    _ => fail("expected an unknown length to be refused")
  }
}

///|
test "a length longer than the input is refused rather than allocated" {
  let hostile = unhex("dbffffffff")
  try (@msgpack.from_bytes(hostile) : String) catch {
    e =>
      inspect(
        e,
        content=(
          #|$: MessagePack: length 4294967295 exceeds the 0 byte(s) remaining
        ),
      )
  } noraise {
    _ => fail("expected a hostile length to be refused")
  }
}

///|
test "trailing input is refused" {
  try (@msgpack.from_bytes(unhex("0101")) : Int) catch {
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
    x: @data.required(x, name="x", path=d.path()),
    y: @data.required(y, name="y", path=d.path()),
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
  let variants : ReadOnlyArray[String] = ["Empty", "Circle", "Rect", "Tagged"]
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
        name=@data.required(name, name="name", path=d.path()),
        size=@data.required(size, name="size", path=d.path()),
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
test "structs are maps with string keys" {
  let p = Point::{ x: 1, y: 2, label: None }
  inspect(hex(@msgpack.to_bytes(p)), content="83a17801a17902a56c6162656cc0")
  assert_eq((@msgpack.from_bytes(@msgpack.to_bytes(p)) : Point), p)
  let q = Point::{ x: -1, y: 300, label: Some("hi") }
  assert_eq((@msgpack.from_bytes(@msgpack.to_bytes(q)) : Point), q)
}

///|
test "every enum variant shape round-trips, externally tagged" {
  inspect(hex(@msgpack.to_bytes(Shape::Empty)), content="a5456d707479")
  for
    shape in [
      Shape::Empty,
      Shape::Circle(2.5),
      Shape::Rect(1.0, 2.0),
      Shape::Tagged(name="s", size=3),
    ] {
    assert_eq((@msgpack.from_bytes(@msgpack.to_bytes(shape)) : Shape), shape)
  }
}

///|
test "unknown fields are skipped, which a self-describing format can do" {
  // A Point with an extra key holding a nested array.
  let with_extra = unhex("84a17801a17902a56c6162656cc0a5657874726193010203")
  assert_eq((@msgpack.from_bytes(with_extra) : Point), Point::{
    x: 1,
    y: 2,
    label: None,
  })
}

///|
test "the format declares itself unreadable by people" {
  assert_false(
    @data.Serializer::is_human_readable(@msgpack.MsgpackSerializer::new()),
  )
  assert_false(
    @data.Deserializer::is_human_readable(
      @msgpack.MsgpackDeserializer::new(b""),
    ),
  )
}

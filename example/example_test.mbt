// Acceptance tests for the generator.
//
// Nothing here is hand-written serialization code: every implementation these
// tests exercise came out of `moonx Yu-zh/data/derive`. They are the check
// that generated impls behave the same as the hand-written ones the core and
// JSON packages test.

///|
test "a generated record round-trips through both formats" {
  let p = @example.Point::{ x: 1, y: 2, label: Some("origin") }
  inspect(
    @data.to_value(p),
    content="{\"x\": 1, \"y\": 2, \"label\": \"origin\"}",
  )
  inspect(@json.to_string(p), content="{\"x\":1,\"y\":2,\"label\":\"origin\"}")
  assert_eq((@data.from_value(@data.to_value(p)) : @example.Point), p)
  assert_eq((@json.from_string(@json.to_string(p)) : @example.Point), p)
}

///|
test "an absent optional field reads back as None" {
  let bare = @example.Point::{ x: 0, y: 0, label: None }
  inspect(@json.to_string(bare), content="{\"x\":0,\"y\":0,\"label\":null}")
  assert_eq((@json.from_string("{\"x\":0,\"y\":0}") : @example.Point), bare)
  assert_eq(
    (@json.from_string("{\"x\":0,\"y\":0,\"label\":null}") : @example.Point),
    bare,
  )
}

///|
test "a missing required field is still reported by name" {
  try (@json.from_string("{\"x\":1}") : @example.Point) catch {
    e => inspect(e, content="$: missing field `y`")
  } noraise {
    _ => fail("expected a missing field error")
  }
}

///|
test "rename changes the wire name and skip drops the field" {
  let c = @example.Config::{ max_retries: 3, cache_generation: 99 }
  inspect(@json.to_string(c), content="{\"max-retries\":3}")
  // `cache_generation` is not written, so it comes back as its default.
  assert_eq((@json.from_string(@json.to_string(c)) : @example.Config), @example.Config::{
    max_retries: 3,
    cache_generation: 0,
  })
}

///|
test "every generated variant shape round-trips" {
  let shapes : Array[@example.Shape] = [
    Empty,
    Circle(2.0),
    Rect(3.0, 4.0),
    Tagged(name="a", size=1),
    Oval(1.0, 2.0),
  ]
  inspect(
    @json.to_string(shapes),
    content="[\"Empty\",{\"Circle\":2},{\"Rect\":[3,4]},{\"Tagged\":{\"name\":\"a\",\"size\":1}},{\"Ellipse\":[1,2]}]",
  )
  for shape in shapes {
    assert_eq(
      (@json.from_string(@json.to_string(shape)) : @example.Shape),
      shape,
    )
    assert_eq((@data.from_value(@data.to_value(shape)) : @example.Shape), shape)
  }
}

///|
test "a renamed variant is only known by its wire name" {
  assert_eq(
    (@json.from_string("{\"Ellipse\":[1,2]}") : @example.Shape),
    Oval(1.0, 2.0),
  )
  try (@json.from_string("{\"Oval\":[1,2]}") : @example.Shape) catch {
    e =>
      inspect(
        e,
        content="$: unknown variant `Oval`, expected one of Empty, Circle, Rect, Tagged, Ellipse",
      )
  } noraise {
    _ => fail("expected an unknown variant error")
  }
}

///|
test "generic types derive with a bound per parameter" {
  let pair : @example.Pair[Int, String] = { first: 1, second: "two" }
  inspect(@json.to_string(pair), content="{\"first\":1,\"second\":\"two\"}")
  assert_eq(
    (@json.from_string(@json.to_string(pair)) : @example.Pair[Int, String]),
    pair,
  )
  // Nesting proves the bounds really are what makes it compose.
  let nested : @example.Pair[@example.Point, Array[Int]] = {
    first: { x: 1, y: 2, label: None },
    second: [3, 4],
  }
  assert_eq(
    (
      @json.from_string(@json.to_string(nested)) :
      @example.Pair[@example.Point, Array[Int]]),
    nested,
  )
}

///|
test "a tuple struct becomes a sequence" {
  let c = @example.Rgb(1, 2, 3)
  inspect(@json.to_string(c), content="[1,2,3]")
  inspect(@data.to_value(c), content="[1, 2, 3]")
  assert_eq((@json.from_string(@json.to_string(c)) : @example.Rgb), c)
  assert_eq((@data.from_value(@data.to_value(c)) : @example.Rgb), c)
}

///|
test "errors from generated impls carry paths like hand-written ones" {
  try
    (@json.from_string("[{\"x\":1,\"y\":\"oops\"}]") : Array[@example.Point])
  catch {
    e =>
      inspect(
        e,
        content="$[0].y: invalid type: expected a number, found string",
      )
  } noraise {
    _ => fail("expected a type error")
  }
}

///|
/// Generated deserializers tolerate fields they do not know about, at every
/// level: plain struct, renamed struct, and struct-shaped variant.
test "generated impls skip unknown fields" {
  assert_eq(
    (
      @json.from_string("{\"x\":1,\"y\":2,\"extra\":[{\"deep\":true}]}") :
      @example.Point),
    @example.Point::{ x: 1, y: 2, label: None },
  )
  assert_eq(
    (
      @json.from_string("{\"max-retries\":3,\"stale\":\"ignored\"}") :
      @example.Config),
    @example.Config::{ max_retries: 3, cache_generation: 0 },
  )
  assert_eq(
    (
      @json.from_string(
        "{\"Tagged\":{\"name\":\"a\",\"extra\":null,\"size\":1}}",
      ) : @example.Shape),
    Tagged(name="a", size=1),
  )
}

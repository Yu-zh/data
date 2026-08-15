// Property tests for the round-trip laws.
//
// `data_test.mbt` pins specific shapes by example; this file pins the laws
// those examples are instances of, over inputs quickcheck picks. Three
// properties, in increasing strength:
//
//   P1  from_value(to_value(x)) == x                the data model round-trips
//   P2  from_bytes(to_bytes(x)) == x                the format round-trips
//   P3  the two agree                               the abstraction holds
//
// P3 is the one that tests `Serializer` rather than any single implementation:
// a bug in `JsonSerializer` that `ValueSerializer` does not share is invisible
// to P1 and P2 — both sides can be wrong in the same way and still round-trip —
// but shows up immediately when the two are compared against each other.
//
// `Point` and `Shape` come from `data_test.mbt`; the generators for them live
// here so the worked examples stay readable as examples.

///|
/// Maps an arbitrary `Int` into `0..<modulus` without discarding cases.
///
/// `abs` will not do: `Int::min_value().abs()` is still negative.
fn wrap(value : Int, modulus : Int) -> Int {
  let r = value % modulus
  if r < 0 {
    r + modulus
  } else {
    r
  }
}

///|
/// Folds the non-finite doubles onto zero.
///
/// Used by the composite generators, which have no way to filter a NaN out of
/// one field without discarding the whole value. `AnyDouble` keeps them and
/// filters at the property instead, because for a bare double they are the
/// interesting inputs.
fn finite(d : Double) -> Double {
  if d.is_nan() || d.is_inf() {
    0.0
  } else {
    d
  }
}

///|
/// A `Double` drawn from the whole bit space rather than the unit interval.
///
/// `Arbitrary for Double` samples `next_double`, which never reaches the large
/// exponents, the subnormals, or negative zero — precisely where a float writer
/// and a float parser are most likely to disagree, and precisely what the
/// Eisel-Lemire path in `json/eisel_lemire.mbt` exists to get right.
/// Reinterpreting arbitrary bits reaches all of them.
struct AnyDouble(Double) derive(Eq, Debug)

///|
impl @quickcheck.Arbitrary for AnyDouble with fn arbitrary(size, rs) {
  let bits : Int64 = @quickcheck.Arbitrary::arbitrary(size, rs)
  AnyDouble(bits.reinterpret_as_double())
}

///|
impl @shrink.Shrink for AnyDouble

///|
pub impl @data.Serialize for AnyDouble with fn serialize(self, s) {
  s.serialize_double(self.0)
}

///|
pub impl @data.Deserialize for AnyDouble with fn deserialize(d) {
  AnyDouble(d.deserialize_double())
}

///|
/// NaN is never equal to itself and both infinities raise on the way out, so
/// the round-trip laws are stated over the finite doubles only.
fn is_finite(x : AnyDouble) -> Bool {
  !(x.0.is_nan() || x.0.is_inf())
}

///|
impl @quickcheck.Arbitrary for Point with fn arbitrary(size, rs) {
  {
    x: @quickcheck.Arbitrary::arbitrary(size, rs),
    y: @quickcheck.Arbitrary::arbitrary(size, rs),
    label: @quickcheck.Arbitrary::arbitrary(size, rs),
  }
}

///|
impl @shrink.Shrink for Point

///|
impl @quickcheck.Arbitrary for Shape with fn arbitrary(size, rs) {
  let tag : Int = @quickcheck.Arbitrary::arbitrary(size, rs)
  match wrap(tag, 4) {
    0 => Empty
    1 => Circle(finite(@quickcheck.Arbitrary::arbitrary(size, rs)))
    2 =>
      Rect(
        finite(@quickcheck.Arbitrary::arbitrary(size, rs)),
        finite(@quickcheck.Arbitrary::arbitrary(size, rs)),
      )
    _ =>
      Tagged(
        name=@quickcheck.Arbitrary::arbitrary(size, rs),
        size=@quickcheck.Arbitrary::arbitrary(size, rs),
      )
  }
}

///|
impl @shrink.Shrink for Shape

// ---- P1: the data model round-trips ----

///|
test "P1: primitives round-trip through Value" {
  @quickcheck.check((x : Unit) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : Bool) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : Byte) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : Int) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : UInt) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : Int64) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : UInt64) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : Char) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : String) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : Bytes) => @data.from_value(@data.to_value(x)) == x)
}

///|
test "P1: doubles round-trip through Value across the whole bit space" {
  @quickcheck.check(
    (x : AnyDouble) => @data.from_value(@data.to_value(x)) == x,
    filter=is_finite,
  )
}

///|
test "P1: containers round-trip through Value" {
  @quickcheck.check((x : Int?) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : Array[Int]) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check(
    (x : Array[String]) => @data.from_value(@data.to_value(x)) == x,
  )
  @quickcheck.check(
    (x : Array[Array[Int]]) => @data.from_value(@data.to_value(x)) == x,
  )
  @quickcheck.check(
    (x : (Int, String)) => @data.from_value(@data.to_value(x)) == x,
  )
  @quickcheck.check(
    (x : (Bool, Int, String)) => @data.from_value(@data.to_value(x)) == x,
  )
}

///|
test "P1: structs and every enum variant shape round-trip through Value" {
  @quickcheck.check((x : Point) => @data.from_value(@data.to_value(x)) == x)
  @quickcheck.check((x : Shape) => @data.from_value(@data.to_value(x)) == x)
}

// ---- P2: JSON round-trips ----

///|
test "P2: primitives round-trip through JSON" {
  @quickcheck.check((x : Unit) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : Bool) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : Byte) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : Int) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : UInt) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : Int64) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : UInt64) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : Char) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : String) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : Bytes) => @json.from_bytes(@json.to_bytes(x)) == x)
}

///|
/// Bit equality, not approximate equality: the writer and the parser have to
/// agree exactly, or the shortest-representation guarantee is worthless.
test "P2: doubles round-trip through JSON across the whole bit space" {
  @quickcheck.check(
    (x : AnyDouble) => @json.from_bytes(@json.to_bytes(x)) == x,
    filter=is_finite,
  )
}

///|
test "P2: containers round-trip through JSON" {
  @quickcheck.check((x : Int?) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : Array[Int]) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check(
    (x : Array[String]) => @json.from_bytes(@json.to_bytes(x)) == x,
  )
  @quickcheck.check(
    (x : Array[Array[Int]]) => @json.from_bytes(@json.to_bytes(x)) == x,
  )
  @quickcheck.check(
    (x : (Int, String)) => @json.from_bytes(@json.to_bytes(x)) == x,
  )
  @quickcheck.check(
    (x : (Bool, Int, String)) => @json.from_bytes(@json.to_bytes(x)) == x,
  )
}

///|
test "P2: structs and every enum variant shape round-trip through JSON" {
  @quickcheck.check((x : Point) => @json.from_bytes(@json.to_bytes(x)) == x)
  @quickcheck.check((x : Shape) => @json.from_bytes(@json.to_bytes(x)) == x)
}

// ---- P3: the two formats agree ----

///|
/// Sends one value down both paths and compares what comes back.
///
/// The annotations are load-bearing: `from_bytes` and `from_value` are both
/// generic in their return type, so comparing the two calls directly leaves the
/// type unconstrained and it defaults to `Unit` — which compares equal every
/// time and quietly turns the property into a tautology.
fn[T : @data.Serialize + @data.Deserialize + Eq] agree(x : T) -> Bool raise {
  let through_json : T = @json.from_bytes(@json.to_bytes(x))
  let through_value : T = @data.from_value(@data.to_value(x))
  through_json == through_value
}

///|
/// The property that tests the abstraction rather than either implementation.
/// Both sides can round-trip while disagreeing about which protocol methods a
/// value goes through; only comparing them catches that.
test "P3: JSON and Value agree on what a value means" {
  @quickcheck.check((x : Int) => agree(x))
  @quickcheck.check((x : String) => agree(x))
  @quickcheck.check((x : Bytes) => agree(x))
  @quickcheck.check((x : Int?) => agree(x))
  @quickcheck.check((x : Array[Int]) => agree(x))
  @quickcheck.check((x : (Int, String)) => agree(x))
  @quickcheck.check((x : Point) => agree(x))
  @quickcheck.check((x : Shape) => agree(x))
}

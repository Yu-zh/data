// Types whose implementations are generated, not written.
//
// Run `moonx Yu-zh/data/derive example` (or, inside this repo,
// `moon run derive -- example`) to regenerate `types_derive.mbt` after
// changing anything here.

///|
#data.derive(Serialize, Deserialize)
pub(all) struct Point {
  x : Int
  y : Int
  /// An `Option` field: absent and explicitly null both read back as `None`.
  label : String?
} derive(Eq, Debug)

///|
#data.derive(Serialize, Deserialize)
pub(all) struct Config {
  /// The wire name need not be a legal MoonBit identifier.
  #data.rename("max-retries")
  max_retries : Int
  /// Never written, and filled from `Default` on the way back in.
  #data.skip
  cache_generation : Int
} derive(Eq, Debug)

///|
#data.derive(Serialize, Deserialize)
pub(all) enum Shape {
  Empty
  Circle(Double)
  Rect(Double, Double)
  Tagged(name~ : String, size~ : Int)
  #data.rename("Ellipse")
  Oval(Double, Double)
} derive(Eq, Debug)

///|
#data.derive(Serialize, Deserialize)
pub(all) struct Pair[A, B] {
  first : A
  second : B
} derive(Eq, Debug)

///|
#data.derive(Serialize, Deserialize)
pub(all) struct Rgb(Int, Int, Int) derive(Eq, Debug)

// What the scanner extracts from a type declaration, and all the emitter
// needs to know about it.
//
// Deliberately does not carry any MoonBit *types*: thanks to backward type
// inference, generated code never has to name the type of a field or a
// variant payload, so the generator never has to render one.

///|
/// A type marked with `#data.derive(...)`.
struct Target {
  name : String
  /// Type parameters, e.g. `["T"]` for `Foo[T]`. Each gets a trait bound on
  /// the generated impl.
  params : Array[String]
  /// Whether the type itself is public, which decides whether the impl can be.
  public : Bool
  shape : Shape
  serialize : Bool
  deserialize : Bool
}

///|
enum Shape {
  /// `struct Foo { a : Int }`
  Record(Array[Field])
  /// `struct Foo(Int, Int)`
  TupleStruct(Int)
  /// `enum Foo { ... }`
  Variant(Array[Case])
}

///|
struct Field {
  /// The MoonBit field name.
  ident : String
  /// The name it is serialized under, after `#data.rename`.
  name : String
  /// True when the declared type is `T?`, in which case an absent field
  /// deserializes to `None` instead of being an error.
  optional : Bool
  /// `#data.skip`: left out of the output entirely, and filled from
  /// `Default::default()` on the way back in.
  skip : Bool
}

///|
struct Case {
  ident : String
  name : String
  payload : Payload
}

///|
/// Which of serde's four variant forms this case maps onto.
enum Payload {
  /// `Empty`
  Unit
  /// `Circle(Double)`
  Newtype
  /// `Rect(Double, Double)`
  Tuple(Int)
  /// `Tagged(name~ : String, size~ : Int)`
  Struct(Array[Field])
}

///|
/// A problem with the *attributes*, as opposed to a parse error. Carries a
/// location prefix so the message reads like a compiler diagnostic.
pub suberror DeriveError {
  DeriveError(where_~ : String, message~ : String)
}

///|
pub impl Show for DeriveError with fn output(self, logger) {
  let DeriveError(where_~, message~) = self
  logger.write_string("\{where_}: \{message}")
}

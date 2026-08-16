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
/// Which of the data model's struct forms a type maps onto.
///
/// The two degenerate forms are separated out for the same reason serde
/// separates them: a struct wrapping exactly one value is a wrapper, not a
/// one-element tuple, and a struct with nothing in it carries no more
/// information than unit. Both have their own `Serializer` methods, whose
/// defaults widen to the general form, so a format that draws no distinction
/// still writes what `TupleStruct` and `Record` would have written.
enum Shape {
  /// `struct Foo {}` — no fields at all. Not the same as a record whose
  /// fields are all `#data.skip`ed: that one still has a shape, and stays a
  /// `Record` with nothing left to write.
  UnitStruct
  /// `struct Foo(Int)` — exactly one positional field, written as the value
  /// it wraps rather than as a sequence of one.
  NewtypeStruct
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
suberror DeriveError {
  DeriveError(where_~ : String, message~ : String)
}

///|
impl Show for DeriveError with fn output(self, logger) {
  let DeriveError(where_~, message~) = self
  logger.write_string("\{where_}: \{message}")
}

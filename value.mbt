///|
/// A self-describing value: the data model made concrete.
///
/// `Serialize` is polymorphic in its serializer and therefore has no trait
/// object form, so a heterogeneous collection cannot be built out of
/// `Serialize` values directly. `Value` fills that gap, and doubles as the
/// result type of `Deserializer::deserialize_any`.
///
/// Structs and enum variants collapse into `Map` here, using serde's default
/// externally-tagged representation: a unit variant becomes `Str(name)`, and
/// any variant with a payload becomes a single-entry `Map` from the variant
/// name to its payload.
pub(all) enum Value {
  Null
  Boolean(Bool)
  /// Any signed integer in the data model, widened.
  Int(Int64)
  /// Any unsigned integer in the data model, widened.
  UInt(UInt64)
  Double(Double)
  Str(String)
  Bytes(Bytes)
  Seq(Array[Value])
  /// Order-preserving, and keys need not be strings.
  Map(Array[(Value, Value)])
} derive(Eq, Debug)

///|
/// A short name for this value's shape, used in `InvalidType` messages.
pub fn Value::type_name(self : Value) -> String {
  match self {
    Null => "unit"
    Boolean(_) => "boolean"
    Int(_) => "integer"
    UInt(_) => "unsigned integer"
    Double(_) => "float"
    Str(_) => "string"
    Bytes(_) => "byte string"
    Seq(_) => "sequence"
    Map(_) => "map"
  }
}

///|
/// Looks up a key in a `Map` value. Returns `None` for any other shape.
pub fn Value::get(self : Value, key : String) -> Value? {
  guard self is Map(entries) else { return None }
  for entry in entries {
    if entry.0 is Str(k) && k == key {
      return Some(entry.1)
    }
  }
  None
}

///|
pub impl Show for Value with fn output(self, logger) {
  match self {
    Null => logger.write_string("null")
    Boolean(b) => logger.write_string(b.to_string())
    Int(i) => logger.write_string(i.to_string())
    UInt(u) => logger.write_string(u.to_string())
    Double(d) => logger.write_string(d.to_string())
    Str(s) => {
      logger.write_string("\"")
      logger.write_string(s)
      logger.write_string("\"")
    }
    Bytes(b) => {
      logger.write_string("b\"")
      for byte in b {
        logger.write_string(byte.to_hex())
      }
      logger.write_string("\"")
    }
    Seq(items) => {
      logger.write_string("[")
      for i, item in items {
        if i > 0 {
          logger.write_string(", ")
        }
        Show::output(item, logger)
      }
      logger.write_string("]")
    }
    Map(entries) => {
      logger.write_string("{")
      for i, entry in entries {
        if i > 0 {
          logger.write_string(", ")
        }
        Show::output(entry.0, logger)
        logger.write_string(": ")
        Show::output(entry.1, logger)
      }
      logger.write_string("}")
    }
  }
}

///|
/// A self-describing value: the data model made concrete.
///
/// `Serialize` is polymorphic in its serializer and therefore has no trait
/// object form, so a heterogeneous collection cannot be built out of
/// `Serialize` values directly. `Value` fills that gap, and doubles as the
/// result type of `Deserializer::deserialize_any`.
///
/// Strings are held as UTF-8 `BytesView`s, not as MoonBit `String`s. The data model
/// describes what a document *contains*, and a document contains text in some
/// encoding — turning that into UTF-16 is a service to one particular consumer,
/// so the consumer that wants it pays for it. It also means a document can be
/// read and written again without ever being transcoded.
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
  Str(BytesView)
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
///
/// Takes a `String` because that is how a key is written in source; it is
/// encoded once, not once per entry.
pub fn Value::get(self : Value, key : String) -> Value? {
  guard self is Map(entries) else { return None }
  let needle = @utf8.encode(key)[:]
  for entry in entries {
    if entry.0 is Str(k) && k == needle {
      return Some(entry.1)
    }
  }
  None
}

///|
/// The text of a `Str`, decoded. `None` for any other shape.
///
/// The explicit step from the data model's bytes to a MoonBit `String`.
pub fn Value::text(self : Value) -> String? {
  guard self is Str(bytes) else { return None }
  Some(@utf8.decode(bytes)) catch {
    _ => None
  }
}

///|
/// Copies every borrowed string, so the value no longer keeps the document it
/// was parsed from alive.
///
/// Parsing borrows by default, which is free and right when a whole document
/// is being processed. Keeping a handful of fields out of a large one is the
/// case that wants this: without it, a five-byte key can hold ten megabytes
/// reachable.
pub fn Value::detach(self : Value) -> Value {
  match self {
    Str(view) => Str(view.to_owned()[:])
    Seq(items) => Seq(items.map(v => v.detach()))
    Map(entries) => Map(entries.map(e => (e.0.detach(), e.1.detach())))
    other => other
  }
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
      logger.write_string(@utf8.decode_lossy(s))
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

///|
/// A location within the data being serialized or deserialized.
///
/// Deserializers thread a `Path` through nested values so that a failure deep
/// inside a document reports *where* it happened, not just what happened.
/// Rendered as a JSONPath-like string: `$.users[0].name`.
pub(all) enum Path {
  Root
  Key(Path, String)
  Index(Path, Int)
} derive(Eq, Debug)

///|
/// Extends the path with a struct field or map key.
pub fn Path::key(self : Path, name : String) -> Path {
  Key(self, name)
}

///|
/// Extends the path with a sequence index.
pub fn Path::index(self : Path, i : Int) -> Path {
  Index(self, i)
}

///|
pub impl Show for Path with fn output(self, logger) {
  match self {
    Root => logger.write_string("$")
    Key(parent, name) => {
      Show::output(parent, logger)
      logger.write_string(".")
      logger.write_string(name)
    }
    Index(parent, i) => {
      Show::output(parent, logger)
      logger.write_string("[")
      logger.write_string(i.to_string())
      logger.write_string("]")
    }
  }
}

///|
/// Failure raised by a `Serializer`.
///
/// Serialization fails far less often than deserialization: the value is
/// already well-typed, so the only real failures are a format that cannot
/// represent part of the data model, or an I/O-style failure in the sink.
pub(all) suberror SerError {
  /// The format cannot represent this part of the data model, e.g. JSON has
  /// no way to write a map with non-string keys.
  UnsupportedType(format~ : String, kind~ : String)
  /// Anything format-specific.
  SerCustom(message~ : String)
}

///|
pub impl Show for SerError with fn output(self, logger) {
  match self {
    UnsupportedType(format~, kind~) =>
      logger.write_string("\{format} cannot serialize \{kind}")
    SerCustom(message~) => logger.write_string(message)
  }
}

///|
/// Failure raised by a `Deserializer`.
///
/// Every variant carries the `Path` at which the failure occurred. The variants
/// mirror serde's `de::Error` constructors so that formats report errors
/// uniformly rather than each inventing its own message strings.
pub(all) suberror DeError {
  /// Found a value of the wrong shape, e.g. a string where an int was expected.
  InvalidType(path~ : Path, expected~ : String, found~ : String)
  /// A value of the right shape but an unacceptable value, e.g. an integer
  /// that does not fit the target width.
  InvalidValue(path~ : Path, expected~ : String, found~ : String)
  /// A sequence or tuple had the wrong number of elements.
  InvalidLength(path~ : Path, expected~ : Int, found~ : Int)
  /// A struct field was absent and had no default.
  MissingField(path~ : Path, field~ : String)
  /// A struct field was present that the target type does not know about.
  UnknownField(path~ : Path, field~ : String, expected~ : Array[String])
  /// An enum variant name that the target type does not know about.
  UnknownVariant(path~ : Path, variant~ : String, expected~ : Array[String])
  /// Input ended in the middle of a value.
  Eof(path~ : Path)
  /// Anything format-specific.
  DeCustom(path~ : Path, message~ : String)
}

///|
/// The path at which this error occurred.
pub fn DeError::path(self : DeError) -> Path {
  match self {
    InvalidType(path~, ..)
    | InvalidValue(path~, ..)
    | InvalidLength(path~, ..)
    | MissingField(path~, ..)
    | UnknownField(path~, ..)
    | UnknownVariant(path~, ..)
    | Eof(path~)
    | DeCustom(path~, ..) => path
  }
}

///|
fn one_of(names : Array[String]) -> String {
  if names.is_empty() {
    "there are no valid values"
  } else {
    "expected one of " + names.join(", ")
  }
}

///|
pub impl Show for DeError with fn output(self, logger) {
  let body = match self {
    InvalidType(expected~, found~, ..) =>
      "invalid type: expected \{expected}, found \{found}"
    InvalidValue(expected~, found~, ..) =>
      "invalid value: expected \{expected}, found \{found}"
    InvalidLength(expected~, found~, ..) =>
      "invalid length: expected \{expected} elements, found \{found}"
    MissingField(field~, ..) => "missing field `\{field}`"
    UnknownField(field~, expected~, ..) =>
      "unknown field `\{field}`, \{one_of(expected)}"
    UnknownVariant(variant~, expected~, ..) =>
      "unknown variant `\{variant}`, \{one_of(expected)}"
    Eof(..) => "unexpected end of input"
    DeCustom(message~, ..) => message
  }
  logger.write_string("\{self.path()}: \{body}")
}

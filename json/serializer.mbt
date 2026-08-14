///|
/// One open `[` or `{`, with the number of items written into it so far.
///
/// `ValueSerializer` needs no stack because it captures each nested value with
/// a fresh serializer. A streaming format cannot do that — the nested value is
/// written straight into the same output — so JSON is the case the flattened
/// compound protocol was designed for: it tracks its own depth.
priv struct Frame {
  is_object : Bool
  mut len : Int
}

///|
/// Writes JSON as UTF-8 bytes.
///
/// Output is compact: no spaces, no newlines. Enums use serde's default
/// external tagging, so a unit variant is a bare string and any variant with a
/// payload is a one-entry object.
struct JsonSerializer {
  out : @buffer.Buffer
  stack : Array[Frame]
  /// True while writing an object key, where JSON requires a quoted string
  /// even if the key type is a number.
  mut in_key : Bool
}

///|
pub fn JsonSerializer::new() -> JsonSerializer {
  { out: Buffer(size_hint=256), stack: [], in_key: false }
}

///|
/// The UTF-8 bytes written so far. Raises if a container was never closed.
pub fn JsonSerializer::finish(
  self : JsonSerializer,
) -> Bytes raise @data.SerError {
  if self.stack.length() > 0 {
    raise @data.SerCustom(
      message="JSON: \{self.stack.length()} container(s) opened but never ended",
    )
  }
  self.out.to_bytes()
}

///|
fn JsonSerializer::top(self : JsonSerializer) -> Frame? {
  if self.stack.length() == 0 {
    None
  } else {
    Some(self.stack[self.stack.length() - 1])
  }
}

///|
/// Writes the separator that must precede a value, if any.
///
/// Inside an array that means a comma between elements. Inside an object the
/// `:` after the key has already been written, so nothing is needed.
fn JsonSerializer::pre_value(self : JsonSerializer) -> Unit {
  if self.in_key {
    return
  }
  guard self.top() is Some(frame) else { return }
  if frame.is_object {
    return
  }
  if frame.len > 0 {
    self.out.write_char_utf8(',')
  }
  frame.len = frame.len + 1
}

///|
fn JsonSerializer::pre_key(self : JsonSerializer) -> Unit raise @data.SerError {
  guard self.top() is Some(frame) && frame.is_object else {
    raise @data.SerCustom(message="JSON: object key written outside an object")
  }
  if frame.len > 0 {
    self.out.write_char_utf8(',')
  }
  frame.len = frame.len + 1
}

///|
fn JsonSerializer::open(
  self : JsonSerializer,
  is_object : Bool,
  ch : Char,
) -> Unit {
  self.pre_value()
  self.out.write_char_utf8(ch)
  self.stack.push({ is_object, len: 0 })
}

///|
fn JsonSerializer::close(
  self : JsonSerializer,
  is_object : Bool,
  ch : Char,
) -> Unit raise @data.SerError {
  guard self.stack.pop() is Some(frame) else {
    raise @data.SerCustom(message="JSON: container ended without a begin")
  }
  guard frame.is_object == is_object else {
    raise @data.SerCustom(message="JSON: mismatched container end")
  }
  self.out.write_char_utf8(ch)
}

///|
/// JSON object keys must be strings, so only the types that have an obvious
/// string spelling may appear in key position.
fn JsonSerializer::reject_key(
  self : JsonSerializer,
  kind : String,
) -> Unit raise @data.SerError {
  if self.in_key {
    raise @data.UnsupportedType(format="JSON", kind="\{kind} as an object key")
  }
}

///|
fn JsonSerializer::write_quoted(self : JsonSerializer, s : String) -> Unit {
  self.out.write_char_utf8('"')
  for c in s {
    match c {
      '"' => self.out.write_string_utf8("\\\"")
      '\\' => self.out.write_string_utf8("\\\\")
      '\n' => self.out.write_string_utf8("\\n")
      '\r' => self.out.write_string_utf8("\\r")
      '\t' => self.out.write_string_utf8("\\t")
      _ =>
        if c.to_int() < 0x20 {
          let hex = c.to_int().to_string(radix=16)
          self.out.write_string_utf8("\\u")
          for _ in 0..<(4 - hex.length()) {
            self.out.write_char_utf8('0')
          }
          self.out.write_string_utf8(hex)
        } else {
          self.out.write_char_utf8(c)
        }
    }
  }
  self.out.write_char_utf8('"')
}

///|
/// Numbers are quoted when they appear as an object key and bare otherwise.
fn JsonSerializer::write_number(self : JsonSerializer, text : String) -> Unit {
  self.pre_value()
  if self.in_key {
    self.out.write_char_utf8('"')
    self.out.write_string_utf8(text)
    self.out.write_char_utf8('"')
  } else {
    self.out.write_string_utf8(text)
  }
}

///|
fn JsonSerializer::write_literal(
  self : JsonSerializer,
  kind : String,
  text : String,
) -> Unit raise @data.SerError {
  self.reject_key(kind)
  self.pre_value()
  self.out.write_string_utf8(text)
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_unit(self) {
  self.write_literal("null", "null")
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_bool(self, v) {
  self.write_literal("a boolean", if v { "true" } else { "false" })
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_byte(self, v) {
  self.write_number(v.to_int().to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_int16(self, v) {
  self.write_number(v.to_int().to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_uint16(self, v) {
  self.write_number(v.to_int().to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_int(self, v) {
  self.write_number(v.to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_uint(self, v) {
  self.write_number(v.to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_int64(self, v) {
  self.write_number(v.to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_uint64(self, v) {
  self.write_number(v.to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_float(self, v) {
  self.serialize_double(v.to_double())
}

///|
/// JSON has no spelling for NaN or infinity. `serde_json` silently writes
/// `null`; raising instead keeps the loss from being invisible.
pub impl @data.Serializer for JsonSerializer with fn serialize_double(self, v) {
  if v.is_nan() || v.is_inf() {
    raise @data.UnsupportedType(format="JSON", kind="NaN or infinity")
  }
  self.write_number(v.to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_char(self, v) {
  self.pre_value()
  self.write_quoted(v.to_string())
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_string(self, v) {
  self.pre_value()
  self.write_quoted(v)
}

///|
/// JSON has no byte string, so bytes become an array of numbers, matching
/// `serde_json`.
pub impl @data.Serializer for JsonSerializer with fn serialize_bytes(self, v) {
  self.reject_key("a byte string")
  self.pre_value()
  self.out.write_char_utf8('[')
  for i in 0..<v.length() {
    if i > 0 {
      self.out.write_char_utf8(',')
    }
    self.out.write_string_utf8(v[i].to_int().to_string())
  }
  self.out.write_char_utf8(']')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_none(self) {
  self.write_literal("null", "null")
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_some(self, v) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_seq_begin(
  self,
  _hint,
) {
  self.reject_key("a sequence")
  self.open(false, '[')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_seq_element(
  self,
  v,
) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_seq_end(self) {
  self.close(false, ']')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_map_begin(
  self,
  _hint,
) {
  self.reject_key("a map")
  self.open(true, '{')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_map_key(self, k) {
  self.pre_key()
  self.in_key = true
  k.serialize(self)
  self.in_key = false
  self.out.write_char_utf8(':')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_map_value(
  self,
  v,
) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_map_end(self) {
  self.close(true, '}')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_struct_begin(
  self,
  _name,
  _len,
) {
  self.reject_key("a struct")
  self.open(true, '{')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_field(
  self,
  name,
  v,
) {
  self.pre_key()
  self.write_quoted(name)
  self.out.write_char_utf8(':')
  v.serialize(self)
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_struct_end(self) {
  self.close(true, '}')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_unit_variant(
  self,
  info,
) {
  self.serialize_string(info.name)
}

///|
fn JsonSerializer::open_variant(
  self : JsonSerializer,
  name : String,
) -> Unit raise @data.SerError {
  self.reject_key("an enum")
  self.open(true, '{')
  self.pre_key()
  self.write_quoted(name)
  self.out.write_char_utf8(':')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_newtype_variant(
  self,
  info,
  v,
) {
  self.open_variant(info.name)
  v.serialize(self)
  self.close(true, '}')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_tuple_variant_begin(
  self,
  info,
  _len,
) {
  self.open_variant(info.name)
  self.open(false, '[')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_tuple_variant_end(
  self,
) {
  self.close(false, ']')
  self.close(true, '}')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_struct_variant_begin(
  self,
  info,
  _len,
) {
  self.open_variant(info.name)
  self.open(true, '{')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_struct_variant_end(
  self,
) {
  self.close(true, '}')
  self.close(true, '}')
}

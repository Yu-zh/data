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
    self.out.write_byte(b',')
  }
  frame.len = frame.len + 1
}

///|
fn JsonSerializer::pre_key(self : JsonSerializer) -> Unit raise @data.SerError {
  guard self.top() is Some(frame) && frame.is_object else {
    raise @data.SerCustom(message="JSON: object key written outside an object")
  }
  if frame.len > 0 {
    self.out.write_byte(b',')
  }
  frame.len = frame.len + 1
}

///|
fn JsonSerializer::open(
  self : JsonSerializer,
  is_object : Bool,
  ch : Byte,
) -> Unit {
  self.pre_value()
  self.out.write_byte(ch)
  self.stack.push({ is_object, len: 0 })
}

///|
fn JsonSerializer::close(
  self : JsonSerializer,
  is_object : Bool,
  ch : Byte,
) -> Unit raise @data.SerError {
  guard self.stack.pop() is Some(frame) else {
    raise @data.SerCustom(message="JSON: container ended without a begin")
  }
  guard frame.is_object == is_object else {
    raise @data.SerCustom(message="JSON: mismatched container end")
  }
  self.out.write_byte(ch)
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
  self.out.write_byte(b'"')
  for c in s {
    match c {
      '"' => {
        self.out.write_byte(b'\\')
        self.out.write_byte(b'"')
      }
      '\\' => {
        self.out.write_byte(b'\\')
        self.out.write_byte(b'\\')
      }
      '\n' => {
        self.out.write_byte(b'\\')
        self.out.write_byte(b'n')
      }
      '\r' => {
        self.out.write_byte(b'\\')
        self.out.write_byte(b'r')
      }
      '\t' => {
        self.out.write_byte(b'\\')
        self.out.write_byte(b't')
      }
      _ =>
        if c.to_int() < 0x20 {
          let hex = c.to_int().to_string(radix=16)
          {
            self.out.write_byte(b'\\')
            self.out.write_byte(b'u')
          }
          for _ in 0..<(4 - hex.length()) {
            self.out.write_byte(b'0')
          }
          self.out.write_string_utf8(hex)
        } else {
          self.out.write_char_utf8(c)
        }
    }
  }
  self.out.write_byte(b'"')
}

///|
/// Lowercase hex digits, for the `\u00XX` escape of a control character.
let hex_digits : Bytes = b"0123456789abcdef"

///|
/// The byte counterpart of `write_quoted`, and simpler: only ASCII ever needs
/// escaping, and every byte of a multi-byte UTF-8 sequence is >= 0x80, so the
/// text passes through untouched without being examined as characters.
fn JsonSerializer::write_quoted_bytes(
  self : JsonSerializer,
  s : BytesView,
) -> Unit {
  self.out.write_byte(b'"')
  for i in 0..<s.length() {
    let byte = s[i]
    let unit = byte.to_int()
    if unit == 0x22 || unit == 0x5C || unit < 0x20 {
      self.out.write_byte(b'\\')
      match unit {
        0x22 => self.out.write_byte(b'"')
        0x5C => self.out.write_byte(b'\\')
        0x0A => self.out.write_byte(b'n')
        0x0D => self.out.write_byte(b'r')
        0x09 => self.out.write_byte(b't')
        _ => {
          self.out.write_byte(b'u')
          self.out.write_byte(b'0')
          self.out.write_byte(b'0')
          self.out.write_byte(hex_digits[unit >> 4])
          self.out.write_byte(hex_digits[unit & 0xF])
        }
      }
    } else {
      self.out.write_byte(byte)
    }
  }
  self.out.write_byte(b'"')
}

///|
/// Numbers are quoted when they appear as an object key and bare otherwise.
fn JsonSerializer::write_number(self : JsonSerializer, text : String) -> Unit {
  self.pre_value()
  if self.in_key {
    self.out.write_byte(b'"')
    self.out.write_string_utf8(text)
    self.out.write_byte(b'"')
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
/// Text that is already UTF-8 is written straight out: no decode on the way
/// in, no encode on the way back, so a document can be read and rewritten
/// without ever being converted.
pub impl @data.Serializer for JsonSerializer with fn serialize_str_bytes(
  self,
  v,
) {
  // A string, so it is legal as an object key — unlike `serialize_bytes`,
  // which is the data model's byte-array type and has no key spelling.
  self.pre_value()
  self.write_quoted_bytes(v)
}

///|
/// JSON has no byte string, so bytes become an array of numbers, matching
/// `serde_json`.
pub impl @data.Serializer for JsonSerializer with fn serialize_bytes(self, v) {
  self.reject_key("a byte string")
  self.pre_value()
  self.out.write_byte(b'[')
  for i in 0..<v.length() {
    if i > 0 {
      self.out.write_byte(b',')
    }
    self.out.write_string_utf8(v[i].to_int().to_string())
  }
  self.out.write_byte(b']')
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
  self.open(false, b'[')
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
  self.close(false, b']')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_map_begin(
  self,
  _hint,
) {
  self.reject_key("a map")
  self.open(true, b'{')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_map_key(self, k) {
  self.pre_key()
  self.in_key = true
  k.serialize(self)
  self.in_key = false
  self.out.write_byte(b':')
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
  self.close(true, b'}')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_struct_begin(
  self,
  _name,
  _len,
) {
  self.reject_key("a struct")
  self.open(true, b'{')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_field(
  self,
  name,
  v,
) {
  self.pre_key()
  self.write_quoted(name)
  self.out.write_byte(b':')
  v.serialize(self)
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_struct_end(self) {
  self.close(true, b'}')
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
  self.open(true, b'{')
  self.pre_key()
  self.write_quoted(name)
  self.out.write_byte(b':')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_newtype_variant(
  self,
  info,
  v,
) {
  self.open_variant(info.name)
  v.serialize(self)
  self.close(true, b'}')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_tuple_variant_begin(
  self,
  info,
  _len,
) {
  self.open_variant(info.name)
  self.open(false, b'[')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_tuple_variant_end(
  self,
) {
  self.close(false, b']')
  self.close(true, b'}')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_struct_variant_begin(
  self,
  info,
  _len,
) {
  self.open_variant(info.name)
  self.open(true, b'{')
}

///|
pub impl @data.Serializer for JsonSerializer with fn serialize_struct_variant_end(
  self,
) {
  self.close(true, b'}')
  self.close(true, b'}')
}

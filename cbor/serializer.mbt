// The CBOR encoder. Definite lengths where a length is known, shortest head
// for every integer.

///|
/// Major types, named rather than spelled as bare numbers at every call site.
const UNSIGNED : Int = 0

///|
const NEGATIVE : Int = 1

///|
const BYTES : Int = 2

///|
const TEXT : Int = 3

///|
const ARRAY : Int = 4

///|
const MAP : Int = 5

///|
const BREAK : Byte = b'\xff'

///|
/// Writes CBOR.
///
/// The stack holds one entry per open container, recording whether it was
/// opened with an indefinite length and therefore needs a break byte to close.
/// `serialize_seq_begin` takes `Int?` and CBOR is the first format able to
/// honour both halves of that: a known length becomes a definite head, and
/// `None` becomes an indefinite container, which is exactly the case the
/// option was introduced for.
struct CborSerializer {
  out : @buffer.Buffer
  breaks : Array[Bool]
}

///|
pub fn CborSerializer::new() -> CborSerializer {
  { out: Buffer(size_hint=256), breaks: [] }
}

///|
/// The bytes written so far. Raises if a container was never closed.
pub fn CborSerializer::finish(
  self : CborSerializer,
) -> Bytes raise @data.SerError {
  if self.breaks.length() > 0 {
    raise @data.SerCustom(
      message="CBOR: \{self.breaks.length()} container(s) opened but never ended",
    )
  }
  self.out.to_bytes()
}

///|
/// `count` bytes of `arg`, most significant first. CBOR is big-endian
/// throughout, unlike most binary formats.
fn CborSerializer::be(
  self : CborSerializer,
  arg : UInt64,
  count : Int,
) -> Unit {
  for i = count - 1; i >= 0; i = i - 1 {
    self.out.write_byte((arg >> (i * 8)).to_uint().to_byte())
  }
}

///|
/// A major type and its argument, in the shortest head that fits.
///
/// Everything in CBOR is this shape: three bits of major type and five bits
/// that either hold the argument outright or say how many bytes follow.
fn CborSerializer::head(
  self : CborSerializer,
  major : Int,
  arg : UInt64,
) -> Unit {
  let tag = major << 5
  if arg < 24 {
    self.out.write_byte((tag | arg.to_uint().reinterpret_as_int()).to_byte())
  } else if arg <= 0xFF {
    self.out.write_byte((tag | 24).to_byte())
    self.be(arg, 1)
  } else if arg <= 0xFFFF {
    self.out.write_byte((tag | 25).to_byte())
    self.be(arg, 2)
  } else if arg <= 0xFFFFFFFF {
    self.out.write_byte((tag | 26).to_byte())
    self.be(arg, 4)
  } else {
    self.out.write_byte((tag | 27).to_byte())
    self.be(arg, 8)
  }
}

///|
/// A signed integer, as whichever of the two integer major types fits.
///
/// CBOR encodes a negative `n` as major type 1 with argument `-1 - n`, which
/// in two's complement is exactly the bitwise complement — and unlike
/// `-1 - n`, the complement does not overflow at `Int64::min_value`.
fn CborSerializer::int(self : CborSerializer, v : Int64) -> Unit {
  if v >= 0 {
    self.head(UNSIGNED, v.reinterpret_as_uint64())
  } else {
    self.head(NEGATIVE, v.lnot().reinterpret_as_uint64())
  }
}

///|
fn CborSerializer::blob(
  self : CborSerializer,
  major : Int,
  payload : BytesView,
) -> Unit {
  self.head(major, payload.length().to_int64().reinterpret_as_uint64())
  self.out.write_bytesview(payload)
}

///|
/// Opens a container, definite when the length is known and indefinite when it
/// is not, and remembers which so `_end` knows whether to write a break.
fn CborSerializer::open(
  self : CborSerializer,
  major : Int,
  hint : Int?,
) -> Unit {
  match hint {
    Some(n) => {
      self.head(major, n.to_int64().reinterpret_as_uint64())
      self.breaks.push(false)
    }
    None => {
      self.out.write_byte(((major << 5) | 31).to_byte())
      self.breaks.push(true)
    }
  }
}

///|
fn CborSerializer::close(self : CborSerializer) -> Unit raise @data.SerError {
  match self.breaks.pop() {
    Some(true) => self.out.write_byte(BREAK)
    Some(false) => ()
    None =>
      raise @data.SerCustom(message="CBOR: container ended without a begin")
  }
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_unit(self) {
  self.out.write_byte(b'\xf6')
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_bool(self, v) {
  self.out.write_byte(if v { b'\xf5' } else { b'\xf4' })
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_byte(self, v) {
  self.head(UNSIGNED, v.to_uint64())
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_int16(self, v) {
  self.int(v.to_int().to_int64())
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_uint16(self, v) {
  self.head(UNSIGNED, v.to_uint64())
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_int(self, v) {
  self.int(v.to_int64())
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_uint(self, v) {
  self.head(UNSIGNED, v.to_uint64())
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_int64(self, v) {
  self.int(v)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_uint64(self, v) {
  self.head(UNSIGNED, v)
}

///|
/// Single precision, not widened to double: CBOR has a head for it, and the
/// whole point of the format is that the encoding says what the value is.
pub impl @data.Serializer for CborSerializer with fn serialize_float(self, v) {
  self.out.write_byte(b'\xfa')
  self.be(v.reinterpret_as_uint().to_uint64(), 4)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_double(self, v) {
  self.out.write_byte(b'\xfb')
  self.be(v.reinterpret_as_uint64(), 8)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_char(self, v) {
  self.blob(TEXT, @utf8.encode(v.to_string())[:])
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_string(self, v) {
  self.blob(TEXT, @utf8.encode(v)[:])
}

///|
/// Overridden: the transport is bytes, so text that is already UTF-8 goes
/// straight out without a round trip through `String`.
pub impl @data.Serializer for CborSerializer with fn serialize_str_bytes(
  self,
  v,
) {
  self.blob(TEXT, v)
}

///|
/// A byte string, which is what the data model meant. JSON has to spell this
/// as an array of numbers; CBOR does not.
pub impl @data.Serializer for CborSerializer with fn serialize_bytes(self, v) {
  self.blob(BYTES, v[:])
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_none(self) {
  self.out.write_byte(b'\xf6')
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_some(self, v) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_unit_variant(
  self,
  info,
) {
  self.blob(TEXT, @utf8.encode(info.name)[:])
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_newtype_variant(
  self,
  info,
  v,
) {
  self.head(MAP, 1)
  self.blob(TEXT, @utf8.encode(info.name)[:])
  v.serialize(self)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_seq_begin(
  self,
  hint,
) {
  self.open(ARRAY, hint)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_seq_element(
  self,
  v,
) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_seq_end(self) {
  self.close()
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_map_begin(
  self,
  hint,
) {
  self.open(MAP, hint)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_map_key(self, k) {
  k.serialize(self)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_map_value(
  self,
  v,
) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_map_end(self) {
  self.close()
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_struct_begin(
  self,
  _name,
  len,
) {
  self.open(MAP, Some(len))
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_field(
  self,
  name,
  v,
) {
  self.blob(TEXT, @utf8.encode(name)[:])
  v.serialize(self)
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_struct_end(self) {
  self.close()
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_tuple_variant_begin(
  self,
  info,
  len,
) {
  self.head(MAP, 1)
  self.blob(TEXT, @utf8.encode(info.name)[:])
  self.open(ARRAY, Some(len))
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_tuple_variant_end(
  self,
) {
  self.close()
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_struct_variant_begin(
  self,
  info,
  len,
) {
  self.head(MAP, 1)
  self.blob(TEXT, @utf8.encode(info.name)[:])
  self.open(MAP, Some(len))
}

///|
pub impl @data.Serializer for CborSerializer with fn serialize_struct_variant_end(
  self,
) {
  self.close()
}

///|
pub impl @data.Serializer for CborSerializer with fn is_human_readable(_self) {
  false
}

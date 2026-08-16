// The MessagePack encoder. Smallest representation for every value: fixints,
// fixstr, fixarray and fixmap wherever the value fits.

///|
/// Writes MessagePack.
///
/// No stack, unlike CBOR and JSON. Every container's length is written up
/// front and nothing has a terminator, so `_end` has nothing to do and depth
/// need not be tracked — the same shape the binary fixture in the root
/// package's tests has, for the same reason.
struct MsgpackSerializer {
  out : @buffer.Buffer
}

///|
pub fn MsgpackSerializer::new() -> MsgpackSerializer {
  { out: Buffer(size_hint=256) }
}

///|
pub fn MsgpackSerializer::finish(self : MsgpackSerializer) -> Bytes {
  self.out.to_bytes()
}

///|
fn MsgpackSerializer::put(self : MsgpackSerializer, marker : Int) -> Unit {
  self.out.write_byte(marker.to_byte())
}

///|
/// `count` bytes of `arg`, most significant first. MessagePack is big-endian
/// throughout, as CBOR is.
fn MsgpackSerializer::be(
  self : MsgpackSerializer,
  arg : UInt64,
  count : Int,
) -> Unit {
  for i = count - 1; i >= 0; i = i - 1 {
    self.out.write_byte((arg >> (i * 8)).to_uint().to_byte())
  }
}

///|
/// An unsigned integer in the narrowest of the five forms that holds it.
fn MsgpackSerializer::uint(self : MsgpackSerializer, v : UInt64) -> Unit {
  if v < 128 {
    self.put(v.to_uint().reinterpret_as_int())
  } else if v <= 0xFF {
    self.put(0xcc)
    self.be(v, 1)
  } else if v <= 0xFFFF {
    self.put(0xcd)
    self.be(v, 2)
  } else if v <= 0xFFFFFFFF {
    self.put(0xce)
    self.be(v, 4)
  } else {
    self.put(0xcf)
    self.be(v, 8)
  }
}

///|
/// A signed integer, negative-fixint first and then the narrowest signed form.
///
/// Non-negative values go through `uint`, which is what every MessagePack
/// encoder does: the unsigned forms are never longer and often shorter.
fn MsgpackSerializer::int(self : MsgpackSerializer, v : Int64) -> Unit {
  if v >= 0 {
    self.uint(v.reinterpret_as_uint64())
  } else if v >= -32 {
    self.put(v.to_int() & 0xFF)
  } else if v >= -128 {
    self.put(0xd0)
    self.be(v.reinterpret_as_uint64(), 1)
  } else if v >= -32768 {
    self.put(0xd1)
    self.be(v.reinterpret_as_uint64(), 2)
  } else if v >= -2147483648 {
    self.put(0xd2)
    self.be(v.reinterpret_as_uint64(), 4)
  } else {
    self.put(0xd3)
    self.be(v.reinterpret_as_uint64(), 8)
  }
}

///|
/// A length prefix from one of three families, and the bytes it counts.
///
/// `fix` is the marker base for the compact form when the length fits in the
/// low bits, or `-1` for byte strings, which have no compact form.
fn MsgpackSerializer::blob(
  self : MsgpackSerializer,
  payload : BytesView,
  fix : Int,
  fix_limit : Int,
  m8 : Int,
  m16 : Int,
  m32 : Int,
) -> Unit {
  let n = payload.length()
  if fix >= 0 && n < fix_limit {
    self.put(fix | n)
  } else if n <= 0xFF && m8 >= 0 {
    self.put(m8)
    self.be(n.to_int64().reinterpret_as_uint64(), 1)
  } else if n <= 0xFFFF {
    self.put(m16)
    self.be(n.to_int64().reinterpret_as_uint64(), 2)
  } else {
    self.put(m32)
    self.be(n.to_int64().reinterpret_as_uint64(), 4)
  }
  self.out.write_bytesview(payload)
}

///|
fn MsgpackSerializer::text(
  self : MsgpackSerializer,
  payload : BytesView,
) -> Unit {
  self.blob(payload, 0xa0, 32, 0xd9, 0xda, 0xdb)
}

///|
/// A container header, or a refusal.
///
/// MessagePack has no indefinite-length container, so an unknown length simply
/// cannot be written. `Array` and `Map` always pass `Some`, so this never
/// fires in practice.
fn MsgpackSerializer::open(
  self : MsgpackSerializer,
  hint : Int?,
  fix : Int,
  m16 : Int,
  m32 : Int,
  kind : String,
) -> Unit raise @data.SerError {
  match hint {
    None =>
      raise @data.UnsupportedType(
        format="MessagePack",
        kind="\{kind} of unknown length",
      )
    Some(n) =>
      if n < 16 {
        self.put(fix | n)
      } else if n <= 0xFFFF {
        self.put(m16)
        self.be(n.to_int64().reinterpret_as_uint64(), 2)
      } else {
        self.put(m32)
        self.be(n.to_int64().reinterpret_as_uint64(), 4)
      }
  }
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_unit(self) {
  self.put(0xc0)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_bool(self, v) {
  self.put(if v { 0xc3 } else { 0xc2 })
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_byte(self, v) {
  self.uint(v.to_uint64())
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_int16(self, v) {
  self.int(v.to_int().to_int64())
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_uint16(
  self,
  v,
) {
  self.uint(v.to_uint64())
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_int(self, v) {
  self.int(v.to_int64())
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_uint(self, v) {
  self.uint(v.to_uint64())
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_int64(self, v) {
  self.int(v)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_uint64(
  self,
  v,
) {
  self.uint(v)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_float(self, v) {
  self.put(0xca)
  self.be(v.reinterpret_as_uint().to_uint64(), 4)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_double(
  self,
  v,
) {
  self.put(0xcb)
  self.be(v.reinterpret_as_uint64(), 8)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_char(self, v) {
  self.text(@utf8.encode(v.to_string())[:])
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_string(
  self,
  v,
) {
  self.text(@utf8.encode(v)[:])
}

///|
/// Overridden: the transport is bytes, so UTF-8 goes straight out.
pub impl @data.Serializer for MsgpackSerializer with fn serialize_str_bytes(
  self,
  v,
) {
  self.text(v)
}

///|
/// A `bin`, not an array of numbers. The distinction JSON cannot make and
/// MessagePack gained in 2013 precisely because it mattered.
pub impl @data.Serializer for MsgpackSerializer with fn serialize_bytes(self, v) {
  self.blob(v[:], -1, 0, 0xc4, 0xc5, 0xc6)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_none(self) {
  self.put(0xc0)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_some(self, v) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_unit_variant(
  self,
  info,
) {
  self.text(@utf8.encode(info.name)[:])
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_newtype_variant(
  self,
  info,
  v,
) {
  self.put(0x81)
  self.text(@utf8.encode(info.name)[:])
  v.serialize(self)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_seq_begin(
  self,
  hint,
) {
  self.open(hint, 0x90, 0xdc, 0xdd, "a sequence")
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_seq_element(
  self,
  v,
) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_seq_end(_self) {

}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_map_begin(
  self,
  hint,
) {
  self.open(hint, 0x80, 0xde, 0xdf, "a map")
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_map_key(
  self,
  k,
) {
  k.serialize(self)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_map_value(
  self,
  v,
) {
  v.serialize(self)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_map_end(_self) {

}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_struct_begin(
  self,
  _name,
  len,
) {
  self.open(Some(len), 0x80, 0xde, 0xdf, "a map")
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_field(
  self,
  name,
  v,
) {
  self.text(@utf8.encode(name)[:])
  v.serialize(self)
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_struct_end(
  _self,
) {

}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_tuple_variant_begin(
  self,
  info,
  len,
) {
  self.put(0x81)
  self.text(@utf8.encode(info.name)[:])
  self.open(Some(len), 0x90, 0xdc, 0xdd, "a sequence")
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_tuple_variant_end(
  _self,
) {

}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_struct_variant_begin(
  self,
  info,
  len,
) {
  self.put(0x81)
  self.text(@utf8.encode(info.name)[:])
  self.open(Some(len), 0x80, 0xde, 0xdf, "a map")
}

///|
pub impl @data.Serializer for MsgpackSerializer with fn serialize_struct_variant_end(
  _self,
) {

}

///|
pub impl @data.Serializer for MsgpackSerializer with fn is_human_readable(_self) {
  false
}

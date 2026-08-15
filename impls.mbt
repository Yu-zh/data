// `Serialize` / `Deserialize` for the builtin types.
//
// These are the leaves of every user-defined implementation: a hand-written
// impl for a struct ultimately bottoms out in these.

///|
pub impl Serialize for Unit with fn serialize(_self, s) {
  s.serialize_unit()
}

///|
pub impl Serialize for Bool with fn serialize(self, s) {
  s.serialize_bool(self)
}

///|
pub impl Serialize for Byte with fn serialize(self, s) {
  s.serialize_byte(self)
}

///|
pub impl Serialize for Int16 with fn serialize(self, s) {
  s.serialize_int16(self)
}

///|
pub impl Serialize for UInt16 with fn serialize(self, s) {
  s.serialize_uint16(self)
}

///|
pub impl Serialize for Int with fn serialize(self, s) {
  s.serialize_int(self)
}

///|
pub impl Serialize for UInt with fn serialize(self, s) {
  s.serialize_uint(self)
}

///|
pub impl Serialize for Int64 with fn serialize(self, s) {
  s.serialize_int64(self)
}

///|
pub impl Serialize for UInt64 with fn serialize(self, s) {
  s.serialize_uint64(self)
}

///|
pub impl Serialize for Float with fn serialize(self, s) {
  s.serialize_float(self)
}

///|
pub impl Serialize for Double with fn serialize(self, s) {
  s.serialize_double(self)
}

///|
pub impl Serialize for Char with fn serialize(self, s) {
  s.serialize_char(self)
}

///|
pub impl Serialize for String with fn serialize(self, s) {
  s.serialize_string(self)
}

///|
pub impl Serialize for Bytes with fn serialize(self, s) {
  s.serialize_bytes(self)
}

///|
pub impl[T : Serialize] Serialize for T? with fn serialize(self, s) {
  match self {
    None => s.serialize_none()
    Some(v) => s.serialize_some(v)
  }
}

///|
pub impl[T : Serialize] Serialize for Array[T] with fn serialize(self, s) {
  s.serialize_seq_begin(Some(self.length()))
  for x in self {
    s.serialize_seq_element(x)
  }
  s.serialize_seq_end()
}

///|
pub impl[T : Serialize] Serialize for FixedArray[T] with fn serialize(self, s) {
  s.serialize_seq_begin(Some(self.length()))
  for x in self {
    s.serialize_seq_element(x)
  }
  s.serialize_seq_end()
}

///|
pub impl[K : Serialize, V : Serialize] Serialize for Map[K, V] with fn serialize(
  self,
  s,
) {
  s.serialize_map_begin(Some(self.length()))
  for k, v in self {
    s.serialize_map_key(k)
    s.serialize_map_value(v)
  }
  s.serialize_map_end()
}

///|
pub impl[A : Serialize, B : Serialize] Serialize for (A, B) with fn serialize(
  self,
  s,
) {
  s.serialize_tuple_begin(2)
  s.serialize_tuple_element(self.0)
  s.serialize_tuple_element(self.1)
  s.serialize_tuple_end()
}

///|
pub impl[A : Serialize, B : Serialize, C : Serialize] Serialize for (A, B, C) with fn serialize(
  self,
  s,
) {
  s.serialize_tuple_begin(3)
  s.serialize_tuple_element(self.0)
  s.serialize_tuple_element(self.1)
  s.serialize_tuple_element(self.2)
  s.serialize_tuple_end()
}

///|
/// `Value` is itself a member of the data model, so it round-trips through any
/// format like any other type.
pub impl Serialize for Value with fn serialize(self, s) {
  match self {
    Null => s.serialize_unit()
    Boolean(b) => s.serialize_bool(b)
    Int(i) => s.serialize_int64(i)
    UInt(u) => s.serialize_uint64(u)
    Double(d) => s.serialize_double(d)
    Str(v) => s.serialize_str_bytes(v)
    Bytes(b) => s.serialize_bytes(b)
    Seq(items) => {
      s.serialize_seq_begin(Some(items.length()))
      for item in items {
        s.serialize_seq_element(item)
      }
      s.serialize_seq_end()
    }
    Map(entries) => {
      s.serialize_map_begin(Some(entries.length()))
      for entry in entries {
        s.serialize_map_key(entry.0)
        s.serialize_map_value(entry.1)
      }
      s.serialize_map_end()
    }
  }
}

///|
pub impl Deserialize for Unit with fn deserialize(d) {
  d.deserialize_unit()
}

///|
pub impl Deserialize for Bool with fn deserialize(d) {
  d.deserialize_bool()
}

///|
pub impl Deserialize for Byte with fn deserialize(d) {
  d.deserialize_byte()
}

///|
pub impl Deserialize for Int16 with fn deserialize(d) {
  d.deserialize_int16()
}

///|
pub impl Deserialize for UInt16 with fn deserialize(d) {
  d.deserialize_uint16()
}

///|
pub impl Deserialize for Int with fn deserialize(d) {
  d.deserialize_int()
}

///|
pub impl Deserialize for UInt with fn deserialize(d) {
  d.deserialize_uint()
}

///|
pub impl Deserialize for Int64 with fn deserialize(d) {
  d.deserialize_int64()
}

///|
pub impl Deserialize for UInt64 with fn deserialize(d) {
  d.deserialize_uint64()
}

///|
pub impl Deserialize for Float with fn deserialize(d) {
  d.deserialize_float()
}

///|
pub impl Deserialize for Double with fn deserialize(d) {
  d.deserialize_double()
}

///|
pub impl Deserialize for Char with fn deserialize(d) {
  d.deserialize_char()
}

///|
pub impl Deserialize for String with fn deserialize(d) {
  d.deserialize_string()
}

///|
pub impl Deserialize for Bytes with fn deserialize(d) {
  d.deserialize_bytes()
}

///|
pub impl[T : Deserialize] Deserialize for T? with fn deserialize(d) {
  d.deserialize_option()
}

///|
/// Bounds a length hint before it becomes an allocation.
///
/// The hint is read from the input, so a hostile four-byte length must not turn
/// into a multi-gigabyte reservation. A format that can compare the count
/// against its remaining input should reject it outright; one that cannot — a
/// streaming reader, say — has no such option, so the cap lives here where
/// every `Deserialize` benefits. Serde bounds it the same way and for the same
/// reason (`size_hint::cautious`): reserve a little, and let `push` grow the
/// rest at the cost of a few reallocations on genuinely large inputs.
fn cautious_capacity(hint : Int) -> Int {
  if hint < 0 {
    0
  } else if hint > 4096 {
    4096
  } else {
    hint
  }
}

///|
pub impl[T : Deserialize] Deserialize for Array[T] with fn deserialize(d) {
  let out = match d.deserialize_seq_begin() {
    Some(n) => Array::new(capacity=cautious_capacity(n))
    None => []
  }
  while (d.deserialize_seq_next() : T?) is Some(x) {
    out.push(x)
  }
  out
}

///|
pub impl[T : Deserialize] Deserialize for FixedArray[T] with fn deserialize(d) {
  let out : Array[T] = Deserialize::deserialize(d)
  FixedArray::from_array(out)
}

///|
pub impl[K : Deserialize + Hash + Eq, V : Deserialize] Deserialize for Map[K, V] with fn deserialize(
  d,
) {
  let _ = d.deserialize_map_begin()
  let out : Map[K, V] = Map([], capacity=8)
  while (d.deserialize_map_next_key() : K?) is Some(k) {
    let v : V = d.deserialize_map_value()
    out[k] = v
  }
  out
}

///|
pub impl[A : Deserialize, B : Deserialize] Deserialize for (A, B) with fn deserialize(
  d,
) {
  d.deserialize_tuple_begin(2)
  let a : A = d.deserialize_tuple_next()
  let b : B = d.deserialize_tuple_next()
  d.deserialize_tuple_end()
  (a, b)
}

///|
pub impl[A : Deserialize, B : Deserialize, C : Deserialize] Deserialize for (
  A,
  B,
  C,
) with fn deserialize(d) {
  d.deserialize_tuple_begin(3)
  let a : A = d.deserialize_tuple_next()
  let b : B = d.deserialize_tuple_next()
  let c : C = d.deserialize_tuple_next()
  d.deserialize_tuple_end()
  (a, b, c)
}

///|
pub impl Deserialize for Value with fn deserialize(d) {
  d.deserialize_any()
}

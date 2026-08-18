///|
pub extend Value with Serialize::{serialize}

///|
pub extend Value with Deserialize::{deserialize}

///|
#deprecated("use `==` and `!=`", skip_current_package=true)
#doc(hidden)
pub extend Value with Eq::{equal, not_equal}

///|
#deprecated("reach it through the `Debug` bound", skip_current_package=true)
#doc(hidden)
pub extend Value with @debug.Debug::{to_repr}

///|
#deprecated("reach it through the `Show` bound", skip_current_package=true)
#doc(hidden)
pub extend Value with Show::{output, to_string}

///|
pub extend ValueSerializer with Serializer::{
  is_human_readable,
  serialize_bool,
  serialize_byte,
  serialize_bytes,
  serialize_char,
  serialize_double,
  serialize_field,
  serialize_float,
  serialize_int,
  serialize_int16,
  serialize_int64,
  serialize_map_begin,
  serialize_map_end,
  serialize_map_key,
  serialize_map_value,
  serialize_newtype_struct,
  serialize_newtype_variant,
  serialize_none,
  serialize_seq_begin,
  serialize_seq_element,
  serialize_seq_end,
  serialize_some,
  serialize_str_bytes,
  serialize_string,
  serialize_struct_begin,
  serialize_struct_end,
  serialize_struct_variant_begin,
  serialize_struct_variant_end,
  serialize_struct_variant_field,
  serialize_tuple_begin,
  serialize_tuple_element,
  serialize_tuple_end,
  serialize_tuple_struct_begin,
  serialize_tuple_struct_end,
  serialize_tuple_struct_field,
  serialize_tuple_variant_begin,
  serialize_tuple_variant_element,
  serialize_tuple_variant_end,
  serialize_uint,
  serialize_uint16,
  serialize_uint64,
  serialize_unit,
  serialize_unit_struct,
  serialize_unit_variant,
}

///|
pub extend ValueDeserializer with Deserializer::{
  deserialize_any,
  deserialize_bool,
  deserialize_byte,
  deserialize_bytes,
  deserialize_char,
  deserialize_double,
  deserialize_enum_begin,
  deserialize_enum_end,
  deserialize_field,
  deserialize_field_name,
  deserialize_field_value,
  deserialize_float,
  deserialize_int,
  deserialize_int16,
  deserialize_int64,
  deserialize_map_begin,
  deserialize_map_next_key,
  deserialize_map_value,
  deserialize_newtype_struct,
  deserialize_newtype_variant,
  deserialize_option,
  deserialize_seq_begin,
  deserialize_seq_next,
  deserialize_str_bytes,
  deserialize_string,
  deserialize_struct_begin,
  deserialize_tuple_begin,
  deserialize_tuple_end,
  deserialize_tuple_next,
  deserialize_tuple_struct_begin,
  deserialize_uint,
  deserialize_uint16,
  deserialize_uint64,
  deserialize_unit,
  deserialize_unit_struct,
  deserialize_unit_variant,
  is_human_readable,
  path,
  skip_value,
}

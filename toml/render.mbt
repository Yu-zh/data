// `Value` to TOML bytes.
//
// The reordering this file exists for: within a table, TOML requires every
// scalar key to appear before the first sub-table header, because a header
// switches which table subsequent keys belong to. So each table is emitted in
// three passes — scalars, then sub-tables, then arrays of tables — rather than
// in the order the fields were declared.
//
// Nothing is decoded on the way out. Every character TOML escapes is ASCII,
// and no byte of a multi-byte UTF-8 sequence is below 0x80, so a string can be
// escaped byte-wise and everything else copied through verbatim — no `String`
// is built for a value or a key.

///|
fn render(root : @data.Value) -> Bytes raise @data.SerError {
  let entries = match root {
    Map(entries) => entries
    other =>
      raise @data.UnsupportedType(
        format="TOML",
        kind="a top-level \{other.type_name()}; a TOML document is a table",
      )
  }
  let out = Buffer(size_hint=256)
  render_table(out, [], entries)
  out.to_bytes()
}

///|
/// ASCII punctuation and rendered numbers, which are the only `String`s this
/// file writes.
fn put(out : @buffer.Buffer, ascii : String) -> Unit {
  out.write_bytesview(@utf8.encode(ascii)[:])
}

///|
/// Whether a value becomes a `[header]` rather than a `key = value` line.
fn is_table(value : @data.Value) -> Bool {
  value is Map(_)
}

///|
/// Whether a value becomes `[[header]]` blocks: a non-empty sequence whose
/// every element is a table. An empty one stays an inline `[]`, since there is
/// no header form that means "no elements".
fn is_table_array(value : @data.Value) -> Bool {
  match value {
    Seq(items) => items.length() > 0 && items.iter().all(is_table)
    _ => false
  }
}

///|
fn render_table(
  out : @buffer.Buffer,
  prefix : Array[BytesView],
  entries : Array[(@data.Value, @data.Value)],
) -> Unit raise @data.SerError {
  // Pass one: the scalars, which have to precede any header.
  for entry in entries {
    let key = table_key(entry.0)
    let value = entry.1
    // A key with no value is dropped rather than spelled, which is how TOML
    // and serde both treat an absent optional field.
    if value is Null {
      continue
    }
    if is_table(value) || is_table_array(value) {
      continue
    }
    write_key(out, key)
    put(out, " = ")
    write_inline(out, value)
    out.write_byte(b'\n')
  }
  // Pass two: sub-tables.
  for entry in entries {
    let key = table_key(entry.0)
    guard entry.1 is Map(inner) else { continue }
    let path = prefix + [key]
    put(out, "\n[")
    write_path(out, path)
    put(out, "]\n")
    render_table(out, path, inner)
  }
  // Pass three: arrays of tables.
  for entry in entries {
    let key = table_key(entry.0)
    guard is_table_array(entry.1) else { continue }
    guard entry.1 is Seq(items) else { continue }
    let path = prefix + [key]
    for item in items {
      guard item is Map(inner) else { continue }
      put(out, "\n[[")
      write_path(out, path)
      put(out, "]]\n")
      render_table(out, path, inner)
    }
  }
}

///|
/// A table key, which TOML requires to be text. Taken as the bytes the data
/// model already holds rather than decoded and re-encoded.
fn table_key(key : @data.Value) -> BytesView raise @data.SerError {
  match key {
    Str(raw) => raw
    other =>
      raise @data.UnsupportedType(
        format="TOML",
        kind="a non-string table key (\{other.type_name()}); keys are strings",
      )
  }
}

///|
fn write_path(out : @buffer.Buffer, path : Array[BytesView]) -> Unit {
  for i, segment in path {
    if i > 0 {
      out.write_byte(b'.')
    }
    write_key(out, segment)
  }
}

///|
/// A bare key where TOML allows one, a quoted key otherwise.
fn write_key(out : @buffer.Buffer, key : BytesView) -> Unit {
  if is_bare_key(key) {
    out.write_bytesview(key)
  } else {
    write_quoted(out, key)
  }
}

///|
fn is_bare_key(key : BytesView) -> Bool {
  if key.length() == 0 {
    return false
  }
  for b in key.iter() {
    let v = b.to_int()
    let ok = (v >= 0x41 && v <= 0x5A) ||
      (v >= 0x61 && v <= 0x7A) ||
      (v >= 0x30 && v <= 0x39) ||
      v == 0x5F ||
      v == 0x2D
    if !ok {
      return false
    }
  }
  true
}

///|
fn hex_digit(v : Int) -> Byte {
  if v < 10 {
    (0x30 + v).to_byte()
  } else {
    (0x61 + v - 10).to_byte()
  }
}

///|
/// A basic string, escaped byte-wise.
fn write_quoted(out : @buffer.Buffer, raw : BytesView) -> Unit {
  out.write_byte(b'"')
  for b in raw.iter() {
    let v = b.to_int()
    match v {
      0x22 => put(out, "\\\"")
      0x5C => put(out, "\\\\")
      0x0A => put(out, "\\n")
      0x0D => put(out, "\\r")
      0x09 => put(out, "\\t")
      _ =>
        if v < 0x20 {
          put(out, "\\u00")
          out.write_byte(hex_digit((v >> 4) & 0xF))
          out.write_byte(hex_digit(v & 0xF))
        } else {
          out.write_byte(b)
        }
    }
  }
  out.write_byte(b'"')
}

///|
/// A value in the position where TOML expects one on a single line.
fn write_inline(
  out : @buffer.Buffer,
  value : @data.Value,
) -> Unit raise @data.SerError {
  match value {
    Null =>
      // Reached only from inside an array or inline table; at table level the
      // key was dropped before getting here.
      raise @data.UnsupportedType(
        format="TOML",
        kind="a null inside an array or inline table",
      )
    Boolean(b) => put(out, if b { "true" } else { "false" })
    Int(v) => put(out, v.to_string())
    UInt(v) => put(out, v.to_string())
    Double(d) => put(out, double_text(d))
    Str(raw) => write_quoted(out, raw)
    Bytes(_) =>
      raise @data.UnsupportedType(
        format="TOML",
        kind="a byte string; TOML has no byte type",
      )
    Seq(items) => {
      out.write_byte(b'[')
      for i, item in items {
        if i > 0 {
          put(out, ", ")
        }
        write_inline(out, item)
      }
      out.write_byte(b']')
    }
    Map(entries) => {
      put(out, "{ ")
      let mut first = true
      for entry in entries {
        if entry.1 is Null {
          continue
        }
        if !first {
          put(out, ", ")
        }
        first = false
        write_key(out, table_key(entry.0))
        put(out, " = ")
        write_inline(out, entry.1)
      }
      put(out, " }")
    }
  }
}

///|
/// A float, always with a `.` or an exponent so TOML reads it back as a float
/// rather than an integer.
///
/// Infinity and NaN are spelled rather than refused: TOML has `inf`, `-inf`
/// and `nan`, so this is one place the format is wider than JSON.
fn double_text(d : Double) -> String {
  if d.is_nan() {
    return "nan"
  }
  if d.is_inf() {
    return if d > 0.0 { "inf" } else { "-inf" }
  }
  let text = d.to_string()
  let plain = text
    .to_array()
    .iter()
    .all(c => c != '.' && c != 'e' && c != 'E' && c != 'n')
  if plain {
    text + ".0"
  } else {
    text
  }
}

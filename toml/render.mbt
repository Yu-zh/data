// `Value` to TOML text.
//
// The reordering this file exists for: within a table, TOML requires every
// scalar key to appear before the first sub-table header, because a header
// switches which table subsequent keys belong to. So each table is emitted in
// three passes — scalars, then sub-tables, then arrays of tables — rather than
// in the order the fields were declared.

///|
fn render(root : @data.Value) -> String raise @data.SerError {
  let entries = match root {
    Map(entries) => entries
    other =>
      raise @data.UnsupportedType(
        format="TOML",
        kind="a top-level \{other.type_name()}; a TOML document is a table",
      )
  }
  let out = StringBuilder::new()
  render_table(out, [], entries)
  out.to_string()
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
  out : StringBuilder,
  prefix : Array[String],
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
    out.write_string(key_text(key))
    out.write_string(" = ")
    write_inline(out, value)
    out.write_string("\n")
  }
  // Pass two: sub-tables.
  for entry in entries {
    let key = table_key(entry.0)
    guard entry.1 is Map(inner) else { continue }
    let path = prefix + [key]
    out.write_string("\n[")
    out.write_string(path_text(path))
    out.write_string("]\n")
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
      out.write_string("\n[[")
      out.write_string(path_text(path))
      out.write_string("]]\n")
      render_table(out, path, inner)
    }
  }
}

///|
/// A table key, which TOML requires to be text.
fn table_key(key : @data.Value) -> String raise @data.SerError {
  match key.text() {
    Some(text) => text
    None =>
      raise @data.UnsupportedType(
        format="TOML",
        kind="a non-string table key (\{key.type_name()}); keys are strings",
      )
  }
}

///|
fn path_text(path : Array[String]) -> String {
  let parts = path.map(key_text)
  parts.join(".")
}

///|
/// A bare key where TOML allows one, a quoted key otherwise.
fn key_text(key : String) -> String {
  let bare = key.length() > 0 &&
    key
    .to_array()
    .iter()
    .all(c => {
      let v = c.to_int()
      (v >= 0x41 && v <= 0x5A) ||
      (v >= 0x61 && v <= 0x7A) ||
      (v >= 0x30 && v <= 0x39) ||
      v == 0x5F ||
      v == 0x2D
    })
  if bare {
    key
  } else {
    quote(key)
  }
}

///|
fn quote(text : String) -> String {
  let out = StringBuilder::new()
  out.write_char('"')
  for c in text {
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ =>
        if c.to_int() < 0x20 {
          out.write_string("\\u")
          let hex = "0123456789abcdef".to_array()
          let v = c.to_int()
          out.write_char('0')
          out.write_char('0')
          out.write_char(hex[(v >> 4) & 0xF])
          out.write_char(hex[v & 0xF])
        } else {
          out.write_char(c)
        }
    }
  }
  out.write_char('"')
  out.to_string()
}

///|
/// A value in the position where TOML expects one on a single line.
fn write_inline(
  out : StringBuilder,
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
    Boolean(b) => out.write_string(if b { "true" } else { "false" })
    Int(v) => out.write_string(v.to_string())
    UInt(v) => out.write_string(v.to_string())
    Double(d) => out.write_string(double_text(d))
    Str(_) =>
      match value.text() {
        Some(text) => out.write_string(quote(text))
        None =>
          raise @data.SerCustom(message="TOML: a string is not valid UTF-8")
      }
    Bytes(_) =>
      raise @data.UnsupportedType(
        format="TOML",
        kind="a byte string; TOML has no byte type",
      )
    Seq(items) => {
      out.write_string("[")
      for i, item in items {
        if i > 0 {
          out.write_string(", ")
        }
        write_inline(out, item)
      }
      out.write_string("]")
    }
    Map(entries) => {
      out.write_string("{ ")
      let mut first = true
      for entry in entries {
        if entry.1 is Null {
          continue
        }
        if !first {
          out.write_string(", ")
        }
        first = false
        out.write_string(key_text(table_key(entry.0)))
        out.write_string(" = ")
        write_inline(out, entry.1)
      }
      out.write_string(" }")
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

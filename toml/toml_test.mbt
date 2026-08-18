// Tests for the TOML codec.

///|
pub(all) struct Server {
  host : String
  port : Int
  tags : Array[String]
  timeout : Double?
} derive(Eq, Debug)

///|
pub impl @data.Serialize for Server with fn serialize(self, s) {
  s.serialize_struct_begin("Server", 4)
  s.serialize_field("host", self.host)
  s.serialize_field("port", self.port)
  s.serialize_field("tags", self.tags)
  s.serialize_field("timeout", self.timeout)
  s.serialize_struct_end()
}

///|
pub impl @data.Deserialize for Server with fn deserialize(d) {
  d.deserialize_struct_begin("Server", ["host", "port", "tags", "timeout"])
  let mut host : String? = None
  let mut port : Int? = None
  let mut tags : Array[String]? = None
  let mut timeout : Double? = None
  while d.deserialize_field_name() is Some(name) {
    match name {
      "host" => host = Some(d.deserialize_field_value())
      "port" => port = Some(d.deserialize_field_value())
      "tags" => tags = Some(d.deserialize_field_value())
      "timeout" => timeout = d.deserialize_field_value()
      _ => d.skip_value()
    }
  }
  {
    host: @data.required(host, name="host", path=d.path()),
    port: @data.required(port, name="port", path=d.path()),
    tags: @data.required(tags, name="tags", path=d.path()),
    timeout,
  }
}

///|
pub(all) struct Config {
  name : String
  server : Server
} derive(Eq, Debug)

///|
pub impl @data.Serialize for Config with fn serialize(self, s) {
  s.serialize_struct_begin("Config", 2)
  s.serialize_field("name", self.name)
  s.serialize_field("server", self.server)
  s.serialize_struct_end()
}

///|
pub impl @data.Deserialize for Config with fn deserialize(d) {
  d.deserialize_struct_begin("Config", ["name", "server"])
  let mut name : String? = None
  let mut server : Server? = None
  while d.deserialize_field_name() is Some(f) {
    match f {
      "name" => name = Some(d.deserialize_field_value())
      "server" => server = Some(d.deserialize_field_value())
      _ => d.skip_value()
    }
  }
  {
    name: @data.required(name, name="name", path=d.path()),
    server: @data.required(server, name="server", path=d.path()),
  }
}

// ---- rendering ----

///|
/// A nested struct becomes a `[header]` block rather than an inline table.
test "a nested struct becomes a sub-table" {
  let c = Config::{
    name: "prod",
    server: { host: "localhost", port: 8080, tags: ["a", "b"], timeout: None },
  }
  inspect(
    @toml.to_string(c),
    content=(
      #|name = "prod"
      #|
      #|[server]
      #|host = "localhost"
      #|port = 8080
      #|tags = ["a", "b"]
      #|
    ),
  )
}

///|
/// The reason this format cannot stream, and the case the previous test does
/// not cover: `b` is declared after `sub`, but a `[sub]` header captures
/// everything written after it, so `b` has to be hoisted above it. A streaming
/// serializer sees `serialize_field` in declaration order with no lookahead,
/// and would emit `b = 3` into `[sub]` — silently, in the wrong table.
test "a scalar declared after a sub-table is hoisted above it" {
  let doc : Map[String, @data.Value] = {
    "a": Int(1L),
    "sub": Map([(Str(b"x"), Int(2L))]),
    "b": Int(3L),
  }
  inspect(
    @toml.to_string(doc),
    content=(
      #|a = 1
      #|b = 3
      #|
      #|[sub]
      #|x = 2
      #|
    ),
  )
}

///|
/// An absent optional is omitted rather than spelled, because TOML has no null.
test "a None field disappears instead of becoming null" {
  let with_timeout = Server::{
    host: "h",
    port: 1,
    tags: [],
    timeout: Some(1.5),
  }
  let without = Server::{ host: "h", port: 1, tags: [], timeout: None }
  inspect(
    @toml.to_string(with_timeout),
    content=(
      #|host = "h"
      #|port = 1
      #|tags = []
      #|timeout = 1.5
      #|
    ),
  )
  inspect(
    @toml.to_string(without),
    content=(
      #|host = "h"
      #|port = 1
      #|tags = []
      #|
    ),
  )
}

///|
/// Floats always carry a `.` or an exponent, or TOML would read them back as
/// integers.
test "whole floats keep a decimal point" {
  let s = Server::{ host: "h", port: 1, tags: [], timeout: Some(2.0) }
  assert_true(@toml.to_string(s).contains("timeout = 2.0"))
}

///|
/// Where TOML is wider than JSON: it can spell these, so nothing has to raise.
test "infinity and NaN survive, unlike in JSON" {
  let inf = Server::{
    host: "h",
    port: 1,
    tags: [],
    timeout: Some(@double.infinity),
  }
  assert_true(@toml.to_string(inf).contains("timeout = inf"))
  let back : Server = @toml.from_string(@toml.to_string(inf))
  assert_true(back.timeout.unwrap().is_inf())
}

// ---- round-tripping ----

///|
test "a nested config round-trips" {
  let c = Config::{
    name: "prod",
    server: {
      host: "localhost",
      port: 8080,
      tags: ["a", "b"],
      timeout: Some(30.5),
    },
  }
  assert_eq((@toml.from_string(@toml.to_string(c)) : Config), c)
}

///|
test "keys that are not bare are quoted and read back" {
  let m : Map[String, Int] = { "with space": 1, "dot.ted": 2, "plain": 3 }
  let text = @toml.to_string(m)
  assert_true(text.contains("\"with space\" = 1"))
  assert_eq((@toml.from_string(text) : Map[String, Int]), m)
}

// ---- parsing what this package does not write ----

///|
test "comments, whitespace and literal strings are accepted" {
  let text =
    #|# a leading comment
    #|host = 'localhost'   # trailing
    #|
    #|port   =   8080
    #|tags = [
    #|  "a",
    #|  "b",   # inside the array
    #|]
    #|
  let s : Server = @toml.from_string(text)
  assert_eq(s, Server::{
    host: "localhost",
    port: 8080,
    tags: ["a", "b"],
    timeout: None,
  })
}

///|
test "underscores and the integer forms TOML allows" {
  let m : Map[String, Int] = @toml.from_string("a = 1_000\nb = +7\nc = -7\n")
  assert_eq(m, { "a": 1000, "b": 7, "c": -7 })
}

///|
test "dotted keys build nested tables" {
  let text = "server.host = \"h\"\nserver.port = 1\nserver.tags = []\n"
  let c : Map[String, Server] = @toml.from_string(text)
  assert_eq(c.get("server").unwrap().host, "h")
}

///|
test "an inline table parses like a sub-table" {
  let text = "server = { host = \"h\", port = 1, tags = [] }\n"
  let c : Map[String, Server] = @toml.from_string(text)
  assert_eq(c.get("server").unwrap().port, 1)
}

///|
/// `[[x]]` is the only way TOML spells an array of tables, and the renderer
/// emits it for any non-empty sequence of maps.
test "arrays of tables round-trip" {
  let servers : Map[String, Array[Server]] = {
    "node": [
      { host: "a", port: 1, tags: [], timeout: None },
      { host: "b", port: 2, tags: [], timeout: None },
    ],
  }
  let text = @toml.to_string(servers)
  assert_true(text.contains("[[node]]"))
  assert_eq((@toml.from_string(text) : Map[String, Array[Server]]), servers)
}

// ---- what TOML cannot represent ----

///|
test "a non-table root is refused, because a document is a table" {
  try @toml.to_string(42) catch {
    e =>
      inspect(
        e,
        content=(
          #|TOML cannot serialize a top-level integer; a TOML document is a table
        ),
      )
  } noraise {
    _ => fail("expected a scalar root to be refused")
  }
}

///|
test "byte strings are refused rather than given an invented spelling" {
  let m : Map[String, Bytes] = { "k": b"\x01" }
  try @toml.to_string(m) catch {
    e =>
      inspect(
        e,
        content=(
          #|TOML cannot serialize a byte string; TOML has no byte type
        ),
      )
  } noraise {
    _ => fail("expected bytes to be refused")
  }
}

///|
test "a non-string table key is refused" {
  let m : Map[Int, Int] = { 1: 2 }
  try @toml.to_string(m) catch {
    e =>
      inspect(
        e,
        content=(
          #|TOML cannot serialize a non-string table key (integer); keys are strings
        ),
      )
  } noraise {
    _ => fail("expected a non-string key to be refused")
  }
}

///|
/// The one common TOML type with no counterpart in `Value`. Coercing it to a
/// string would round-trip into something that is no longer a datetime, so it
/// is refused with a message that says why.
test "datetimes are refused rather than coerced" {
  try
    (@toml.from_string("when = 1979-05-27T07:32:00Z\n") : Map[String, String])
  catch {
    e =>
      inspect(
        e,
        content=(
          #|$.when: TOML: datetimes are not part of the data model
        ),
      )
  } noraise {
    _ => fail("expected a datetime to be refused")
  }
}

///|
test "a duplicate key is an error rather than a silent overwrite" {
  try (@toml.from_string("a = 1\na = 2\n") : Map[String, Int]) catch {
    e =>
      inspect(
        e,
        content=(
          #|$.a: TOML: duplicate key `a`
        ),
      )
  } noraise {
    _ => fail("expected a duplicate key to be refused")
  }
}

// ---- the trait implementations ----

///|
/// The types exist so TOML can be used wherever a format is expected, not
/// only through the two free functions. This is the same value written both
/// ways.
test "the serializer type produces what to_string does" {
  let doc : Map[String, Int] = { "a": 1 }
  let s = @toml.TomlSerializer::new()
  @data.Serialize::serialize(doc, s)
  assert_eq(s.finish(), @toml.to_bytes(doc))
}

///|
test "the deserializer type reads what from_string does" {
  let text = b"a = 1\nb = 2\n"
  let d = @toml.TomlDeserializer::new(text)
  let direct : Map[String, Int] = @data.Deserialize::deserialize(d)
  d.finish()
  assert_eq(direct, (@toml.from_bytes(text) : Map[String, Int]))
}

///|
/// Answered on purpose rather than inherited from `Value`, which returns the
/// same thing today and might not always.
test "TOML declares itself human-readable" {
  assert_true(@data.Serializer::is_human_readable(@toml.TomlSerializer::new()))
  assert_true(
    @data.Deserializer::is_human_readable(@toml.TomlDeserializer::new(b"")),
  )
}

///|
/// The reordering has to survive going through the trait, not only through
/// `to_string` — the serializer is where the buffering lives.
test "a scalar after a sub-table is hoisted through the trait too" {
  let doc : Map[String, @data.Value] = {
    "a": Int(1L),
    "sub": Map([(Str(b"x"), Int(2L))]),
    "b": Int(3L),
  }
  let s = @toml.TomlSerializer::new()
  @data.Serialize::serialize(doc, s)
  inspect(
    @utf8.decode_lossy(s.finish()),
    content=(
      #|a = 1
      #|b = 3
      #|
      #|[sub]
      #|x = 2
      #|
    ),
  )
}

// ---- the transport is bytes ----

///|
/// The point of escaping byte-wise: no byte above ASCII is ever inspected, so
/// multi-byte UTF-8 passes through the writer untouched and comes back out of
/// the reader as a borrowed view.
test "non-ASCII survives without being decoded" {
  let m : Map[String, String] = { "key": "value with an em dash", "pi": "3.14" }
  let bytes = @toml.to_bytes(m)
  assert_eq((@toml.from_bytes(bytes) : Map[String, String]), m)
}

///|
test "multi-byte keys and values round-trip through bytes" {
  let m : Map[String, String] = { "\u{952}": "\u{503C}", "\u{3C0}": "3.14" }
  let bytes = @toml.to_bytes(m)
  assert_eq((@toml.from_bytes(bytes) : Map[String, String]), m)
  // Quoted, because the key is not bare — but its bytes are copied verbatim,
  // since none of them is below 0x80.
  assert_true(@utf8.decode_lossy(bytes).contains("\"\u{952}\" = "))
}

///|
test "to_string and from_string are conveniences over the bytes" {
  let m : Map[String, Int] = { "a": 1 }
  assert_eq(@toml.to_string(m), @utf8.decode_lossy(@toml.to_bytes(m)))
  let text = "a = 1\n"
  assert_eq(
    (@toml.from_string(text) : Map[String, Int]),
    (@toml.from_bytes(@utf8.encode(text)) : Map[String, Int]),
  )
}

///|
/// Control characters still need escaping, and that path is byte-wise too.
test "control characters are escaped, everything else copied" {
  let m : Map[String, String] = { "k": "a\u{01}b\tc" }
  inspect(
    @toml.to_string(m),
    content=(
      #|k = "a\u0001b\tc"
      #|
    ),
  )
  assert_eq((@toml.from_string(@toml.to_string(m)) : Map[String, String]), m)
}

# Yu-zh/data

A serde-shaped serialization framework for MoonBit.

A type describes itself in terms of a fixed **data model**. A format knows how
to read and write that data model. Neither knows about the other — so N types
and M formats cost N + M implementations instead of N × M.

```mbt nocheck
///|
#data.derive(Serialize, Deserialize)
pub(all) struct User {
  name : String
  age : Int
}

// Works with every format, without the type mentioning any of them.

///|
let bytes = @json.to_bytes(user)

///|
let value = @data.to_value(user)
```

## Install

```bash
moon add Yu-zh/data
```

Then import what you need in `moon.pkg`:

```
import {
  "Yu-zh/data",
  "Yu-zh/data/json",
}
```

## The five pieces

| | |
|---|---|
| `Serialize` | a type describing itself to any `Serializer` |
| `Deserialize` | a type reconstructing itself from any `Deserializer` |
| `Serializer` | a format receiving the data model |
| `Deserializer` | a format producing the data model |
| `Value` | the data model made concrete, for when a type is not known ahead of time |

`Value` holds strings as UTF-8 `BytesView`s, not as MoonBit `String`s. A document
contains text in some encoding; turning that into UTF-16 is a service to one
particular consumer, so the consumer that wants it pays — `Value::text()` — and
a document can otherwise be read and written again without ever being
converted. Parsing *borrows*: a string in a `Value` is a view into the document
it came from, so no text is copied at all — MoonBit's collector keeps the
document alive, with none of the lifetime machinery Rust needs for the same
trick. The cost is retention, so `Value::detach()` deep-copies when a caller
keeps a few fields and wants the document released.

`Serializer` and `Deserializer` carry both paths: `serialize_string`
/ `deserialize_string` for text, `serialize_str_bytes` / `deserialize_str_bytes`
for UTF-8, each defaulting to the other so a format implements only what suits
it.

The two traits a *type* implements are, in full:

```mbt nocheck
///|
pub(open) trait Serialize {
  fn[S : Serializer] serialize(Self, S) -> Unit raise SerError
}

///|
pub(open) trait Deserialize {
  fn[D : Deserializer] deserialize(D) -> Self raise DeError
}
```

Both are polymorphic in the format, so neither has a trait-object form — the
same as in Rust. Reach for `Value` when a heterogeneous collection is needed.

## Writing an implementation

Everything ships with implementations already: the fourteen primitives
(`Bool`, `Int`, `Int64`, `UInt`, `UInt64`, `Int16`, `UInt16`, `Byte`, `Float`,
`Double`, `Char`, `String`, `Bytes`, `Unit`), plus `Option`, `Array`,
`FixedArray`, `Map`, 2- and 3-tuples, and `Value` itself.

For your own types, either write the two implementations or generate them.
Written by hand they look like this:

```mbt check
///|
pub(all) struct User {
  name : String
  age : Int
  /// An `Option` field: absent and explicitly null both read back as `None`.
  nickname : String?
} derive(Eq, Debug)

///|
pub impl @data.Serialize for User with fn serialize(self, s) {
  s.serialize_struct_begin("User", 3)
  s.serialize_field("name", self.name)
  s.serialize_field("age", self.age)
  s.serialize_field("nickname", self.nickname)
  s.serialize_struct_end()
}

///|
let user_fields : ReadOnlyArray[String] = ["name", "age", "nickname"]

///|
pub impl @data.Deserialize for User with fn deserialize(d) {
  d.deserialize_struct_begin("User", user_fields)
  let mut name = None
  let mut age = None
  let mut nickname = None
  while d.deserialize_field_name() is Some(field) {
    match field {
      "name" => name = Some(d.deserialize_field_value())
      "age" => age = Some(d.deserialize_field_value())
      "nickname" => nickname = d.deserialize_field_value()
      // Unknown fields are skipped rather than rejected.
      _ => d.skip_value()
    }
  }
  {
    name: @data.required(name, name="name", path=d.path()),
    age: @data.required(age, name="age", path=d.path()),
    nickname,
  }
}
```

Note that no field type is ever named: type inference flows backward from the
struct literal, so the accumulators need no annotations. The format sees the
ordinary immutable field-name array. Derived code additionally generates a
private field enum implementing `FieldIdentifier`; byte-oriented formats can
then map raw UTF-8 directly to semantic cases without exposing numeric indices
or a lookup-table representation in the public API.

That one pair of implementations now drives every format:

```mbt check
///|
test "one implementation, every format" {
  let user = User::{ name: "ada", age: 36, nickname: None }

  // JSON, as UTF-8 bytes.
  inspect(
    @json.to_string(user),
    content="{\"name\":\"ada\",\"age\":36,\"nickname\":null}",
  )
  assert_eq((@json.from_string(@json.to_string(user)) : User), user)

  // The same value in memory, with no encoding step.
  inspect(
    @data.to_value(user),
    content="{\"name\": \"ada\", \"age\": 36, \"nickname\": null}",
  )
  assert_eq((@data.from_value(@data.to_value(user)) : User), user)
}
```

## Enums

Enums use serde's default external tagging: a variant with no payload is a
bare string, and anything else is a one-entry object.

```mbt check
///|
pub(all) enum Role {
  Guest
  Member(String)
  Admin(level~ : Int, since~ : String)
} derive(Eq, Debug)

///|
pub impl @data.Serialize for Role with fn serialize(self, s) {
  let name = "Role"
  match self {
    Guest =>
      s.serialize_unit_variant({ enum_name: name, index: 0, name: "Guest" })
    Member(team) =>
      s.serialize_newtype_variant(
        { enum_name: name, index: 1, name: "Member" },
        team,
      )
    Admin(level~, since~) => {
      s.serialize_struct_variant_begin(
        { enum_name: name, index: 2, name: "Admin" },
        2,
      )
      s.serialize_struct_variant_field("level", level)
      s.serialize_struct_variant_field("since", since)
      s.serialize_struct_variant_end()
    }
  }
}

///|
test "enums are externally tagged" {
  inspect(@json.to_string(Guest), content="\"Guest\"")
  inspect(@json.to_string(Member("core")), content="{\"Member\":\"core\"}")
  inspect(
    @json.to_string(Admin(level=2, since="2019")),
    content="{\"Admin\":{\"level\":2,\"since\":\"2019\"}}",
  )
}
```

## Deriving instead

MoonBit has no user-defined `derive`, so implementations are generated by a
tool rather than by the compiler. Mark a type with an attribute — the compiler
ignores attributes it does not recognise:

```mbt nocheck
///|
#data.derive(Serialize, Deserialize)
pub(all) struct Config {
  #data.rename("max-retries")
  max_retries : Int
  #data.skip
  cache_generation : Int
}
```

Then run the generator, which writes a `*_derive.mbt` companion next to each
source file:

```bash
moonx Yu-zh/data/derive [path ...]
```

| Attribute | On | Effect |
|---|---|---|
| `#data.derive(Serialize, Deserialize)` | struct or enum | generates the named implementations |
| `#data.rename("name")` | field or variant | changes the name on the wire, not in MoonBit |
| `#data.skip` | field | never written; filled from `Default` when read |

Generic types get one trait bound per parameter, so `Pair[A, B]` derives as
`impl[A : Serialize, B : Serialize] Serialize for Pair[A, B]`.

A struct's declared shape picks its form in the data model, and the two
degenerate shapes are not spelled as the general one: `struct Rgb(Int, Int,
Int)` is a tuple struct, but `struct Meters(Double)` is a *newtype* struct,
written as the value it wraps rather than as a sequence of one, and
`struct Marker {}` is a unit struct, written as unit. Formats that draw no
distinction still receive what the general form would have written, since the
`Serializer` defaults widen back to it.

There is no build-system hook — the current `moon.pkg` format has no pre-build
step — so generated files are committed alongside their sources and the
generator is re-run by hand. It is idempotent, and CI can check nothing is
stale with `moon run derive && git diff --exit-code`.

A trait impl also installs its methods as regular methods on the type, so a
derived `Serialize` would otherwise add `value.serialize(s)` to your package's
public interface — an API you did not ask for, in a file you did not write.
Each impl comes with an `extend` declaration that names the promotion,
deprecates it and hides it, so deriving neither widens your interface nor
leaves warning 79 (`implicit_impl_as_method`) behind. Reach these through the
`Serialize` and `Deserialize` bounds, as generated code itself does.

See the [`example`](example/) package for the whole loop: attributed types,
their generated implementations, and round-trip tests.

## Errors carry a path

Every failure records *where* in the document it happened, so a bad field in a
large payload does not turn into a shrug:

```mbt check
///|
test "errors say where" {
  let bad = "[{\"name\":\"ada\",\"age\":\"thirty-six\"}]"
  try (@json.from_string(bad) : Array[User]) catch {
    e =>
      inspect(
        e,
        content="$[0].age: invalid type: expected a number, found string",
      )
  } noraise {
    _ => fail("expected a type error")
  }
}
```

`DeError` distinguishes the cases serde does — `InvalidType`, `InvalidValue`,
`InvalidLength`, `MissingField`, `UnknownField`, `UnknownVariant`, `Eof` and
`DeCustom` — so a format never has to invent message strings.

## Untyped documents

`Value` is the data model made concrete. It is what `deserialize_any` returns,
and it round-trips like any other type:

```mbt check
///|
test "Value carries any document" {
  let text = "{\"tags\":[1,-2.5,true,null],\"name\":\"ada\",\"meta\":{}}"
  let value : @data.Value = @json.from_string(text)
  guard value.get("tags") is Some(tags) else { fail("expected a tags field") }
  inspect(tags, content="[1, -2.5, true, null]")
  inspect(@json.to_string(value), content=text)
  // Strings inside are UTF-8 bytes; `text()` is the explicit step to a String.
  guard value.get("name") is Some(name) else { fail("expected a name field") }
  guard name.text() is Some(who) else { fail("expected valid UTF-8") }
  inspect(who, content="ada")
}
```

## JSON specifics

The transport is UTF-8 `Bytes`. `to_string` / `from_string` are conveniences
over `to_bytes` / `from_bytes`, the same split `serde_json` makes between
`to_vec` / `from_slice` and `to_string` / `from_str`.

```mbt check
///|
test "the transport is bytes" {
  assert_eq(@json.to_bytes("é"), b"\x22\xc3\xa9\x22")
  assert_eq((@json.from_bytes(b"[1,2]") : Array[Int]), [1, 2])
}
```

Where JSON is narrower than the data model it follows `serde_json`: byte
strings become arrays of numbers, `Char` becomes a one-character string, tuples
become arrays, and unit becomes `null`. It departs on two points, deliberately:

- **NaN and infinity raise** `UnsupportedType` instead of silently becoming
  `null`, because losing them quietly is worse than failing.
- **A non-string, non-numeric map key raises** instead of being coerced.

## CBOR specifics

CBOR ([RFC 8949](https://www.rfc-editor.org/rfc/rfc8949)) fits the data model
more closely than JSON does, because three things JSON has to fake are native
to it:

```mbt check
///|
test "what CBOR carries that JSON cannot" {
  // A byte string stays bytes, rather than becoming an array of numbers.
  assert_eq(@cbor.to_bytes(b"\x01\x02"), b"\x42\x01\x02")
  // A map key need not be a string.
  let keyed : Map[Int, String] = { 1: "a" }
  assert_eq((@cbor.from_bytes(@cbor.to_bytes(keyed)) : Map[Int, String]), keyed)
  // Unsigned and negative integers are distinct major types, so a double is
  // never mistaken for an integer that happened to be whole.
  assert_eq(@cbor.to_bytes(1.5), b"\xfb\x3f\xf8\x00\x00\x00\x00\x00\x00")
}
```

Everything else follows `serde_cbor`: unit is `null`, `Char` is a
one-character text string, tuples are arrays, newtype structs are transparent,
structs are maps with text keys, and enums are externally tagged.

Writing uses definite lengths wherever a length is known and the shortest head
that fits each integer. That is deterministic for a given value but not
canonical CBOR — map keys go out in declaration order rather than sorted.

Reading deliberately accepts more than writing produces, since a decoder that
only understood its own output would be useless for interoperating:
indefinite-length containers and strings, half-precision floats, and semantic
tags. **Tags are read and discarded**, so a tagged value decodes as its
content; `Value` has no case for a tag, and refusing them outright would reject
ordinary documents from encoders that mark their timestamps.

## MessagePack specifics

MessagePack is CBOR's closest sibling — self-describing, binary, big-endian,
with byte strings and non-string map keys native — and follows `rmp-serde` on
everything the data model does not pin down. Two differences from CBOR matter:

**Every length is explicit.** There is no indefinite-length container, so
`serialize_seq_begin(None)` cannot be honoured and raises `UnsupportedType`.
Nothing in this library passes `None`, so it is unreachable in practice, but it
is the clearest illustration of why the hint is an `Int?`: JSON never knows a
length up front, MessagePack can never do without one, and CBOR can spell
either.

**Extension types are refused, not skipped.** A CBOR tag wraps a value that
decodes on its own, so dropping the tag leaves something meaningful. A
MessagePack ext is a type byte and an opaque payload with no inner value to
fall back to, and `Value` has no case for one.

```mbt check
///|
test "every value takes its narrowest form" {
  assert_eq(@msgpack.to_bytes(127), b"\x7f")
  assert_eq(@msgpack.to_bytes(128), b"\xcc\x80")
  assert_eq(@msgpack.to_bytes(-32), b"\xe0")
  assert_eq(@msgpack.to_bytes(b"\x01\x02"), b"\xc4\x02\x01\x02")
}
```

## TOML specifics

The transport is UTF-8 `Bytes`, as it is for JSON — that is what a TOML file is
on disk — with `to_string` / `from_string` as thin conveniences over it.

TOML is the one format here that cannot stream. Within a table every scalar
key must appear before the first sub-table header, so field order is not
emission order: a struct `{ a, sub, b }` has to emit `a`, `b`, then `[sub]`.
And `serialize_field` hands over a value whose only capability is `Serialize`,
so the serializer cannot tell a scalar from a table without writing it —
classification has to wait until the whole table is in hand.

That does not put the traits out of reach, because they never required emitting
as you go: `ValueSerializer` accumulates into a tree and is a first-class
`Serializer` for doing so. `TomlSerializer` and `TomlDeserializer` are backed by
it, matching `toml::ser::Serializer` and `toml::de::Deserializer` in Rust.
Reading is the easier direction — a pull protocol lets a format parse before
the first question, which it must, since a TOML sub-table may be defined before
its parent.

```mbt check
///|
test "scalars come out before sub-tables" {
  let doc : Map[String, @data.Value] = {
    "name": Str(b"prod"),
    "server": Map([(Str(b"port"), Int(8080L))]),
  }
  inspect(
    @toml.to_string(doc),
    content=(
      #|name = "prod"
      #|
      #|[server]
      #|port = 8080
      #|
    ),
  )
}
```

What TOML cannot represent, and what happens: a `None` field is omitted (TOML
has no null); byte strings, non-string keys and a non-table root all raise
`UnsupportedType`. Reading back, datetimes are refused rather than coerced into
strings, since a string that used to be a datetime no longer is one.

Infinity and NaN survive, unusually — TOML spells them `inf`, `-inf` and `nan`,
so this is the one place a format here is wider than JSON.

## Choosing a format

| | self-describing | streaming | bytes as bytes | non-string keys | null |
|---|---|---|---|---|---|
| JSON | yes | yes | no, an array of numbers | no | yes |
| CBOR | yes | yes | yes | yes | yes |
| MessagePack | yes | yes | yes | yes | yes |
| TOML | yes | no, buffers | no | no | no |

JSON when a human has to read it. CBOR when a standard matters, since it is an
IETF RFC. MessagePack when talking to something that already speaks it. TOML
for configuration, where the shape is a table and a person edits the file.

## How this differs from Rust's serde

Two deviations, both forced by MoonBit having no associated types.

**Compound protocols are flattened.** Serde returns a distinct builder type
from `serialize_seq` and friends, which makes it a type error to mix up two
open compounds. Without associated types the sub-serializer cannot be named,
so sequences, maps, structs and tuple variants are written as
`_begin` / element / `_end` triples on the serializer itself. Correct nesting
becomes a contract rather than a type guarantee — every misuse raises a named
error rather than silently producing wrong output.

**`Error` is concrete.** Serde's `Error` associated type becomes the concrete
`SerError` and `DeError`, each carrying a `Path`.

There is no general value `Visitor`. MoonBit trait methods may carry their own
type parameters, so `deserialize_seq_next` is generic in the element type and
calls `T::deserialize` directly — which is the job Serde's `Visitor` and
`DeserializeSeed` do in Rust. Struct fields are the narrow special case:
`deserialize_field` is generic in `FieldIdentifier`, and derive generates a
private semantic enum for that identifier, analogous to Serde's private field
enum. A format may feed it an index, raw UTF-8, or an existing `String`.

## License

Apache-2.0

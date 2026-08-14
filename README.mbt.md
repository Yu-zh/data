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
pub impl @data.Deserialize for User with fn deserialize(d) {
  d.deserialize_struct_begin("User", ["name", "age", "nickname"])
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
    name: @data.required(name, "name", d.path()),
    age: @data.required(age, "age", d.path()),
    nickname,
  }
}
```

Note that no field type is ever named: type inference flows backward from the
struct literal, so the accumulators need no annotations.

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

There is no build-system hook — the current `moon.pkg` format has no pre-build
step — so generated files are committed alongside their sources and the
generator is re-run by hand. It is idempotent, and CI can check nothing is
stale with `moon run derive && git diff --exit-code`.

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
  let text = "{\"tags\":[1,-2.5,true,null],\"meta\":{}}"
  let value : @data.Value = @json.from_string(text)
  guard value.get("tags") is Some(tags) else { fail("expected a tags field") }
  inspect(tags, content="[1, -2.5, true, null]")
  inspect(@json.to_string(value), content=text)
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

And one thing serde needs that this does not: **there is no `Visitor`.**
MoonBit trait methods may carry their own type parameters, so
`deserialize_seq_next` is generic in the element type and calls
`T::deserialize` directly — which is the job `Visitor` and `DeserializeSeed`
exist to do in Rust.

## License

Apache-2.0

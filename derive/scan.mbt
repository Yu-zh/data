// Turning parsed MoonBit source into `Target`s.
//
// Only attributes qualified with `data.` are considered. The compiler ignores
// unknown namespaced attributes, so an unqualified `#derive(...)` or another
// tool's `#gobject.subclass` passes straight through untouched.

///|
const NAMESPACE : String = "data"

///|
/// Splits a `data.`-qualified attribute into its name and arguments.
///
/// `#data.skip` is `("skip", [])` and `#data.rename("why")` is
/// `("rename", [String("why")])`. Anything in another namespace is `None`.
fn attribute_call(
  attr : @attribute.Attribute,
) -> (String, Array[@attribute.Expr])? {
  match attr.parsed {
    Some(Apply(id, props)) =>
      if id.qual == Some(NAMESPACE) {
        let args = []
        for prop in props {
          match prop {
            Expr(e) => args.push(e)
            Labeled(_, e) => args.push(e)
          }
        }
        Some((id.name, args))
      } else {
        None
      }
    Some(Ident(id)) =>
      if id.qual == Some(NAMESPACE) {
        Some((id.name, []))
      } else {
        None
      }
    _ => None
  }
}

///|
/// Whether an attribute is in our namespace at all, judged from the raw text.
///
/// `attribute_call` only recognises the forms this tool understands, so
/// something like `#data.skip(1)` — whose argument the attribute grammar has
/// no representation for — would otherwise parse to nothing and be silently
/// ignored. Anything spelled `#data.*` has to be accounted for.
fn is_ours(attr : @attribute.Attribute) -> Bool {
  attr.raw.has_prefix("#" + NAMESPACE + ".")
}

///|
fn[T] unparseable(
  attr : @attribute.Attribute,
  where_ : String,
) -> T raise DeriveError {
  raise DeriveError(
    where_~,
    message="cannot make sense of attribute `\{attr.raw}`",
  )
}

///|
fn expr_ident(expr : @attribute.Expr) -> String? {
  match expr {
    Ident(id) => Some(id.name)
    _ => None
  }
}

///|
fn expr_string(expr : @attribute.Expr) -> String? {
  match expr {
    String(text) => Some(text)
    _ => None
  }
}

///|
/// Reads `#data.rename("...")` and `#data.skip` off a field or variant.
fn read_member_attributes(
  attrs : @list.List[@attribute.Attribute],
  where_ : String,
  ident : String,
) -> (String, Bool) raise DeriveError {
  let mut name = ident
  let mut skip = false
  for attr in attrs {
    guard attribute_call(attr) is Some((call, args)) else {
      if is_ours(attr) {
        unparseable(attr, where_)
      }
      continue
    }
    match call {
      "rename" => {
        guard args.length() == 1 && expr_string(args[0]) is Some(text) else {
          raise DeriveError(
            where_~,
            message="#data.rename on `\{ident}` takes exactly one string",
          )
        }
        name = text
      }
      "skip" => {
        guard args.is_empty() else {
          raise DeriveError(
            where_~,
            message="#data.skip on `\{ident}` takes no arguments",
          )
        }
        skip = true
      }
      other =>
        raise DeriveError(
          where_~,
          message="unknown attribute `#data.\{other}` on `\{ident}`",
        )
    }
  }
  (name, skip)
}

///|
fn scan_fields(
  fields : @list.List[@syntax.FieldDecl],
  where_ : String,
) -> Array[Field] raise DeriveError {
  let out = []
  for field in fields {
    let ident = field.name.label
    let (name, skip) = read_member_attributes(field.attrs, where_, ident)
    out.push({ ident, name, optional: field.ty is Option(..), skip })
  }
  out
}

///|
fn scan_case(
  constr : @syntax.ConstrDecl,
  where_ : String,
) -> Case raise DeriveError {
  let ident = constr.name.name
  let (name, skip) = read_member_attributes(constr.attrs, where_, ident)
  guard !skip else {
    raise DeriveError(
      where_~,
      message="#data.skip is not supported on enum variants (`\{ident}`)",
    )
  }
  let args = match constr.args {
    None => []
    Some(list) => list.to_array()
  }
  if args.is_empty() {
    return { ident, name, payload: Unit }
  }
  let labelled = args.filter(arg => arg.label is Some(_)).length()
  if labelled == 0 {
    let payload = if args.length() == 1 {
      Newtype
    } else {
      Tuple(args.length())
    }
    return { ident, name, payload }
  }
  guard labelled == args.length() else {
    raise DeriveError(
      where_~,
      message="variant `\{ident}` mixes labelled and positional payloads, which has no data model equivalent",
    )
  }
  let fields = []
  for arg in args {
    guard arg.label is Some(label) else { continue }
    fields.push({
      ident: label.name,
      name: label.name,
      optional: false,
      skip: false,
    })
  }
  { ident, name, payload: Struct(fields) }
}

///|
/// Extracts every `#data.derive(...)` target from one parsed file.
///
/// `where_` is used verbatim as the location prefix of any `DeriveError`.
pub fn scan(
  impls : @list.List[@syntax.Impl],
  where_ : String,
) -> Array[Target] raise DeriveError {
  let targets = []
  for impl_ in impls {
    guard impl_ is TopTypeDef(decl) else { continue }
    let mut serialize = false
    let mut deserialize = false
    let mut marked = false
    for attr in decl.attrs {
      guard attribute_call(attr) is Some((call, args)) else {
        if is_ours(attr) {
          unparseable(attr, where_)
        }
        continue
      }
      guard call == "derive" else {
        raise DeriveError(
          where_~,
          message="unknown attribute `#data.\{call}` on type `\{decl.tycon}`",
        )
      }
      marked = true
      guard !args.is_empty() else {
        raise DeriveError(
          where_~,
          message="#data.derive on `\{decl.tycon}` names no traits",
        )
      }
      for arg in args {
        match expr_ident(arg) {
          Some("Serialize") => serialize = true
          Some("Deserialize") => deserialize = true
          Some(other) =>
            raise DeriveError(
              where_~,
              message="cannot derive `\{other}` for `\{decl.tycon}`; expected Serialize or Deserialize",
            )
          None =>
            raise DeriveError(
              where_~,
              message="#data.derive on `\{decl.tycon}` takes trait names, not literals",
            )
        }
      }
    }
    guard marked else { continue }
    let site = "\{where_}: type `\{decl.tycon}`"
    let shape = match decl.components {
      Record(fields~) => Record(scan_fields(fields, site))
      TupleStruct(types) => TupleStruct(types.length())
      Variant(constrs) => {
        let cases = []
        for constr in constrs {
          cases.push(scan_case(constr, site))
        }
        Variant(cases)
      }
      _ =>
        raise DeriveError(
          where_~,
          message="`\{decl.tycon}` is not a struct or enum, so there is nothing to derive",
        )
    }
    let params = []
    for binder in decl.params {
      match binder.name {
        Some(name) => params.push(name)
        None =>
          raise DeriveError(
            where_~,
            message="`\{decl.tycon}` has an unnamed type parameter",
          )
      }
    }
    targets.push({
      name: decl.tycon,
      params,
      public: decl.type_vis is Pub(..),
      shape,
      serialize,
      deserialize,
    })
  }
  targets
}

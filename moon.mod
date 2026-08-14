// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Yu-zh/data"

version = "0.2.0"

readme = "README.mbt.md"

repository = "https://github.com/Yu-zh/data"

license = "Apache-2.0"

keywords = [ "serde", "serialization", "json", "derive" ]

preferred_target = "wasm"

description = "A serde-shaped serialization framework: one data model, many formats"

import {
  "moonbitlang/parser@0.3.14",
  "moonbitlang/async@0.20.5",
}

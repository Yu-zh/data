// The generator's command line.
//
//   moonx Yu-zh/data/derive [path ...]
//
// Each path is a file or a directory to walk. For every source file holding at
// least one `#data.derive(...)` type, a sibling `*_derive*.mbt` is written; if
// a file stops having any, its stale companion is removed.
//
// There is no way to hook this into `moon build` — the current `moon.pkg`
// format has no pre-build step — so generated files are committed alongside
// the sources they came from and the generator is re-run by hand.

///|
const USAGE : String =
  #|Generate Serialize / Deserialize implementations for types marked
  #|`#data.derive(...)`.
  #|
  #|    moonx Yu-zh/data/derive [path ...]
  #|
  #|Paths may be files or directories; directories are walked recursively.
  #|Defaults to the current directory.
  #|
  #|Attributes:
  #|    #data.derive(Serialize, Deserialize)   on a struct or enum
  #|    #data.rename("name")                   on a field or variant
  #|    #data.skip                             on a field

///|
/// Directories that never contain hand-written sources.
fn skip_dir(name : String) -> Bool {
  name
  is ("target"
  | "_build"
  | ".mooncakes"
  | ".git"
  | ".moonagent"
  | ".github"
  | ".githooks")
}

///|
/// Generated files are recognised by name so a re-run never reads its own
/// output back in.
fn is_generated(name : String) -> Bool {
  name.has_suffix("_derive.mbt") ||
  name.has_suffix("_derive_test.mbt") ||
  name.has_suffix("_derive_wbtest.mbt")
}

///|
/// Where a source file's generated companion goes.
///
/// The test suffix has to survive: `moon` decides which package a file belongs
/// to from its name, so `foo_test.mbt` must generate `foo_derive_test.mbt` and
/// not `foo_test_derive.mbt`, which would land in the wrong package.
fn output_path(path : String) -> String {
  for suffix in ["_wbtest.mbt", "_test.mbt"] {
    if path.has_suffix(suffix) {
      let stem = path[:path.length() - suffix.length()].to_owned()
      return stem + "_derive" + suffix
    }
  }
  path[:path.length() - ".mbt".length()].to_owned() + "_derive.mbt"
}

///|
fn collect(root : String, out : Array[String]) -> Unit raise @fs.IOError {
  if @fs.is_dir(root) {
    let entries = @fs.read_dir(root)
    entries.sort()
    for entry in entries {
      if !skip_dir(entry) {
        collect(if root == "." { entry } else { root + "/" + entry }, out)
      }
    }
  } else if root.has_suffix(".mbt") && !is_generated(root) {
    out.push(root)
  }
}

///|
/// A layout-insensitive fingerprint of generated source.
///
/// The two formatters in play disagree: `moon fmt` breaks long calls where the
/// one available inside this program does not, and adds a trailing comma when
/// it wraps. Comparing raw text would make the generator and `moon fmt`
/// rewrite each other forever, dirtying the tree on every run. Dropping
/// whitespace and commas — the only things they disagree about — leaves a
/// fingerprint that changes when the code does and not before.
fn fingerprint(source : String) -> String {
  let out = StringBuilder::new()
  for c in source {
    let noise = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ','
    if !noise {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Generates for one file. Returns a one-line report, or `None` if nothing
/// changed.
fn process(path : String) -> String? raise {
  let source = @fs.read_file_to_string(path)
  let (impls, reports) = @parser.parse_string(source, name=path)
  if reports.length() > 0 {
    // A file that does not parse is the compiler's problem to report, not
    // ours; skipping keeps the generator quiet during an edit-compile loop.
    return None
  }
  let targets = scan(impls, path)
  let target_path = output_path(path)
  match emit(targets) {
    Some(code) => {
      let formatted = @fmt.format(code)
      let existing = if @fs.path_exists(target_path) {
        @fs.read_file_to_string(target_path) catch {
          _ => ""
        }
      } else {
        ""
      }
      if fingerprint(existing) == fingerprint(formatted) {
        return None
      }
      @fs.write_string_to_file(target_path, formatted)
      Some("wrote    \{target_path}")
    }
    None =>
      if @fs.path_exists(target_path) {
        @fs.remove_file(target_path)
        Some("removed  \{target_path}")
      } else {
        None
      }
  }
}

///|
fn main {
  let argv = @env.args()
  let roots = []
  for i in 1..<argv.length() {
    let arg = argv[i]
    if arg is ("-h" | "--help") {
      println(USAGE)
      return
    }
    roots.push(arg)
  }
  if roots.is_empty() {
    roots.push(".")
  }
  let sources = []
  for root in roots {
    collect(root, sources) catch {
      IOError(reason) => {
        println("derive: cannot read `\{root}`: \{reason}")
        return
      }
    }
  }
  let mut changed = 0
  let mut failed = 0
  for path in sources {
    try {
      if process(path) is Some(report) {
        println(report)
        changed = changed + 1
      }
    } catch {
      err => {
        println("derive: \{err}")
        failed = failed + 1
      }
    }
  }
  if failed > 0 {
    println("derive: \{failed} file(s) failed, \{changed} updated")
  } else if changed == 0 {
    println(
      "derive: \{sources.length()} file(s) scanned, everything up to date",
    )
  } else {
    println("derive: \{sources.length()} file(s) scanned, \{changed} updated")
  }
}

// Benchmarks, and the corpus they run on.
//
// The corpus is generated rather than committed: four shapes, built in memory
// from a seeded generator, so the numbers are reproducible by anyone running
// `moon bench` without a multi-megabyte fixture in the repository.
//
// The shapes exist because JSON performance is not one number. Each isolates a
// different part of the parser, and a change that helps one routinely does
// nothing for another — every measurement in this package's history has split
// along these lines.

///|
/// xorshift64*, so a corpus is reproducible without depending on an RNG.
struct Seed {
  mut state : UInt64
}

///|
fn Seed::next(self : Seed) -> UInt64 {
  let mut x = self.state
  x = x ^ (x >> 12)
  x = x ^ (x << 25)
  x = x ^ (x >> 27)
  self.state = x
  x * 0x2545F4914F6CDD1DUL
}

///|
fn Seed::below(self : Seed, bound : Int) -> Int {
  (self.next() % bound.to_uint64()).to_int()
}

///|
const LETTERS : String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

///|
fn Seed::word(self : Seed, len : Int) -> String {
  let out = StringBuilder::new()
  for _ in 0..<len {
    out.write_char(LETTERS.unsafe_get(self.below(52)).to_char().unwrap())
  }
  out.to_string()
}

///|
/// Coordinate pairs with 17-significant-digit doubles: the shape of the
/// `json-serde` benchmark's canada.json, and the hard case for float parsing.
/// Roughly 90% numeric characters.
fn corpus_numbers(pairs : Int) -> Bytes {
  let seed = Seed::{ state: 0x9E3779B97F4A7C15UL }
  let out = StringBuilder::new()
  out.write_string("{\"type\":\"numbers\",\"coordinates\":[")
  for i in 0..<pairs {
    if i > 0 {
      out.write_string(",")
    }
    let lon = -180.0 + seed.below(360000000).to_double() / 1000000.0
    let lat = -90.0 + seed.below(180000000).to_double() / 1000000.0
    out.write_string("[\{lon},\{lat}]")
  }
  out.write_string("]}")
  @utf8.encode(out.to_string())
}

///|
/// Many small objects with short ASCII keys: the shape where identifier
/// handling dominates and string values barely register.
fn corpus_keys(rows : Int) -> Bytes {
  let seed = Seed::{ state: 0x123456789ABCDEFUL }
  let out = StringBuilder::new()
  out.write_string("{\"type\":\"keys\",\"rows\":[")
  for i in 0..<rows {
    if i > 0 {
      out.write_string(",")
    }
    out.write_string(
      "{\"id\":\{seed.below(1000000)},\"kind\":\{seed.below(64)},\"count\":\{seed.below(4096)},\"flag\":\{seed.below(2) == 0}}",
    )
  }
  out.write_string("]}")
  @utf8.encode(out.to_string())
}

///|
/// Long string values: the shape that decides whether a vectorised scan pays,
/// since the measured crossover for SIMD is around sixteen bytes and object
/// keys sit well below it.
fn corpus_text(rows : Int, len : Int) -> Bytes {
  let seed = Seed::{ state: 0xFEEDFACECAFEBEEFUL }
  let out = StringBuilder::new()
  out.write_string("{\"type\":\"text\",\"rows\":[")
  for i in 0..<rows {
    if i > 0 {
      out.write_string(",")
    }
    out.write_string(
      "{\"title\":\"\{seed.word(len)}\",\"body\":\"\{seed.word(len * 4)}\"}",
    )
  }
  out.write_string("]}")
  @utf8.encode(out.to_string())
}

///|
/// Strings needing frequent escapes: the path that can take no fast route, so
/// it catches a change that speeds up the common case by slowing this one.
fn corpus_escapes(rows : Int) -> Bytes {
  let seed = Seed::{ state: 0x0BADC0DEDEADBEEFUL }
  let out = StringBuilder::new()
  out.write_string("{\"type\":\"escapes\",\"rows\":[")
  for i in 0..<rows {
    if i > 0 {
      out.write_string(",")
    }
    let text = StringBuilder::new()
    for _ in 0..<8 {
      text.write_string(seed.word(4))
      text.write_string(
        ["\\n", "\\t", "\\\"", "\\\\", "\\u0001"][seed.below(5)],
      )
    }
    out.write_string("{\"v\":\"\{text.to_string()}\"}")
  }
  out.write_string("]}")
  @utf8.encode(out.to_string())
}

///|
/// The corpora are valid by construction, and the parity test below proves it,
/// so a benchmark body may treat failure as unreachable rather than propagate
/// an error the timing loop cannot accept.
fn parse(doc : Bytes) -> @data.Value {
  @json.from_bytes(doc) catch {
    _ => @data.Null
  }
}

///|
fn write(value : @data.Value) -> Bytes {
  @json.to_bytes(value) catch {
    _ => b""
  }
}

///|
fn parse_core(doc : Bytes) -> Json {
  @corejson.parse(@utf8.decode_lossy(doc)) catch {
    _ => Json::null()
  }
}

///|
/// Every corpus, at a size where a benchmark run stays quick.
fn corpora() -> Array[(String, Bytes)] {
  [
    ("numbers", corpus_numbers(4000)),
    ("keys", corpus_keys(4000)),
    ("text", corpus_text(2000, 24)),
    ("escapes", corpus_escapes(2000)),
  ]
}

///|
/// The corpus is only worth measuring on if it is being parsed correctly, so
/// parity with core's parser is asserted where the numbers are produced rather
/// than somewhere else in the suite.
test "every corpus round-trips identically to core" {
  for entry in corpora() {
    let (name, doc) = entry
    let ours : @data.Value = @json.from_bytes(doc)
    let theirs = @corejson.parse(@utf8.decode_lossy(doc))
    let ours_text = @json.to_string(ours)
    let theirs_text = theirs.stringify()
    assert_eq(
      ours_text,
      theirs_text,
      msg="corpus `\{name}` disagrees with core",
    )
    // And the document survives a round-trip through our own writer.
    assert_eq((@json.from_bytes(@json.to_bytes(ours)) : @data.Value), ours)
  }
}

///|
test "bench parse numbers" (it : @bench.T) {
  let doc = corpus_numbers(4000)
  it.bench(() => it.keep(parse(doc)))
}

///|
test "bench parse keys" (it : @bench.T) {
  let doc = corpus_keys(4000)
  it.bench(() => it.keep(parse(doc)))
}

///|
test "bench parse text" (it : @bench.T) {
  let doc = corpus_text(2000, 24)
  it.bench(() => it.keep(parse(doc)))
}

///|
test "bench parse escapes" (it : @bench.T) {
  let doc = corpus_escapes(2000)
  it.bench(() => it.keep(parse(doc)))
}

///|
test "bench write numbers" (it : @bench.T) {
  let value = parse(corpus_numbers(4000))
  it.bench(() => it.keep(write(value)))
}

///|
test "bench write text" (it : @bench.T) {
  let value = parse(corpus_text(2000, 24))
  it.bench(() => it.keep(write(value)))
}

// The core comparisons below are the yardstick. They parse the same bytes
// through `moonbitlang/core/json`, which must transcode to a `String` first
// because its parser takes one — that cost is charged here deliberately, since
// a file or a socket hands you bytes.

///|
test "bench parse numbers (core)" (it : @bench.T) {
  let doc = corpus_numbers(4000)
  it.bench(() => it.keep(parse_core(doc)))
}

///|
test "bench parse keys (core)" (it : @bench.T) {
  let doc = corpus_keys(4000)
  it.bench(() => it.keep(parse_core(doc)))
}

///|
test "bench parse text (core)" (it : @bench.T) {
  let doc = corpus_text(2000, 24)
  it.bench(() => it.keep(parse_core(doc)))
}

///|
test "bench parse escapes (core)" (it : @bench.T) {
  let doc = corpus_escapes(2000)
  it.bench(() => it.keep(parse_core(doc)))
}

// Core given a `String` it already holds, so the whole-document decode charged
// to it above is removed. This is the friendlier comparison for core, and the
// gap between each pair says how much of core's time that decode was.

///|
test "bench parse numbers (core, pre-decoded)" (it : @bench.T) {
  let text = @utf8.decode_lossy(corpus_numbers(4000))
  it.bench(() => it.keep(@corejson.parse(text) catch { _ => Json::null() }))
}

///|
test "bench parse keys (core, pre-decoded)" (it : @bench.T) {
  let text = @utf8.decode_lossy(corpus_keys(4000))
  it.bench(() => it.keep(@corejson.parse(text) catch { _ => Json::null() }))
}

///|
test "bench parse text (core, pre-decoded)" (it : @bench.T) {
  let text = @utf8.decode_lossy(corpus_text(2000, 24))
  it.bench(() => it.keep(@corejson.parse(text) catch { _ => Json::null() }))
}

///|
test "bench parse escapes (core, pre-decoded)" (it : @bench.T) {
  let text = @utf8.decode_lossy(corpus_escapes(2000))
  it.bench(() => it.keep(@corejson.parse(text) catch { _ => Json::null() }))
}

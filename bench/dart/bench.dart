// struple reference benchmark (Dart).
//
// Mirrors bench/zig/bench.zig and bench/js/bench.ts: encode (build a framed
// stream from prepared in-memory records) and decode (walk the whole stream,
// descending and un-escaping every container body and touching every scalar)
// throughput for the seven shared workloads — four realistic streaming shapes
// (stock quotes, geospatial points, tweets, blockchain transactions) plus three
// structural micro-benchmarks (an integer stream, a string stream, a nested
// document).
//
// The native records are parsed from bench/data/<name>.json once (setup,
// untimed) with dart:convert — every data field is a typed string, so there is
// no big-int-in-JSON precision risk. The encoder then rebuilds the bytes with
// the same appendX sequence the Zig reference uses. Byte-identity is verified
// against bench/payloads.json (sha256, computed by a self-contained SHA-256 so
// the check is real and no pub dependency is added) before any throughput
// figure is reported.
//
// Methodology (per (payload, op)): 5 warm-up runs, auto-calibrate the iteration
// count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is reported. A
// global checksum sink consumes every result so the optimizer can't elide the
// work. Steady-state buffers retain capacity. Single-threaded.
//
// Zero dependencies beyond the Dart SDK (dart:io, dart:convert, dart:typed_data,
// dart:core BigInt). Timing uses Stopwatch.elapsedTicks (high-resolution).
//
// Run (paths are resolved relative to the repo root, so run from there):
//   ~/dart-sdk/bin/dart compile exe bench/dart/bench.dart -o bench/dart/bench
//   bench/dart/bench
// (A JIT run also works: ~/dart-sdk/bin/dart run bench/dart/bench.dart — but the
//  AOT exe is the representative number; see the header note in the report.)

import 'dart:convert' show jsonDecode, utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:struple/struple.dart';

// ---------------------------------------------------------------------------
// DCE sink — every measured op folds something into this so the optimizer must
// actually perform the work. A plain Dart int is 64-bit two's-complement and
// wraps on overflow, mirroring the Zig `g_sink: u64` wrap exactly (the absolute
// value is irrelevant; it just has to depend on the work).
// ---------------------------------------------------------------------------
int gSink = 0;

// ---------------------------------------------------------------------------
// Native record shapes (parsed once from the shared JSON data).
// ---------------------------------------------------------------------------

class Dec {
  final List<int> digits; // coefficient digits, MSD-first, each 0–9
  final int exp;
  const Dec(this.digits, this.exp);
}

class Quote {
  final List<int> symbol; // UTF-8 bytes
  final Dec bid;
  final Dec ask;
  final double last; // f64
  final BigInt volume;
  final int ts; // µs since epoch (fits signed 64-bit)
  const Quote(this.symbol, this.bid, this.ask, this.last, this.volume, this.ts);
}

class Geo {
  final double lat;
  final double lon;
  final double elevation;
  final List<int> name; // UTF-8 bytes
  final int ts;
  const Geo(this.lat, this.lon, this.elevation, this.name, this.ts);
}

class Tweet {
  final BigInt id; // u64 — can exceed 2^63, so BigInt (not native int)
  final List<int> user; // UTF-8 bytes
  final List<int> text; // UTF-8 bytes
  final int createdAt;
  final BigInt likes;
  final BigInt retweets;
  const Tweet(
      this.id, this.user, this.text, this.createdAt, this.likes, this.retweets);
}

class Tx {
  final BigInt height;
  final Uint8List txHash; // 32 bytes
  final Uint8List from; // 20 bytes
  final Uint8List to; // 20 bytes
  // wei value — both the i128 fixed path and the arbitrary-precision big-int
  // path reduce to a BigInt; appendBigIntValue routes by magnitude.
  final BigInt value;
  final BigInt gas;
  final BigInt nonce;
  final int ts;
  const Tx(this.height, this.txHash, this.from, this.to, this.value, this.gas,
      this.nonce, this.ts);
}

class Nested {
  final BigInt uid;
  final List<int> name; // UTF-8 bytes
  final bool active;
  final List<BigInt> scores; // length 3
  const Nested(this.uid, this.name, this.active, this.scores);
}

enum PKind { quotes, geo, tweets, txs, ints, strings, nested }

class PayloadMeta {
  final PKind kind;
  final String name;
  final String category;
  const PayloadMeta(this.kind, this.name, this.category);
}

const payloads = <PayloadMeta>[
  PayloadMeta(PKind.quotes, 'stock_quotes', 'streaming'),
  PayloadMeta(PKind.geo, 'geo_points', 'streaming'),
  PayloadMeta(PKind.tweets, 'tweets', 'streaming'),
  PayloadMeta(PKind.txs, 'blockchain_txs', 'streaming'),
  PayloadMeta(PKind.ints, 'int_stream', 'structural'),
  PayloadMeta(PKind.strings, 'string_stream', 'structural'),
  PayloadMeta(PKind.nested, 'nested_doc', 'structural'),
];

class Data {
  final List<Quote> quotes;
  final List<Geo> geo;
  final List<Tweet> tweets;
  final List<Tx> txs;
  final List<BigInt> ints;
  final List<List<int>> strings; // UTF-8 bytes per string
  final List<Nested> nested;
  const Data(this.quotes, this.geo, this.tweets, this.txs, this.ints,
      this.strings, this.nested);
}

// ---------------------------------------------------------------------------
// Parsing helpers — the shared data fields are all typed strings (so any JSON
// library reads them identically across languages). See bench/README.md.
// ---------------------------------------------------------------------------

final ByteData _f64Scratch = ByteData(8);

// 16 hex digits of the IEEE-754 bits (big-endian) → Dart double (ByteData).
double f64FromHex(String hex) {
  final bits = BigInt.parse(hex, radix: 16);
  // Split into two 32-bit halves (BigInt → int could be negative at the top
  // bit, but setUint32 masks to 32 bits, so this is exact).
  final hi = (bits >> 32).toInt() & 0xFFFFFFFF;
  final lo = (bits & BigInt.from(0xFFFFFFFF)).toInt();
  _f64Scratch.setUint32(0, hi, Endian.big);
  _f64Scratch.setUint32(4, lo, Endian.big);
  return _f64Scratch.getFloat64(0, Endian.big);
}

// digit string "12345" → [1,2,3,4,5]
List<int> digitsFromStr(String s) {
  final out = List<int>.filled(s.length, 0);
  for (var i = 0; i < s.length; i++) {
    out[i] = s.codeUnitAt(i) - 48;
  }
  return out;
}

// hex string (even length) → bytes
Uint8List bytesFromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// big-endian hex magnitude → BigInt (both the `big` and `fix` blockchain paths
// reduce to this: appendBigIntValue routes magnitudes within the i128 range
// through the fixed slots and magnitudes beyond it through the big-int codes,
// byte-for-byte identical to the Zig appendI128 / appendBigInt split).
BigInt bigFromHex(String hex) =>
    hex.isEmpty ? BigInt.zero : BigInt.parse(hex, radix: 16);

Data readData(String dataDir) {
  dynamic load(String name) =>
      jsonDecode(File('$dataDir/$name.json').readAsStringSync());

  final quotesRaw = (load('stock_quotes') as List).cast<List>();
  final quotes = <Quote>[];
  for (final r in quotesRaw) {
    quotes.add(Quote(
      utf8.encode(r[0] as String),
      Dec(digitsFromStr(r[1] as String), int.parse(r[2] as String)),
      Dec(digitsFromStr(r[3] as String), int.parse(r[4] as String)),
      f64FromHex(r[5] as String),
      BigInt.parse(r[6] as String),
      int.parse(r[7] as String),
    ));
  }

  final geoRaw = (load('geo_points') as List).cast<List>();
  final geo = <Geo>[];
  for (final r in geoRaw) {
    geo.add(Geo(
      f64FromHex(r[0] as String),
      f64FromHex(r[1] as String),
      f64FromHex(r[2] as String),
      utf8.encode(r[3] as String),
      int.parse(r[4] as String),
    ));
  }

  final tweetsRaw = (load('tweets') as List).cast<List>();
  final tweets = <Tweet>[];
  for (final r in tweetsRaw) {
    tweets.add(Tweet(
      BigInt.parse(r[0] as String),
      utf8.encode(r[1] as String),
      utf8.encode(r[2] as String),
      int.parse(r[3] as String),
      BigInt.parse(r[4] as String),
      BigInt.parse(r[5] as String),
    ));
  }

  final txsRaw = (load('blockchain_txs') as List).cast<List>();
  final txs = <Tx>[];
  for (final r in txsRaw) {
    // r[4] is "big" | "fix"; r[5] is the big-endian hex magnitude. Both collapse
    // to a BigInt for appendBigIntValue.
    txs.add(Tx(
      BigInt.parse(r[0] as String),
      bytesFromHex(r[1] as String),
      bytesFromHex(r[2] as String),
      bytesFromHex(r[3] as String),
      bigFromHex(r[5] as String),
      BigInt.parse(r[6] as String),
      BigInt.parse(r[7] as String),
      int.parse(r[8] as String),
    ));
  }

  final intsRaw = (load('int_stream') as List).cast<String>();
  final ints = intsRaw.map(BigInt.parse).toList();

  final strings = (load('string_stream') as List)
      .cast<String>()
      .map<List<int>>((s) => utf8.encode(s))
      .toList();

  final nestedRaw = (load('nested_doc') as List).cast<List>();
  final nested = <Nested>[];
  for (final r in nestedRaw) {
    nested.add(Nested(
      BigInt.parse(r[1] as String),
      utf8.encode(r[2] as String),
      (r[0] as String) == '1',
      [
        BigInt.parse(r[3] as String),
        BigInt.parse(r[4] as String),
        BigInt.parse(r[5] as String),
      ],
    ));
  }

  return Data(quotes, geo, tweets, txs, ints, strings, nested);
}

// ---------------------------------------------------------------------------
// Encoders — one per payload kind. `out` is reset by the caller each iteration;
// a single reused `scratch` Writer frames one record at a time (its backing
// builder is cleared, not reallocated, so it retains capacity at steady state).
// Mirrors encodeOnce in bench/zig/bench.zig.
// ---------------------------------------------------------------------------

// Pre-encoded constant keys for the nested-doc map (the keys never change; the
// Zig harness re-encodes them per record from an arena, but the keys are
// invariant, so caching them is byte-identical and avoids needless work — the
// same choice the JS port makes).
final Uint8List kKeyActive = _encStr('active');
final Uint8List kKeyScores = _encStr('scores');
final Uint8List kKeyUser = _encStr('user');
final Uint8List kKeyId = _encStr('id');
final Uint8List kKeyName = _encStr('name');

Uint8List _encStr(String s) {
  final w = Writer();
  w.appendString(utf8.encode(s));
  return w.bytes();
}

Uint8List _encStrBytes(List<int> b) {
  final w = Writer();
  w.appendString(b);
  return w.bytes();
}

Uint8List _encInt(BigInt v) {
  final w = Writer();
  w.appendBigIntValue(v);
  return w.bytes();
}

Uint8List _encBool(bool v) {
  final w = Writer();
  w.appendBool(v);
  return w.bytes();
}

void encodeOnce(PKind kind, Data d, Writer out, Writer scratch) {
  switch (kind) {
    case PKind.quotes:
      for (final q in d.quotes) {
        scratch.reset();
        scratch.appendString(q.symbol);
        scratch.appendDecimal(false, q.bid.digits, q.bid.exp);
        scratch.appendDecimal(false, q.ask.digits, q.ask.exp);
        scratch.appendF64(q.last);
        scratch.appendBigIntValue(q.volume);
        scratch.appendTimestamp(q.ts);
        out.appendArray(scratch.bytes());
      }
    case PKind.geo:
      for (final g in d.geo) {
        scratch.reset();
        scratch.appendF64(g.lat);
        scratch.appendF64(g.lon);
        scratch.appendF64(g.elevation);
        scratch.appendString(g.name);
        scratch.appendTimestamp(g.ts);
        out.appendArray(scratch.bytes());
      }
    case PKind.tweets:
      for (final t in d.tweets) {
        scratch.reset();
        scratch.appendBigIntValue(t.id); // u64 id (may exceed 2^63)
        scratch.appendString(t.user);
        scratch.appendString(t.text);
        scratch.appendTimestamp(t.createdAt);
        scratch.appendBigIntValue(t.likes);
        scratch.appendBigIntValue(t.retweets);
        out.appendArray(scratch.bytes());
      }
    case PKind.txs:
      for (final x in d.txs) {
        scratch.reset();
        scratch.appendBigIntValue(x.height);
        scratch.appendBytes(x.txHash);
        scratch.appendBytes(x.from);
        scratch.appendBytes(x.to);
        scratch.appendBigIntValue(x.value); // big-int or i128 fixed, by magnitude
        scratch.appendBigIntValue(x.gas);
        scratch.appendBigIntValue(x.nonce);
        scratch.appendTimestamp(x.ts);
        out.appendArray(scratch.bytes());
      }
    case PKind.ints:
      for (final v in d.ints) {
        out.appendBigIntValue(v);
      }
    case PKind.strings:
      for (final s in d.strings) {
        out.appendString(s);
      }
    case PKind.nested:
      for (final n in d.nested) {
        // user sub-map { id, name }
        final user = Writer();
        user.appendMap([
          [kKeyId, _encInt(n.uid)],
          [kKeyName, _encStrBytes(n.name)],
        ]);
        // scores array [s0, s1, s2]
        final scoresInner = Writer();
        scoresInner.appendBigIntValue(n.scores[0]);
        scoresInner.appendBigIntValue(n.scores[1]);
        scoresInner.appendBigIntValue(n.scores[2]);
        final scoresArr = Writer();
        scoresArr.appendArray(scoresInner.bytes());
        // top-level map (appendMap sorts by encoded key, so order here is free)
        out.appendMap([
          [kKeyActive, _encBool(n.active)],
          [kKeyScores, scoresArr.bytes()],
          [kKeyUser, user.bytes()],
        ]);
      }
  }
}

int recordCount(PKind kind, Data d) {
  switch (kind) {
    case PKind.quotes:
      return d.quotes.length;
    case PKind.geo:
      return d.geo.length;
    case PKind.tweets:
      return d.tweets.length;
    case PKind.txs:
      return d.txs.length;
    case PKind.ints:
      return d.ints.length;
    case PKind.strings:
      return d.strings.length;
    case PKind.nested:
      return d.nested.length;
  }
}

// ---------------------------------------------------------------------------
// Decode — recursive walk that touches every value, unescaping container bodies
// (the realistic cost of the memcmp-orderable framing). Reader.next() returns a
// *framed* body view for containers; we unescape it (single pass into a fresh
// buffer) and recurse — the realistic work, with no separate hasEscapes scan.
// ---------------------------------------------------------------------------

final ByteData _decScratch = ByteData(8);

void walk(Uint8List buf) {
  final r = Reader(buf);
  Element? el;
  while ((el = r.next()) != null) {
    switch (el!.kind) {
      case Kind.nil:
      case Kind.undefined:
        break;
      case Kind.boolean:
        gSink += el.boolValue ? 1 : 0;
      case Kind.int_:
      case Kind.bigInt:
        // Fold the low 64 bits of the exact integer value into the sink.
        gSink += el.intValue!.toUnsigned(64).toInt();
      case Kind.float32:
        _decScratch.setFloat32(0, el.doubleValue, Endian.big);
        gSink += _decScratch.getUint32(0, Endian.big);
      case Kind.float64:
        _decScratch.setFloat64(0, el.doubleValue, Endian.big);
        gSink += _decScratch.getUint32(0, Endian.big) +
            _decScratch.getUint32(4, Endian.big);
      case Kind.decimal:
        final dc = el.decimalValue!;
        gSink += dc.coeffStored.length + dc.adjExp;
      case Kind.timestamp:
        gSink += el.timestampValue;
      case Kind.uuid:
        gSink += el.uuidValue![0];
      case Kind.string:
      case Kind.bytes:
        // body is the *framed* payload; unescape to get the literal content,
        // then touch its length and first byte (the realistic per-scalar cost).
        final s = unescape(el.body!);
        gSink += s.length;
        if (s.isNotEmpty) gSink += s[0];
      case Kind.array:
      case Kind.map:
      case Kind.set:
        walk(unescape(el.body!));
    }
  }
}

// ---------------------------------------------------------------------------
// Timing.
// ---------------------------------------------------------------------------

class Stats {
  final double nsPerOp;
  final int bytes;
  final int records;
  const Stats(this.nsPerOp, this.bytes, this.records);

  double get mbPerSec => (bytes / nsPerOp) * 1000.0; // bytes/ns → MB/s
  double get mRecPerSec => (records / nsPerOp) * 1000.0; // rec/ns → Mrec/s
}

const int nTrials = 9;
const int nWarmup = 5;
const int targetTrialNs = 100 * 1000 * 1000; // ~100 ms

// Nanoseconds per Stopwatch tick (frequency is ticks/second).
final double _nsPerTick = 1e9 / Stopwatch().frequency;

double _median(List<double> values) {
  values.sort();
  return values[values.length ~/ 2];
}

Uint8List buildCanonical(PKind kind, Data d) {
  final out = Writer();
  final scratch = Writer();
  encodeOnce(kind, d, out, scratch);
  return out.bytes();
}

Stats benchEncode(PKind kind, Data d, int canonicalLen) {
  final out = Writer();
  final scratch = Writer();
  final sw = Stopwatch();

  void runOnce() {
    out.reset();
    encodeOnce(kind, d, out, scratch);
    gSink += out.bytes().length;
  }

  for (var i = 0; i < nWarmup; i++) {
    runOnce();
  }

  sw.start();
  runOnce();
  sw.stop();
  final one = sw.elapsedTicks <= 0 ? 1 : sw.elapsedTicks;
  final oneNs = one * _nsPerTick;
  final iters = oneNs <= 0 ? 1 : (targetTrialNs / oneNs).floor();
  final n = iters < 1 ? 1 : iters;

  final trials = List<double>.filled(nTrials, 0.0);
  for (var t = 0; t < nTrials; t++) {
    sw.reset();
    sw.start();
    for (var j = 0; j < n; j++) {
      runOnce();
    }
    sw.stop();
    trials[t] = (sw.elapsedTicks * _nsPerTick) / n;
  }
  return Stats(_median(trials), canonicalLen, recordCount(kind, d));
}

Stats benchDecode(PKind kind, Data d, Uint8List bytes) {
  final sw = Stopwatch();
  void runOnce() => walk(bytes);

  for (var i = 0; i < nWarmup; i++) {
    runOnce();
  }

  sw.start();
  runOnce();
  sw.stop();
  final one = sw.elapsedTicks <= 0 ? 1 : sw.elapsedTicks;
  final oneNs = one * _nsPerTick;
  final iters = oneNs <= 0 ? 1 : (targetTrialNs / oneNs).floor();
  final n = iters < 1 ? 1 : iters;

  final trials = List<double>.filled(nTrials, 0.0);
  for (var t = 0; t < nTrials; t++) {
    sw.reset();
    sw.start();
    for (var j = 0; j < n; j++) {
      runOnce();
    }
    sw.stop();
    trials[t] = (sw.elapsedTicks * _nsPerTick) / n;
  }
  return Stats(_median(trials), bytes.length, recordCount(kind, d));
}

// ---------------------------------------------------------------------------
// Host label.
// ---------------------------------------------------------------------------

String hostLabel() {
  try {
    final text = File('/proc/cpuinfo').readAsStringSync();
    for (final line in text.split('\n')) {
      if (line.startsWith('model name')) {
        final c = line.indexOf(':');
        if (c != -1) return line.substring(c + 1).trim();
      }
    }
  } catch (_) {
    // fall through
  }
  return 'unknown';
}

// ---------------------------------------------------------------------------
// Self-contained SHA-256 (FIPS 180-4). No pub dependency (the crypto package is
// off-limits); this makes the byte-identity check real.
// ---------------------------------------------------------------------------

const List<int> _sha256K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr32(int x, int n) =>
    ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

String sha256Hex(Uint8List msg) {
  // Pre-processing: pad to a multiple of 64 bytes.
  final ml = msg.length;
  final bitLen = ml * 8;
  var padLen = 64 - ((ml + 9) % 64);
  if (padLen == 64) padLen = 0;
  final total = ml + 1 + padLen + 8;
  final data = Uint8List(total);
  data.setRange(0, ml, msg);
  data[ml] = 0x80;
  // 64-bit big-endian bit length in the final 8 bytes.
  for (var i = 0; i < 8; i++) {
    data[total - 1 - i] = (bitLen >>> (8 * i)) & 0xFF;
  }

  var h0 = 0x6a09e667,
      h1 = 0xbb67ae85,
      h2 = 0x3c6ef372,
      h3 = 0xa54ff53a,
      h4 = 0x510e527f,
      h5 = 0x9b05688c,
      h6 = 0x1f83d9ab,
      h7 = 0x5be0cd19;

  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < total; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final o = chunk + i * 4;
      w[i] = ((data[o] << 24) |
              (data[o + 1] << 16) |
              (data[o + 2] << 8) |
              data[o + 3]) &
          0xFFFFFFFF;
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr32(w[i - 15], 7) ^
          _rotr32(w[i - 15], 18) ^
          (w[i - 15] >>> 3);
      final s1 = _rotr32(w[i - 2], 17) ^
          _rotr32(w[i - 2], 19) ^
          (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    var a = h0, b = h1, c = h2, dd = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (h + s1 + ch + _sha256K[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (dd + t1) & 0xFFFFFFFF;
      dd = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }

    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + dd) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }

  final sb = StringBuffer();
  for (final hv in [h0, h1, h2, h3, h4, h5, h6, h7]) {
    sb.write(hv.toRadixString(16).padLeft(8, '0'));
  }
  return sb.toString();
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

double _round2(double x) => (x * 100).round() / 100;

void main(List<String> args) {
  // Resolve paths relative to the repo root (two levels up from this file:
  // bench/dart/bench.dart). The script may run from anywhere; the AOT exe lives
  // next to the source, so derive from Platform.script when possible, else fall
  // back to a fixed repo-root relative layout.
  final benchDir = _benchDir();
  final dataDir = '$benchDir/data';
  final resultsDir = '$benchDir/results';

  final manifestText = File('$benchDir/payloads.json').readAsStringSync();
  final manifest = jsonDecode(manifestText) as Map<String, dynamic>;
  final expected = <String, Map<String, dynamic>>{};
  for (final p in (manifest['payloads'] as List)) {
    final m = (p as Map).cast<String, dynamic>();
    expected[m['name'] as String] = m;
  }

  final data = readData(dataDir);

  final dartVersion = Platform.version.split(' ').first;
  stdout.writeln(
      'struple benchmark (Dart $dartVersion, single-threaded)\n');

  final out = <String, Map<String, dynamic>>{};
  var allOk = true;
  var totalBytes = 0;

  for (final meta in payloads) {
    final bytes = buildCanonical(meta.kind, data);
    totalBytes += bytes.length;

    // Verify byte-identity against the manifest BEFORE measuring.
    final exp = expected[meta.name];
    final sha = sha256Hex(bytes);
    final shaOk =
        exp != null && sha == exp['sha256'] && bytes.length == exp['byte_len'];
    if (!shaOk) {
      allOk = false;
      stderr.writeln('\nBYTE MISMATCH for ${meta.name}:\n'
          '  produced byte_len=${bytes.length} sha256=$sha\n'
          '  expected byte_len=${exp?['byte_len']} sha256=${exp?['sha256']}\n'
          'This is a contract bug — STOPPING (no throughput reported for this payload).');
      out[meta.name] = {
        'enc_mrec_s': 0,
        'enc_mb_s': 0,
        'dec_mrec_s': 0,
        'dec_mb_s': 0,
        'sha256_ok': false,
      };
      continue;
    }

    final enc = benchEncode(meta.kind, data, bytes.length);
    final dec = benchDecode(meta.kind, data, bytes);

    out[meta.name] = {
      'enc_mrec_s': _round2(enc.mRecPerSec),
      'enc_mb_s': _round2(enc.mbPerSec),
      'dec_mrec_s': _round2(dec.mRecPerSec),
      'dec_mb_s': _round2(dec.mbPerSec),
      'sha256_ok': true,
    };

    stdout.writeln('  ${meta.name.padRight(16)} '
        '${enc.records.toString().padLeft(6)} rec   '
        'enc ${enc.mRecPerSec.toStringAsFixed(2).padLeft(7)} Mrec/s '
        '${enc.mbPerSec.toStringAsFixed(0).padLeft(6)} MB/s   '
        'dec ${dec.mRecPerSec.toStringAsFixed(2).padLeft(7)} Mrec/s '
        '${dec.mbPerSec.toStringAsFixed(0).padLeft(6)} MB/s   sha ok');
  }

  final host = hostLabel();
  final result = {'lang': 'Dart', 'host': host, 'payloads': out};

  Directory(resultsDir).createSync(recursive: true);
  File('$resultsDir/dart.json')
      .writeAsStringSync('${_jsonPretty(result)}\n');

  stdout.writeln('\nHost: $host · '
      'Total corpus: ${(totalBytes / 1024).toStringAsFixed(1)} KB · '
      'Wrote bench/results/dart.json');
  stdout.writeln('(sink ${gSink.toUnsigned(64).toRadixString(16)})');

  if (!allOk) {
    stderr.writeln('\nOne or more payloads failed byte-identity — see above.');
    exit(1);
  }
}

// Resolve the bench/ directory from the running script/exe location, falling
// back to "<repo>/bench" relative to CWD. Works for both `dart run` and the AOT
// exe (both report a file:// URI for Platform.script).
String _benchDir() {
  try {
    final scriptPath = Platform.script.toFilePath();
    // .../bench/dart/bench.dart  (or .../bench/dart/bench for the exe)
    final dir = File(scriptPath).parent; // .../bench/dart
    final benchParent = dir.parent; // .../bench
    if (Directory('${benchParent.path}/data').existsSync()) {
      return benchParent.path;
    }
  } catch (_) {
    // fall through
  }
  // Fallback: assume CWD is the repo root.
  if (Directory('bench/data').existsSync()) return 'bench';
  return 'bench';
}

// Minimal stable-key JSON pretty-printer (2-space indent) matching the layout
// the other ports emit (JSON.stringify(result, null, 2)). Avoids depending on
// dart:convert's JsonEncoder formatting differences.
String _jsonPretty(Object? value, [int indent = 0]) {
  final pad = '  ' * indent;
  final padIn = '  ' * (indent + 1);
  if (value is Map) {
    if (value.isEmpty) return '{}';
    final sb = StringBuffer('{\n');
    final keys = value.keys.toList();
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      sb.write('$padIn${_jsonStr(k.toString())}: '
          '${_jsonPretty(value[k], indent + 1)}');
      sb.write(i + 1 < keys.length ? ',\n' : '\n');
    }
    sb.write('$pad}');
    return sb.toString();
  }
  if (value is List) {
    if (value.isEmpty) return '[]';
    final sb = StringBuffer('[\n');
    for (var i = 0; i < value.length; i++) {
      sb.write('$padIn${_jsonPretty(value[i], indent + 1)}');
      sb.write(i + 1 < value.length ? ',\n' : '\n');
    }
    sb.write('$pad]');
    return sb.toString();
  }
  if (value is String) return _jsonStr(value);
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) {
    // Emit integers without a trailing .0, doubles as-is.
    if (value is int) return value.toString();
    if (value == value.truncateToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    return value.toString();
  }
  if (value == null) return 'null';
  return _jsonStr(value.toString());
}

String _jsonStr(String s) {
  final sb = StringBuffer('"');
  for (final code in s.runes) {
    switch (code) {
      case 0x22:
        sb.write('\\"');
      case 0x5C:
        sb.write('\\\\');
      case 0x08:
        sb.write('\\b');
      case 0x0C:
        sb.write('\\f');
      case 0x0A:
        sb.write('\\n');
      case 0x0D:
        sb.write('\\r');
      case 0x09:
        sb.write('\\t');
      default:
        if (code < 0x20) {
          sb.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
        } else {
          sb.writeCharCode(code);
        }
    }
  }
  sb.write('"');
  return sb.toString();
}

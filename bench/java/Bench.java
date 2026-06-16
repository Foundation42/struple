// struple reference benchmark (Java).
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
// untimed) with a tiny hand-rolled tokenizer (Java has no stdlib JSON, and the
// data is a simple structure: arrays of '"'-quoted strings). The encoder then
// rebuilds the bytes with the same appendX sequence the Zig/TS references use.
// Byte-identity is verified against bench/payloads.json (sha256) before any
// throughput figure is reported.
//
// Methodology (per (payload, op)): a generous JVM warm-up, auto-calibrate the
// iteration count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is
// reported. A static checksum sink consumes every result so the JIT can't elide
// the work. Steady-state buffers retain capacity (the codec already amortizes
// allocation internally; for a GC'd port a fresh per-record Packer is a no-op).
// Single-threaded.
//
// Zero dependencies beyond the JDK (java.math.BigInteger, java.security.
// MessageDigest, java.nio). No Maven/Gradle/JUnit — matches the port's
// no-build-tool style.
//
// Compile + run (JDK 26, the toolchain java/run-tests.sh uses; run from the
// repo root so the bench/* relative paths resolve):
//
//   javac -d bench/java/build bench/java/Bench.java java/src/struple/Struple.java
//   java -cp bench/java/build Bench
//
// (Bench is in the default package and imports struple.Struple.* — compiling
// the codec source alongside it keeps the bench self-contained and does not
// touch java/build or run-tests.sh.)

import static struple.Struple.*;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class Bench {

  // -------------------------------------------------------------------------
  // DCE sink — every measured op folds something into this so the JIT must
  // actually perform the work. A plain long mirrors the Zig `g_sink: u64`
  // (Java long arithmetic wraps mod 2^64, exactly like Zig's `+%`).
  // -------------------------------------------------------------------------
  static long gSink = 0;

  static void sink(long v) {
    gSink += v;
  }

  // -------------------------------------------------------------------------
  // Native record shapes (parsed once from the shared JSON data).
  // -------------------------------------------------------------------------

  static final class Dec {
    final int[] digits; // coefficient digits, MSD-first, each 0–9
    final int exp;

    Dec(int[] digits, int exp) {
      this.digits = digits;
      this.exp = exp;
    }
  }

  static final class Quote {
    final String symbol;
    final Dec bid;
    final Dec ask;
    final double last; // f64
    final long volume;
    final long ts; // µs since epoch

    Quote(String symbol, Dec bid, Dec ask, double last, long volume, long ts) {
      this.symbol = symbol;
      this.bid = bid;
      this.ask = ask;
      this.last = last;
      this.volume = volume;
      this.ts = ts;
    }
  }

  static final class Geo {
    final double lat;
    final double lon;
    final double elevation;
    final String name;
    final long ts;

    Geo(double lat, double lon, double elevation, String name, long ts) {
      this.lat = lat;
      this.lon = lon;
      this.elevation = elevation;
      this.name = name;
      this.ts = ts;
    }
  }

  static final class Tweet {
    final BigInteger id; // u64 — can exceed 2^63, so BigInteger
    final String user;
    final String text;
    final long createdAt;
    final long likes;
    final long retweets;

    Tweet(BigInteger id, String user, String text, long createdAt, long likes, long retweets) {
      this.id = id;
      this.user = user;
      this.text = text;
      this.createdAt = createdAt;
      this.likes = likes;
      this.retweets = retweets;
    }
  }

  static final class Tx {
    final long height;
    final byte[] txHash; // 32 bytes
    final byte[] from; // 20 bytes
    final byte[] to; // 20 bytes
    // wei value: both the i128 fixed path and the big-int path reduce to a
    // BigInteger; appendBigInteger routes by magnitude (byte-identical to the
    // Zig appendI128 / appendBigInt split).
    final BigInteger value;
    final long gas;
    final long nonce;
    final long ts;

    Tx(long height, byte[] txHash, byte[] from, byte[] to, BigInteger value,
        long gas, long nonce, long ts) {
      this.height = height;
      this.txHash = txHash;
      this.from = from;
      this.to = to;
      this.value = value;
      this.gas = gas;
      this.nonce = nonce;
      this.ts = ts;
    }
  }

  static final class Nested {
    final long uid;
    final String name;
    final boolean active;
    final long s0;
    final long s1;
    final long s2;

    Nested(long uid, String name, boolean active, long s0, long s1, long s2) {
      this.uid = uid;
      this.name = name;
      this.active = active;
      this.s0 = s0;
      this.s1 = s1;
      this.s2 = s2;
    }
  }

  static final class Data {
    Quote[] quotes;
    Geo[] geo;
    Tweet[] tweets;
    Tx[] txs;
    long[] ints;
    String[] strings;
    Nested[] nested;
  }

  enum PKind {
    QUOTES, GEO, TWEETS, TXS, INTS, STRINGS, NESTED
  }

  static final class PayloadMeta {
    final PKind kind;
    final String name;
    final String category;

    PayloadMeta(PKind kind, String name, String category) {
      this.kind = kind;
      this.name = name;
      this.category = category;
    }
  }

  static final PayloadMeta[] PAYLOADS = {
    new PayloadMeta(PKind.QUOTES, "stock_quotes", "streaming"),
    new PayloadMeta(PKind.GEO, "geo_points", "streaming"),
    new PayloadMeta(PKind.TWEETS, "tweets", "streaming"),
    new PayloadMeta(PKind.TXS, "blockchain_txs", "streaming"),
    new PayloadMeta(PKind.INTS, "int_stream", "structural"),
    new PayloadMeta(PKind.STRINGS, "string_stream", "structural"),
    new PayloadMeta(PKind.NESTED, "nested_doc", "structural"),
  };

  // -------------------------------------------------------------------------
  // Minimal JSON tokenizer. The shared data is a SIMPLE structure: arrays of
  // '"'-quoted strings (flat array, or array of arrays). Only handles `[` `]`
  // `,` and quoted strings with the escapes the Zig emitter writes (backslash
  // quote, double-backslash, and backslash-u four-hex). Returns nested
  // List<Object> where leaves are String.
  // -------------------------------------------------------------------------
  static final class JsonParser {
    private final String s;
    private int i;

    JsonParser(String s) {
      this.s = s;
    }

    Object parse() {
      skipWs();
      Object v = parseValue();
      skipWs();
      return v;
    }

    private Object parseValue() {
      skipWs();
      char c = s.charAt(i);
      if (c == '[') {
        return parseArray();
      }
      if (c == '"') {
        return parseString();
      }
      throw new RuntimeException("unexpected char '" + c + "' at " + i);
    }

    private List<Object> parseArray() {
      i++; // consume '['
      List<Object> out = new ArrayList<>();
      skipWs();
      if (s.charAt(i) == ']') {
        i++;
        return out;
      }
      while (true) {
        out.add(parseValue());
        skipWs();
        char c = s.charAt(i++);
        if (c == ']') {
          break;
        }
        if (c != ',') {
          throw new RuntimeException("expected ',' or ']' at " + (i - 1));
        }
      }
      return out;
    }

    private String parseString() {
      i++; // consume opening '"'
      StringBuilder sb = new StringBuilder();
      while (true) {
        char c = s.charAt(i++);
        if (c == '"') {
          break;
        }
        if (c == '\\') {
          char e = s.charAt(i++);
          switch (e) {
            case '"': sb.append('"'); break;
            case '\\': sb.append('\\'); break;
            case '/': sb.append('/'); break;
            case 'b': sb.append('\b'); break;
            case 'f': sb.append('\f'); break;
            case 'n': sb.append('\n'); break;
            case 'r': sb.append('\r'); break;
            case 't': sb.append('\t'); break;
            case 'u': {
              int cp = Integer.parseInt(s.substring(i, i + 4), 16);
              i += 4;
              sb.append((char) cp);
              break;
            }
            default:
              throw new RuntimeException("bad escape \\" + e + " at " + (i - 1));
          }
        } else {
          sb.append(c);
        }
      }
      return sb.toString();
    }

    private void skipWs() {
      while (i < s.length()) {
        char c = s.charAt(i);
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
          i++;
        } else {
          break;
        }
      }
    }
  }

  // -------------------------------------------------------------------------
  // Parsing helpers — the shared data fields are all typed strings. See
  // bench/README.md.
  // -------------------------------------------------------------------------

  // 16 hex digits of the IEEE-754 bits (big-endian) → double.
  static double f64FromHex(String hex) {
    long bits = Long.parseUnsignedLong(hex, 16);
    return Double.longBitsToDouble(bits);
  }

  // digit string "12345" → [1,2,3,4,5]
  static int[] digitsFromStr(String s) {
    int[] out = new int[s.length()];
    for (int k = 0; k < s.length(); k++) {
      out[k] = s.charAt(k) - '0';
    }
    return out;
  }

  // hex string (even length) → bytes
  static byte[] bytesFromHex(String hex) {
    int n = hex.length() / 2;
    byte[] out = new byte[n];
    for (int k = 0; k < n; k++) {
      int hi = Character.digit(hex.charAt(k * 2), 16);
      int lo = Character.digit(hex.charAt(k * 2 + 1), 16);
      out[k] = (byte) ((hi << 4) | lo);
    }
    return out;
  }

  // big-endian hex magnitude → BigInteger (both `big` and `fix` blockchain
  // paths reduce to this; appendBigInteger routes by magnitude).
  static BigInteger bigFromHex(String hex) {
    return hex.isEmpty() ? BigInteger.ZERO : new BigInteger(hex, 16);
  }

  @SuppressWarnings("unchecked")
  static Data readData(Path dataDir) throws IOException {
    Data d = new Data();

    List<Object> quotesRaw = (List<Object>) loadJson(dataDir, "stock_quotes");
    d.quotes = new Quote[quotesRaw.size()];
    for (int k = 0; k < quotesRaw.size(); k++) {
      List<Object> r = (List<Object>) quotesRaw.get(k);
      d.quotes[k] = new Quote(
          (String) r.get(0),
          new Dec(digitsFromStr((String) r.get(1)), Integer.parseInt((String) r.get(2))),
          new Dec(digitsFromStr((String) r.get(3)), Integer.parseInt((String) r.get(4))),
          f64FromHex((String) r.get(5)),
          Long.parseLong((String) r.get(6)),
          Long.parseLong((String) r.get(7)));
    }

    List<Object> geoRaw = (List<Object>) loadJson(dataDir, "geo_points");
    d.geo = new Geo[geoRaw.size()];
    for (int k = 0; k < geoRaw.size(); k++) {
      List<Object> r = (List<Object>) geoRaw.get(k);
      d.geo[k] = new Geo(
          f64FromHex((String) r.get(0)),
          f64FromHex((String) r.get(1)),
          f64FromHex((String) r.get(2)),
          (String) r.get(3),
          Long.parseLong((String) r.get(4)));
    }

    List<Object> tweetsRaw = (List<Object>) loadJson(dataDir, "tweets");
    d.tweets = new Tweet[tweetsRaw.size()];
    for (int k = 0; k < tweetsRaw.size(); k++) {
      List<Object> r = (List<Object>) tweetsRaw.get(k);
      d.tweets[k] = new Tweet(
          new BigInteger((String) r.get(0)), // u64 id — may exceed 2^63
          (String) r.get(1),
          (String) r.get(2),
          Long.parseLong((String) r.get(3)),
          Long.parseLong((String) r.get(4)),
          Long.parseLong((String) r.get(5)));
    }

    List<Object> txsRaw = (List<Object>) loadJson(dataDir, "blockchain_txs");
    d.txs = new Tx[txsRaw.size()];
    for (int k = 0; k < txsRaw.size(); k++) {
      List<Object> r = (List<Object>) txsRaw.get(k);
      // r.get(4) is "big" | "fix"; r.get(5) is the big-endian hex magnitude.
      // Both collapse to a BigInteger for appendBigInteger.
      d.txs[k] = new Tx(
          Long.parseLong((String) r.get(0)),
          bytesFromHex((String) r.get(1)),
          bytesFromHex((String) r.get(2)),
          bytesFromHex((String) r.get(3)),
          bigFromHex((String) r.get(5)),
          Long.parseLong((String) r.get(6)),
          Long.parseLong((String) r.get(7)),
          Long.parseLong((String) r.get(8)));
    }

    List<Object> intsRaw = (List<Object>) loadJson(dataDir, "int_stream");
    d.ints = new long[intsRaw.size()];
    for (int k = 0; k < intsRaw.size(); k++) {
      d.ints[k] = Long.parseLong((String) intsRaw.get(k));
    }

    List<Object> strRaw = (List<Object>) loadJson(dataDir, "string_stream");
    d.strings = new String[strRaw.size()];
    for (int k = 0; k < strRaw.size(); k++) {
      d.strings[k] = (String) strRaw.get(k);
    }

    List<Object> nestedRaw = (List<Object>) loadJson(dataDir, "nested_doc");
    d.nested = new Nested[nestedRaw.size()];
    for (int k = 0; k < nestedRaw.size(); k++) {
      List<Object> r = (List<Object>) nestedRaw.get(k);
      d.nested[k] = new Nested(
          Long.parseLong((String) r.get(1)),
          (String) r.get(2),
          "1".equals(r.get(0)),
          Long.parseLong((String) r.get(3)),
          Long.parseLong((String) r.get(4)),
          Long.parseLong((String) r.get(5)));
    }

    return d;
  }

  static Object loadJson(Path dataDir, String name) throws IOException {
    String text = Files.readString(dataDir.resolve(name + ".json"));
    return new JsonParser(text).parse();
  }

  // -------------------------------------------------------------------------
  // Encoders — one per payload kind. `out` is reset (a fresh Packer) by the
  // caller each iteration; a fresh `scratch` Packer frames one record at a time
  // (the codec amortizes its growable buffer internally; on a GC'd port a
  // per-record Packer is a no-op, per bench/README.md optimization #2).
  // Mirrors encodeOnce in bench/zig/bench.zig.
  // -------------------------------------------------------------------------

  // Pre-encoded constant keys for the nested-doc map (the keys never change;
  // the Zig harness re-encodes them per record from an arena, but the keys are
  // invariant, so caching them is byte-identical and avoids needless work —
  // mirrors the JS port).
  static final byte[] KEY_ACTIVE = encodeString("active");
  static final byte[] KEY_SCORES = encodeString("scores");
  static final byte[] KEY_USER = encodeString("user");
  static final byte[] KEY_ID = encodeString("id");
  static final byte[] KEY_NAME = encodeString("name");

  static byte[] encodeString(String s) {
    return new Packer().appendString(s).bytes();
  }

  static byte[] encodeInt(long v) {
    return new Packer().appendInt(v).bytes();
  }

  static byte[] encodeBool(boolean v) {
    return new Packer().appendBool(v).bytes();
  }

  static void encodeOnce(PKind kind, Data d, Packer out) {
    switch (kind) {
      case QUOTES:
        for (Quote q : d.quotes) {
          Packer scratch = new Packer();
          scratch.appendString(q.symbol);
          scratch.appendDecimal(false, q.bid.digits, q.bid.exp);
          scratch.appendDecimal(false, q.ask.digits, q.ask.exp);
          scratch.appendFloat64(q.last);
          scratch.appendInt(q.volume);
          scratch.appendTimestamp(q.ts);
          out.appendArray(scratch.bytes());
        }
        break;
      case GEO:
        for (Geo g : d.geo) {
          Packer scratch = new Packer();
          scratch.appendFloat64(g.lat);
          scratch.appendFloat64(g.lon);
          scratch.appendFloat64(g.elevation);
          scratch.appendString(g.name);
          scratch.appendTimestamp(g.ts);
          out.appendArray(scratch.bytes());
        }
        break;
      case TWEETS:
        for (Tweet t : d.tweets) {
          Packer scratch = new Packer();
          scratch.appendBigInteger(t.id); // u64 id — positive, routes via fixed/big by magnitude
          scratch.appendString(t.user);
          scratch.appendString(t.text);
          scratch.appendTimestamp(t.createdAt);
          scratch.appendInt(t.likes);
          scratch.appendInt(t.retweets);
          out.appendArray(scratch.bytes());
        }
        break;
      case TXS:
        for (Tx x : d.txs) {
          Packer scratch = new Packer();
          scratch.appendInt(x.height);
          scratch.appendBytes(x.txHash);
          scratch.appendBytes(x.from);
          scratch.appendBytes(x.to);
          scratch.appendBigInteger(x.value); // big-int or i128 fixed path, by magnitude
          scratch.appendInt(x.gas);
          scratch.appendInt(x.nonce);
          scratch.appendTimestamp(x.ts);
          out.appendArray(scratch.bytes());
        }
        break;
      case INTS:
        for (long v : d.ints) {
          out.appendInt(v);
        }
        break;
      case STRINGS:
        for (String s : d.strings) {
          out.appendString(s);
        }
        break;
      case NESTED:
        for (Nested n : d.nested) {
          // user sub-map { id, name }
          List<byte[][]> userEntries = new ArrayList<>(2);
          userEntries.add(new byte[][] {KEY_ID, encodeInt(n.uid)});
          userEntries.add(new byte[][] {KEY_NAME, encodeString(n.name)});
          byte[] user = new Packer().appendMap(userEntries).bytes();
          // scores array [s0, s1, s2]
          Packer scoresInner = new Packer();
          scoresInner.appendInt(n.s0);
          scoresInner.appendInt(n.s1);
          scoresInner.appendInt(n.s2);
          byte[] scoresArr = new Packer().appendArray(scoresInner.bytes()).bytes();
          // top-level map (appendMap sorts by encoded key, so order here is free)
          List<byte[][]> entries = new ArrayList<>(3);
          entries.add(new byte[][] {KEY_ACTIVE, encodeBool(n.active)});
          entries.add(new byte[][] {KEY_SCORES, scoresArr});
          entries.add(new byte[][] {KEY_USER, user});
          out.appendMap(entries);
        }
        break;
    }
  }

  static int recordCount(PKind kind, Data d) {
    switch (kind) {
      case QUOTES: return d.quotes.length;
      case GEO: return d.geo.length;
      case TWEETS: return d.tweets.length;
      case TXS: return d.txs.length;
      case INTS: return d.ints.length;
      case STRINGS: return d.strings.length;
      case NESTED: return d.nested.length;
      default: throw new IllegalStateException();
    }
  }

  // -------------------------------------------------------------------------
  // Decode — recursive walk that touches every value, descending into every
  // container (the Reader already un-escapes each container body in a single
  // pass via takeFramedUnescaped, so el.inner() is the un-escaped child stream
  // — recursing into it does the realistic work without a redundant pre-scan,
  // mirroring the JS port). Sink accumulation mirrors bench/zig/bench.zig walk.
  // -------------------------------------------------------------------------

  static void walk(byte[] buf) {
    Reader r = new Reader(buf);
    Element el;
    while ((el = r.next()) != null) {
      switch (el.kind) {
        case NIL:
        case UNDEF:
          break;
        case BOOLEAN:
          sink(el.boolValue() ? 1L : 0L);
          break;
        case INT:
          sink(el.intValue().longValue()); // low 64 bits (== Zig @truncate i64 → u64)
          break;
        case BIG_INT:
          sink(el.bigInt().magnitude.length);
          break;
        case FLOAT32:
          sink(Float.floatToRawIntBits(el.float32()) & 0xFFFFFFFFL);
          break;
        case FLOAT64:
          sink(Double.doubleToRawLongBits(el.float64()));
          break;
        case DECIMAL: {
          Decimal dc = el.decimal();
          sink(dc.coeffStored.length + dc.adjExp);
          break;
        }
        case TIMESTAMP:
          sink(el.timestamp());
          break;
        case UUID:
          sink(el.uuid()[0] & 0xFFL);
          break;
        case STRING: {
          byte[] s = el.stringBytes();
          sink(s.length);
          if (s.length > 0) {
            sink(s[0] & 0xFFL);
          }
          break;
        }
        case BYTES: {
          byte[] s = el.bytesValue();
          sink(s.length);
          if (s.length > 0) {
            sink(s[0] & 0xFFL);
          }
          break;
        }
        case ARRAY:
        case MAP:
        case SET:
          walk(el.inner()); // inner() is already un-escaped (single pass in next())
          break;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Timing.
  // -------------------------------------------------------------------------

  static final class Stats {
    final double nsPerOp;
    final long bytes;
    final int records;

    Stats(double nsPerOp, long bytes, int records) {
      this.nsPerOp = nsPerOp;
      this.bytes = bytes;
      this.records = records;
    }

    double mbPerSec() {
      return (bytes / nsPerOp) * 1000.0; // bytes/ns → MB/s
    }

    double mRecPerSec() {
      return (records / nsPerOp) * 1000.0; // rec/ns → Mrec/s
    }
  }

  static final long TARGET_TRIAL_NS = 100_000_000L; // ~100 ms
  static final int N_TRIALS = 9;
  // Generous warm-up: the JVM's tiered JIT (C1 → C2) needs far more than the
  // reference's 5 iterations to reach steady state. We run a warm-up *budget*
  // (~400 ms of repeated runOnce) per (payload, op) so C2 has compiled the hot
  // path before any trial is timed; with median-of-9 on top, timings stabilize.
  static final long WARMUP_NS = 400_000_000L;

  static double median(double[] values) {
    double[] sorted = values.clone();
    Arrays.sort(sorted);
    return sorted[sorted.length / 2];
  }

  static byte[] buildCanonical(PKind kind, Data d) {
    Packer out = new Packer();
    encodeOnce(kind, d, out);
    return out.bytes();
  }

  interface Op {
    void run();
  }

  /** Warm up `op` for at least WARMUP_NS, then auto-calibrate + time 9 trials. */
  static double measure(Op op) {
    // Warm-up budget — drives the JVM to steady-state JIT.
    long warmStart = System.nanoTime();
    long warmRuns = 0;
    do {
      op.run();
      warmRuns++;
      // Re-check time only every few runs for very cheap ops to limit overhead.
    } while (System.nanoTime() - warmStart < WARMUP_NS);

    // Calibrate iteration count to ~TARGET_TRIAL_NS from one fresh run.
    long t0 = System.nanoTime();
    op.run();
    long one = Math.max(System.nanoTime() - t0, 1);
    long iters = Math.max(1, TARGET_TRIAL_NS / one);

    double[] trials = new double[N_TRIALS];
    for (int t = 0; t < N_TRIALS; t++) {
      long s = System.nanoTime();
      for (long j = 0; j < iters; j++) {
        op.run();
      }
      long dt = System.nanoTime() - s;
      trials[t] = (double) dt / iters;
    }
    return median(trials);
  }

  static Stats benchEncode(PKind kind, Data d, long canonicalLen) {
    Op op = () -> {
      Packer out = new Packer();
      encodeOnce(kind, d, out);
      sink(out.bytes().length);
    };
    return new Stats(measure(op), canonicalLen, recordCount(kind, d));
  }

  static Stats benchDecode(PKind kind, Data d, byte[] bytes) {
    Op op = () -> walk(bytes);
    return new Stats(measure(op), bytes.length, recordCount(kind, d));
  }

  // -------------------------------------------------------------------------
  // Host label.
  // -------------------------------------------------------------------------

  static String hostLabel() {
    try {
      String text = Files.readString(Path.of("/proc/cpuinfo"));
      for (String line : text.split("\n")) {
        if (line.startsWith("model name")) {
          int c = line.indexOf(':');
          if (c != -1) {
            return line.substring(c + 1).trim();
          }
        }
      }
    } catch (IOException e) {
      /* fall through */
    }
    return "unknown";
  }

  // -------------------------------------------------------------------------
  // sha256 + tiny JSON output (no dependency).
  // -------------------------------------------------------------------------

  static String sha256Hex(byte[] bytes) {
    try {
      MessageDigest md = MessageDigest.getInstance("SHA-256");
      byte[] dig = md.digest(bytes);
      StringBuilder sb = new StringBuilder(dig.length * 2);
      for (byte b : dig) {
        sb.append(Character.forDigit((b >> 4) & 0xF, 16));
        sb.append(Character.forDigit(b & 0xF, 16));
      }
      return sb.toString();
    } catch (NoSuchAlgorithmException e) {
      throw new RuntimeException(e);
    }
  }

  static double round2(double x) {
    return Math.round(x * 100.0) / 100.0;
  }

  static String jsonNum(double x) {
    // Match the JS JSON.stringify(round2(x)) style: integral values print
    // without a trailing ".0" only when JS would; to keep it simple and valid
    // JSON we always print the rounded double via Double.toString, then strip a
    // trailing ".0" to mirror JSON.stringify of an integer-valued number.
    double r = round2(x);
    if (r == Math.rint(r) && !Double.isInfinite(r)) {
      return Long.toString((long) r);
    }
    String s = Double.toString(r);
    return s;
  }

  // -------------------------------------------------------------------------
  // Manifest parsing — pull each payload's name/byte_len/sha256 out of
  // bench/payloads.json with the same tokenizer-grade simplicity (regex-free,
  // tolerant of the known shape).
  // -------------------------------------------------------------------------

  static final class Expected {
    final long byteLen;
    final String sha256;

    Expected(long byteLen, String sha256) {
      this.byteLen = byteLen;
      this.sha256 = sha256;
    }
  }

  static java.util.Map<String, Expected> readManifest(Path benchDir) throws IOException {
    String text = Files.readString(benchDir.resolve("payloads.json"));
    java.util.Map<String, Expected> map = new java.util.HashMap<>();
    // The manifest is a structured JSON object; parse the fields we need with a
    // light scan keyed on the well-known field names (the file is generated, so
    // the shape is stable). Find each "name": "..." then its "byte_len" and
    // "sha256".
    int idx = 0;
    while (true) {
      int n = text.indexOf("\"name\"", idx);
      if (n < 0) {
        break;
      }
      String name = jsonStringAfter(text, n + "\"name\"".length());
      int bl = text.indexOf("\"byte_len\"", n);
      long byteLen = jsonLongAfter(text, bl + "\"byte_len\"".length());
      int sh = text.indexOf("\"sha256\"", n);
      String sha = jsonStringAfter(text, sh + "\"sha256\"".length());
      map.put(name, new Expected(byteLen, sha));
      idx = sh;
    }
    return map;
  }

  // After a key, skip ': ' then read a quoted string.
  static String jsonStringAfter(String s, int from) {
    int i = s.indexOf('"', s.indexOf(':', from) + 1);
    int j = s.indexOf('"', i + 1);
    return s.substring(i + 1, j);
  }

  // After a key, skip ':' then read a bare integer.
  static long jsonLongAfter(String s, int from) {
    int i = s.indexOf(':', from) + 1;
    while (i < s.length() && (s.charAt(i) == ' ' || s.charAt(i) == '\t')) {
      i++;
    }
    int j = i;
    while (j < s.length() && (Character.isDigit(s.charAt(j)) || s.charAt(j) == '-')) {
      j++;
    }
    return Long.parseLong(s.substring(i, j).trim());
  }

  // -------------------------------------------------------------------------
  // Main.
  // -------------------------------------------------------------------------

  public static void main(String[] args) throws IOException {
    // Paths resolved relative to the repo root (the CWD the compile+run command
    // documents). An optional first argument overrides the repo root (used by
    // the verification harness, which runs from a different CWD). bench/ holds
    // the manifest + data + results.
    Path repoRoot = (args.length > 0)
        ? Path.of(args[0]).toAbsolutePath()
        : Path.of("").toAbsolutePath();
    Path benchDir = repoRoot.resolve("bench");
    Path dataDir = benchDir.resolve("data");
    Path resultsDir = benchDir.resolve("results");

    java.util.Map<String, Expected> expected = readManifest(benchDir);
    Data data = readData(dataDir);

    System.out.println("struple benchmark (Java " + System.getProperty("java.version")
        + ", single-threaded)\n");

    // Ordered map for stable output (matches payload order).
    java.util.LinkedHashMap<String, double[]> results = new java.util.LinkedHashMap<>();
    java.util.LinkedHashMap<String, Boolean> shaResults = new java.util.LinkedHashMap<>();
    boolean allOk = true;
    long totalBytes = 0;

    for (PayloadMeta meta : PAYLOADS) {
      byte[] bytes = buildCanonical(meta.kind, data);
      totalBytes += bytes.length;

      Expected exp = expected.get(meta.name);
      String sha = sha256Hex(bytes);
      boolean shaOk = exp != null && sha.equals(exp.sha256) && bytes.length == exp.byteLen;
      shaResults.put(meta.name, shaOk);

      if (!shaOk) {
        allOk = false;
        System.err.println("\nBYTE MISMATCH for " + meta.name + ":\n"
            + "  produced byte_len=" + bytes.length + " sha256=" + sha + "\n"
            + "  expected byte_len=" + (exp == null ? "?" : exp.byteLen)
            + " sha256=" + (exp == null ? "?" : exp.sha256) + "\n"
            + "This is a contract bug — STOPPING (no throughput reported for this payload).");
        results.put(meta.name, new double[] {0, 0, 0, 0});
        continue;
      }

      Stats enc = benchEncode(meta.kind, data, bytes.length);
      Stats dec = benchDecode(meta.kind, data, bytes);

      results.put(meta.name, new double[] {
        enc.mRecPerSec(), enc.mbPerSec(), dec.mRecPerSec(), dec.mbPerSec()
      });

      System.out.printf(
          "  %-16s %6d rec   enc %7.2f Mrec/s %6.0f MB/s   dec %7.2f Mrec/s %6.0f MB/s   sha %s%n",
          meta.name, enc.records, enc.mRecPerSec(), enc.mbPerSec(),
          dec.mRecPerSec(), dec.mbPerSec(), shaOk ? "ok" : "FAIL");
    }

    String host = hostLabel();
    Files.createDirectories(resultsDir);
    Files.writeString(resultsDir.resolve("java.json"),
        renderJson(host, results, shaResults));

    System.out.printf("%nHost: %s · Total corpus: %.1f KB · Wrote bench/results/java.json%n",
        host, totalBytes / 1024.0);
    System.out.printf("(sink %x)%n", gSink);

    if (!allOk) {
      System.err.println("\nOne or more payloads failed byte-identity — see above.");
      System.exit(1);
    }
  }

  static String renderJson(String host, java.util.LinkedHashMap<String, double[]> results,
      java.util.LinkedHashMap<String, Boolean> shaResults) {
    StringBuilder sb = new StringBuilder();
    sb.append("{\n");
    sb.append("  \"lang\": \"Java\",\n");
    sb.append("  \"host\": \"").append(host).append("\",\n");
    sb.append("  \"payloads\": {\n");
    int i = 0;
    int n = results.size();
    for (var e : results.entrySet()) {
      double[] v = e.getValue();
      sb.append("    \"").append(e.getKey()).append("\": {\n");
      sb.append("      \"enc_mrec_s\": ").append(jsonNum(v[0])).append(",\n");
      sb.append("      \"enc_mb_s\": ").append(jsonNum(v[1])).append(",\n");
      sb.append("      \"dec_mrec_s\": ").append(jsonNum(v[2])).append(",\n");
      sb.append("      \"dec_mb_s\": ").append(jsonNum(v[3])).append(",\n");
      sb.append("      \"sha256_ok\": ").append(shaResults.get(e.getKey())).append("\n");
      sb.append("    }").append(++i == n ? "" : ",").append("\n");
    }
    sb.append("  }\n");
    sb.append("}\n");
    return sb.toString();
  }
}

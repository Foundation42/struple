// struple reference benchmark (C# / .NET).
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
// untimed) with System.Text.Json; the encoder then rebuilds the bytes with the
// same appendX sequence the Zig reference uses. Byte-identity is verified
// against bench/payloads.json (sha256) before any throughput figure is reported.
//
// Methodology (per (payload, op)): generous JIT warm-up, auto-calibrate the
// iteration count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is
// reported. A global checksum sink consumes every result so the JIT can't elide
// the work. Single-threaded. Zero dependencies beyond the BCL.
//
// .NET JIT WARM-UP: tiered compilation promotes hot methods tier-0 -> tier-1 only
// after a call-count threshold, so the first calls run unoptimized. We run an
// explicit, generous warm-up (see N_WARMUP_OPS below): a fixed ~300 ms of timed
// warm-up *per (payload, op)* on top of the 5 nominal warm-up ops, which is more
// than enough iterations on every payload to drive the codec methods to tier-1
// (and let TieredPGO collect profile data) before any trial is measured.
//
// Build + run (Release):
//   /home/chrisbe/.dotnet/dotnet run -c Release --project bench/csharp/Bench.csproj
// (run from the repo root /home/chrisbe/dev/struple, or pass the absolute path;
//  data/manifest paths are resolved relative to this source file's location so
//  it also works from anywhere.)

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Struple;

namespace Struple.Bench;

internal static class Program
{
    // -----------------------------------------------------------------------
    // DCE sink — every measured op folds something into this so the JIT must
    // actually perform the work. A ulong accumulator (wrapping) mirrors the Zig
    // `g_sink: u64` and the JS BigInt sink exactly.
    // -----------------------------------------------------------------------
    private static ulong s_sink;
    private static readonly BigInteger UInt64Mask = (BigInteger.One << 64) - BigInteger.One;

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void Sink(ulong v) => s_sink = unchecked(s_sink + v);

    // -----------------------------------------------------------------------
    // Native record shapes (parsed once from the shared JSON data).
    // -----------------------------------------------------------------------

    private struct Dec
    {
        public int[] Digits; // coefficient digits, MSD-first, each 0–9
        public int Exp;
    }

    private struct Quote
    {
        public string Symbol;
        public Dec Bid;
        public Dec Ask;
        public double Last; // f64
        public long Volume;
        public long Ts; // µs since epoch
    }

    private struct Geo
    {
        public double Lat;
        public double Lon;
        public double Elevation;
        public string Name;
        public long Ts;
    }

    private struct Tweet
    {
        public BigInteger Id; // u64 (exceeds long.MaxValue for some ids)
        public string User;
        public string Text;
        public long CreatedAt;
        public long Likes;
        public long Retweets;
    }

    private struct Tx
    {
        public long Height;
        public byte[] TxHash; // 32 bytes
        public byte[] From; // 20 bytes
        public byte[] To; // 20 bytes
        public BigInteger Value; // wei (both the i128 fixed path and the big-int path reduce to a BigInteger)
        public long Gas;
        public long Nonce;
        public long Ts;
    }

    private struct Nested
    {
        public long Uid;
        public string Name;
        public bool Active;
        public long Score0, Score1, Score2;
    }

    private sealed class Data
    {
        public Quote[] Quotes = System.Array.Empty<Quote>();
        public Geo[] Geo = System.Array.Empty<Geo>();
        public Tweet[] Tweets = System.Array.Empty<Tweet>();
        public Tx[] Txs = System.Array.Empty<Tx>();
        public long[] Ints = System.Array.Empty<long>();
        public string[] Strings = System.Array.Empty<string>();
        public Nested[] Nested = System.Array.Empty<Nested>();
    }

    private enum PKind { Quotes, Geo, Tweets, Txs, Ints, Strings, Nested }

    private readonly struct PayloadMeta
    {
        public readonly PKind Kind;
        public readonly string Name;
        public readonly string Category;
        public PayloadMeta(PKind kind, string name, string category)
        {
            Kind = kind;
            Name = name;
            Category = category;
        }
    }

    private static readonly PayloadMeta[] s_payloads =
    {
        new(PKind.Quotes, "stock_quotes", "streaming"),
        new(PKind.Geo, "geo_points", "streaming"),
        new(PKind.Tweets, "tweets", "streaming"),
        new(PKind.Txs, "blockchain_txs", "streaming"),
        new(PKind.Ints, "int_stream", "structural"),
        new(PKind.Strings, "string_stream", "structural"),
        new(PKind.Nested, "nested_doc", "structural"),
    };

    // -----------------------------------------------------------------------
    // Path resolution — relative to this source file, like the JS/Python ports.
    // -----------------------------------------------------------------------

    private static string SourceDir([CallerFilePath] string path = "") => Path.GetDirectoryName(path)!;

    private static readonly string s_benchDir = Path.GetFullPath(Path.Combine(SourceDir(), ".."));
    private static readonly string s_dataDir = Path.Combine(s_benchDir, "data");
    private static readonly string s_resultsDir = Path.Combine(s_benchDir, "results");

    // -----------------------------------------------------------------------
    // Parsing helpers — the shared data fields are all typed strings (so any
    // JSON library reads them identically across languages). See bench/README.md.
    // -----------------------------------------------------------------------

    // 16 hex digits of the IEEE-754 bits (big-endian) → double (bit-reinterpret).
    private static double F64FromHex(string hex)
    {
        ulong bits = ulong.Parse(hex, System.Globalization.NumberStyles.HexNumber, System.Globalization.CultureInfo.InvariantCulture);
        return BitConverter.Int64BitsToDouble(unchecked((long)bits));
    }

    // digit string "12345" → [1,2,3,4,5]
    private static int[] DigitsFromStr(string s)
    {
        var outArr = new int[s.Length];
        for (int i = 0; i < s.Length; i++) outArr[i] = s[i] - '0';
        return outArr;
    }

    // hex string (even length) → bytes
    private static byte[] BytesFromHex(string hex)
    {
        var outArr = new byte[hex.Length / 2];
        for (int i = 0; i < outArr.Length; i++)
        {
            outArr[i] = (byte)((HexNibble(hex[i * 2]) << 4) | HexNibble(hex[i * 2 + 1]));
        }
        return outArr;
    }

    private static int HexNibble(char c)
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        throw new FormatException("bad hex digit");
    }

    // big-endian hex magnitude → BigInteger (both the `big` and `fix` blockchain
    // paths reduce to this: AppendBigInteger routes magnitudes within i128 through
    // the fixed slots and magnitudes beyond i128 through the big-int codes,
    // byte-for-byte identical to the Zig appendI128 / appendBigInt split). The
    // magnitude is unsigned big-endian; prefix a 0x00 so BigInteger treats the
    // top bit as magnitude, not sign.
    private static BigInteger BigFromHex(string hex)
    {
        if (hex.Length == 0) return BigInteger.Zero;
        byte[] be = BytesFromHex(hex);
        return new BigInteger(be, isUnsigned: true, isBigEndian: true);
    }

    private static long ParseLong(string s) =>
        long.Parse(s, System.Globalization.CultureInfo.InvariantCulture);

    private static string[][] LoadRows(string name)
    {
        string text = File.ReadAllText(Path.Combine(s_dataDir, name + ".json"));
        return JsonSerializer.Deserialize<string[][]>(text)!;
    }

    private static string[] LoadFlat(string name)
    {
        string text = File.ReadAllText(Path.Combine(s_dataDir, name + ".json"));
        return JsonSerializer.Deserialize<string[]>(text)!;
    }

    private static Data ReadData()
    {
        var d = new Data();

        var quotesRaw = LoadRows("stock_quotes");
        d.Quotes = new Quote[quotesRaw.Length];
        for (int i = 0; i < quotesRaw.Length; i++)
        {
            var r = quotesRaw[i];
            d.Quotes[i] = new Quote
            {
                Symbol = r[0],
                Bid = new Dec { Digits = DigitsFromStr(r[1]), Exp = (int)ParseLong(r[2]) },
                Ask = new Dec { Digits = DigitsFromStr(r[3]), Exp = (int)ParseLong(r[4]) },
                Last = F64FromHex(r[5]),
                Volume = ParseLong(r[6]),
                Ts = ParseLong(r[7]),
            };
        }

        var geoRaw = LoadRows("geo_points");
        d.Geo = new Geo[geoRaw.Length];
        for (int i = 0; i < geoRaw.Length; i++)
        {
            var r = geoRaw[i];
            d.Geo[i] = new Geo
            {
                Lat = F64FromHex(r[0]),
                Lon = F64FromHex(r[1]),
                Elevation = F64FromHex(r[2]),
                Name = r[3],
                Ts = ParseLong(r[4]),
            };
        }

        var tweetsRaw = LoadRows("tweets");
        d.Tweets = new Tweet[tweetsRaw.Length];
        for (int i = 0; i < tweetsRaw.Length; i++)
        {
            var r = tweetsRaw[i];
            d.Tweets[i] = new Tweet
            {
                // u64 id may exceed long.MaxValue — parse exactly via BigInteger.
                Id = BigInteger.Parse(r[0], System.Globalization.CultureInfo.InvariantCulture),
                User = r[1],
                Text = r[2],
                CreatedAt = ParseLong(r[3]),
                Likes = ParseLong(r[4]),
                Retweets = ParseLong(r[5]),
            };
        }

        var txsRaw = LoadRows("blockchain_txs");
        d.Txs = new Tx[txsRaw.Length];
        for (int i = 0; i < txsRaw.Length; i++)
        {
            var r = txsRaw[i];
            // r[4] is "big" | "fix"; r[5] is the big-endian hex magnitude. Both
            // collapse to a BigInteger for AppendBigInteger (magnitude chooses the
            // codec path). System.Decimal is only 28–29 digits and CANNOT hold the
            // 256-bit wei magnitudes — BigInteger is required here.
            d.Txs[i] = new Tx
            {
                Height = ParseLong(r[0]),
                TxHash = BytesFromHex(r[1]),
                From = BytesFromHex(r[2]),
                To = BytesFromHex(r[3]),
                Value = BigFromHex(r[5]),
                Gas = ParseLong(r[6]),
                Nonce = ParseLong(r[7]),
                Ts = ParseLong(r[8]),
            };
        }

        var intsRaw = LoadFlat("int_stream");
        d.Ints = new long[intsRaw.Length];
        for (int i = 0; i < intsRaw.Length; i++) d.Ints[i] = ParseLong(intsRaw[i]);

        d.Strings = LoadFlat("string_stream");

        var nestedRaw = LoadRows("nested_doc");
        d.Nested = new Nested[nestedRaw.Length];
        for (int i = 0; i < nestedRaw.Length; i++)
        {
            var r = nestedRaw[i];
            d.Nested[i] = new Nested
            {
                Active = r[0] == "1",
                Uid = ParseLong(r[1]),
                Name = r[2],
                Score0 = ParseLong(r[3]),
                Score1 = ParseLong(r[4]),
                Score2 = ParseLong(r[5]),
            };
        }

        return d;
    }

    // -----------------------------------------------------------------------
    // Encoders — one per payload kind. Mirrors encodeOnce in bench/zig/bench.zig
    // and bench/js/bench.ts. The C# Packer has no public reset (Bytes() returns a
    // fresh array), so each record frames into a freshly-constructed Packer — the
    // honest baseline against the public API. (See the optimization note at the
    // bottom of this file.)
    //
    // The nested-doc map keys never change, so they are pre-encoded once and
    // reused (byte-identical to the Zig harness, which re-encodes invariant keys
    // from an arena each record).
    // -----------------------------------------------------------------------

    private static readonly byte[] s_keyActive = EncodeString("active");
    private static readonly byte[] s_keyScores = EncodeString("scores");
    private static readonly byte[] s_keyUser = EncodeString("user");
    private static readonly byte[] s_keyId = EncodeString("id");
    private static readonly byte[] s_keyName = EncodeString("name");

    private static byte[] EncodeString(string s) => new Struple.Packer().AppendString(s).Bytes();
    private static byte[] EncodeInt(long v) => new Struple.Packer().AppendInt(v).Bytes();
    private static byte[] EncodeBool(bool v) => new Struple.Packer().AppendBool(v).Bytes();

    private static void EncodeOnce(PKind kind, Data d, Struple.Packer outP)
    {
        switch (kind)
        {
            case PKind.Quotes:
                foreach (var q in d.Quotes)
                {
                    var scratch = new Struple.Packer();
                    scratch.AppendString(q.Symbol);
                    scratch.AppendDecimal(false, q.Bid.Digits, q.Bid.Exp);
                    scratch.AppendDecimal(false, q.Ask.Digits, q.Ask.Exp);
                    scratch.AppendFloat64(q.Last);
                    scratch.AppendInt(q.Volume);
                    scratch.AppendTimestamp(q.Ts);
                    outP.AppendArray(scratch.Bytes());
                }
                break;
            case PKind.Geo:
                foreach (var g in d.Geo)
                {
                    var scratch = new Struple.Packer();
                    scratch.AppendFloat64(g.Lat);
                    scratch.AppendFloat64(g.Lon);
                    scratch.AppendFloat64(g.Elevation);
                    scratch.AppendString(g.Name);
                    scratch.AppendTimestamp(g.Ts);
                    outP.AppendArray(scratch.Bytes());
                }
                break;
            case PKind.Tweets:
                foreach (var t in d.Tweets)
                {
                    var scratch = new Struple.Packer();
                    scratch.AppendBigInteger(t.Id); // u64 id; positive, so == appendUint
                    scratch.AppendString(t.User);
                    scratch.AppendString(t.Text);
                    scratch.AppendTimestamp(t.CreatedAt);
                    scratch.AppendInt(t.Likes);
                    scratch.AppendInt(t.Retweets);
                    outP.AppendArray(scratch.Bytes());
                }
                break;
            case PKind.Txs:
                foreach (var x in d.Txs)
                {
                    var scratch = new Struple.Packer();
                    scratch.AppendInt(x.Height);
                    scratch.AppendBytes(x.TxHash);
                    scratch.AppendBytes(x.From);
                    scratch.AppendBytes(x.To);
                    scratch.AppendBigInteger(x.Value); // big-int or i128 fixed path, by magnitude
                    scratch.AppendInt(x.Gas);
                    scratch.AppendInt(x.Nonce);
                    scratch.AppendTimestamp(x.Ts);
                    outP.AppendArray(scratch.Bytes());
                }
                break;
            case PKind.Ints:
                foreach (var v in d.Ints) outP.AppendInt(v);
                break;
            case PKind.Strings:
                foreach (var s in d.Strings) outP.AppendString(s);
                break;
            case PKind.Nested:
                foreach (var n in d.Nested)
                {
                    // user sub-map { id, name }
                    byte[] user = new Struple.Packer().AppendMap(new[]
                    {
                        new[] { s_keyId, EncodeInt(n.Uid) },
                        new[] { s_keyName, EncodeString(n.Name) },
                    }).Bytes();
                    // scores array [s0, s1, s2]
                    var scoresInner = new Struple.Packer();
                    scoresInner.AppendInt(n.Score0);
                    scoresInner.AppendInt(n.Score1);
                    scoresInner.AppendInt(n.Score2);
                    byte[] scoresArr = new Struple.Packer().AppendArray(scoresInner.Bytes()).Bytes();
                    // top-level map (AppendMap sorts by encoded key, so order here is free)
                    outP.AppendMap(new[]
                    {
                        new[] { s_keyActive, EncodeBool(n.Active) },
                        new[] { s_keyScores, scoresArr },
                        new[] { s_keyUser, user },
                    });
                }
                break;
        }
    }

    private static int RecordCount(PKind kind, Data d) => kind switch
    {
        PKind.Quotes => d.Quotes.Length,
        PKind.Geo => d.Geo.Length,
        PKind.Tweets => d.Tweets.Length,
        PKind.Txs => d.Txs.Length,
        PKind.Ints => d.Ints.Length,
        PKind.Strings => d.Strings.Length,
        PKind.Nested => d.Nested.Length,
        _ => 0,
    };

    // -----------------------------------------------------------------------
    // Decode — recursive walk that touches every value, descending into and
    // un-escaping every container body (the realistic cost of the
    // memcmp-orderable framing). The Reader already un-escapes each container body
    // in a single pass inside Next() (TakeFramedUnescaped), so descending into
    // Element.Inner does the realistic work without a redundant pre-scan.
    // Mirrors walk() in bench/zig/bench.zig and bench/js/bench.ts.
    // -----------------------------------------------------------------------

    private static void Walk(byte[] buf)
    {
        var r = new Struple.Reader(buf);
        Struple.Element? el;
        while ((el = r.Next()) != null)
        {
            switch (el.Kind)
            {
                case Struple.Kind.Nil:
                case Struple.Kind.Undef:
                    break;
                case Struple.Kind.Boolean:
                    Sink(el.BoolValue ? 1ul : 0ul);
                    break;
                case Struple.Kind.Int:
                    // Truncate to the low 64 bits (mirrors Zig @truncate→@bitCast / JS asUintN(64)).
                    Sink((ulong)(el.IntValue & UInt64Mask));
                    break;
                case Struple.Kind.BigIntKind:
                    Sink((ulong)el.BigInt!.Magnitude.Length);
                    break;
                case Struple.Kind.Float32:
                    Sink(unchecked((uint)BitConverter.SingleToInt32Bits(el.Float32Value)));
                    break;
                case Struple.Kind.Float64:
                    Sink(unchecked((ulong)BitConverter.DoubleToInt64Bits(el.Float64Value)));
                    break;
                case Struple.Kind.Decimal:
                {
                    var dc = el.Decimal!;
                    Sink((ulong)dc.CoeffStored.Length + unchecked((ulong)dc.AdjExp));
                    break;
                }
                case Struple.Kind.Timestamp:
                    Sink(unchecked((ulong)el.TimestampValue));
                    break;
                case Struple.Kind.Uuid:
                    Sink(el.UuidValue[0]);
                    break;
                case Struple.Kind.String:
                {
                    byte[] s = el.StringBytes;
                    Sink((ulong)s.Length);
                    if (s.Length > 0) Sink(s[0]);
                    break;
                }
                case Struple.Kind.Bytes:
                {
                    byte[] s = el.BytesValue;
                    Sink((ulong)s.Length);
                    if (s.Length > 0) Sink(s[0]);
                    break;
                }
                case Struple.Kind.Array:
                case Struple.Kind.Map:
                case Struple.Kind.Set:
                    Walk(el.Inner);
                    break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Timing.
    // -----------------------------------------------------------------------

    private struct Stats
    {
        public double NsPerOp;
        public long Bytes;
        public int Records;
        public readonly double MbPerSec => (Bytes / NsPerOp) * 1000.0; // bytes/ns → MB/s
        public readonly double MRecPerSec => (Records / NsPerOp) * 1000.0; // rec/ns → Mrec/s
    }

    private const long TargetTrialNs = 100_000_000; // ~100 ms
    private const int NTrials = 9;
    private const int NWarmupOps = 5;
    // Extra timed warm-up to drive the JIT (tier-0 -> tier-1 + TieredPGO) before
    // any trial: keep running until ~300 ms has elapsed. On these payloads that is
    // thousands to millions of iterations — far past the tiering threshold.
    private const long WarmupNs = 300_000_000; // ~300 ms

    private static readonly double s_nsPerTick = 1_000_000_000.0 / Stopwatch.Frequency;

    private static double Median(double[] values)
    {
        var sorted = (double[])values.Clone();
        System.Array.Sort(sorted);
        return sorted[sorted.Length / 2];
    }

    private static byte[] BuildCanonical(PKind kind, Data d)
    {
        var outP = new Struple.Packer();
        EncodeOnce(kind, d, outP);
        return outP.Bytes();
    }

    private static Stats BenchEncode(PKind kind, Data d, long canonicalLen)
    {
        void RunOnce()
        {
            var outP = new Struple.Packer();
            EncodeOnce(kind, d, outP);
            Sink((ulong)outP.Bytes().Length);
        }

        // Nominal warm-up + generous timed JIT warm-up.
        for (int i = 0; i < NWarmupOps; i++) RunOnce();
        long warmStart = Stopwatch.GetTimestamp();
        while ((Stopwatch.GetTimestamp() - warmStart) * s_nsPerTick < WarmupNs) RunOnce();

        long t0 = Stopwatch.GetTimestamp();
        RunOnce();
        double oneNs = System.Math.Max((Stopwatch.GetTimestamp() - t0) * s_nsPerTick, 1.0);
        long iters = System.Math.Max(1, (long)(TargetTrialNs / oneNs));

        var trials = new double[NTrials];
        for (int t = 0; t < NTrials; t++)
        {
            t0 = Stopwatch.GetTimestamp();
            for (long j = 0; j < iters; j++) RunOnce();
            double dt = (Stopwatch.GetTimestamp() - t0) * s_nsPerTick;
            trials[t] = dt / iters;
        }
        return new Stats { NsPerOp = Median(trials), Bytes = canonicalLen, Records = RecordCount(kind, d) };
    }

    private static Stats BenchDecode(PKind kind, Data d, byte[] bytes)
    {
        void RunOnce() => Walk(bytes);

        for (int i = 0; i < NWarmupOps; i++) RunOnce();
        long warmStart = Stopwatch.GetTimestamp();
        while ((Stopwatch.GetTimestamp() - warmStart) * s_nsPerTick < WarmupNs) RunOnce();

        long t0 = Stopwatch.GetTimestamp();
        RunOnce();
        double oneNs = System.Math.Max((Stopwatch.GetTimestamp() - t0) * s_nsPerTick, 1.0);
        long iters = System.Math.Max(1, (long)(TargetTrialNs / oneNs));

        var trials = new double[NTrials];
        for (int t = 0; t < NTrials; t++)
        {
            t0 = Stopwatch.GetTimestamp();
            for (long j = 0; j < iters; j++) RunOnce();
            double dt = (Stopwatch.GetTimestamp() - t0) * s_nsPerTick;
            trials[t] = dt / iters;
        }
        return new Stats { NsPerOp = Median(trials), Bytes = bytes.Length, Records = RecordCount(kind, d) };
    }

    // -----------------------------------------------------------------------
    // Host label.
    // -----------------------------------------------------------------------

    private static string HostLabel()
    {
        try
        {
            foreach (var line in File.ReadLines("/proc/cpuinfo"))
            {
                if (line.StartsWith("model name", StringComparison.Ordinal))
                {
                    int c = line.IndexOf(':');
                    if (c != -1) return line.Substring(c + 1).Trim();
                }
            }
        }
        catch
        {
            // fall through
        }
        return "unknown";
    }

    private static string Sha256Hex(byte[] bytes)
    {
        byte[] hash = SHA256.HashData(bytes);
        var sb = new StringBuilder(hash.Length * 2);
        foreach (byte b in hash) sb.Append(b.ToString("x2", System.Globalization.CultureInfo.InvariantCulture));
        return sb.ToString();
    }

    private static double Round2(double x) => System.Math.Round(x * 100.0) / 100.0;

    // -----------------------------------------------------------------------
    // Main.
    // -----------------------------------------------------------------------

    private static int Main()
    {
        // Parse the manifest.
        string manifestText = File.ReadAllText(Path.Combine(s_benchDir, "payloads.json"));
        var expected = new Dictionary<string, (long ByteLen, string Sha256)>();
        using (var doc = JsonDocument.Parse(manifestText))
        {
            foreach (var p in doc.RootElement.GetProperty("payloads").EnumerateArray())
            {
                expected[p.GetProperty("name").GetString()!] =
                    (p.GetProperty("byte_len").GetInt64(), p.GetProperty("sha256").GetString()!);
            }
        }

        Data data = ReadData();

        Console.WriteLine($"struple benchmark (C# / .NET {Environment.Version}, Release, single-threaded)\n");

        var outResults = new Dictionary<string, object>();
        bool allOk = true;
        long totalBytes = 0;

        foreach (var meta in s_payloads)
        {
            byte[] bytes = BuildCanonical(meta.Kind, data);
            totalBytes += bytes.Length;

            // Verify byte-identity against the manifest BEFORE measuring.
            string sha = Sha256Hex(bytes);
            bool shaOk = expected.TryGetValue(meta.Name, out var exp)
                && sha == exp.Sha256 && bytes.Length == exp.ByteLen;
            if (!shaOk)
            {
                allOk = false;
                Console.Error.WriteLine(
                    $"\nBYTE MISMATCH for {meta.Name}:\n" +
                    $"  produced byte_len={bytes.Length} sha256={sha}\n" +
                    $"  expected byte_len={(expected.ContainsKey(meta.Name) ? exp.ByteLen.ToString() : "?")} " +
                    $"sha256={(expected.ContainsKey(meta.Name) ? exp.Sha256 : "?")}\n" +
                    "This is a contract bug — STOPPING (no throughput reported for this payload).");
                outResults[meta.Name] = new Dictionary<string, object>
                {
                    ["enc_mrec_s"] = 0.0, ["enc_mb_s"] = 0.0,
                    ["dec_mrec_s"] = 0.0, ["dec_mb_s"] = 0.0, ["sha256_ok"] = false,
                };
                continue;
            }

            Stats enc = BenchEncode(meta.Kind, data, bytes.Length);
            Stats dec = BenchDecode(meta.Kind, data, bytes);

            outResults[meta.Name] = new Dictionary<string, object>
            {
                ["enc_mrec_s"] = Round2(enc.MRecPerSec),
                ["enc_mb_s"] = Round2(enc.MbPerSec),
                ["dec_mrec_s"] = Round2(dec.MRecPerSec),
                ["dec_mb_s"] = Round2(dec.MbPerSec),
                ["sha256_ok"] = true,
            };

            Console.WriteLine(
                $"  {meta.Name,-16} {enc.Records,6} rec   " +
                $"enc {enc.MRecPerSec,7:F2} Mrec/s {enc.MbPerSec,6:F0} MB/s   " +
                $"dec {dec.MRecPerSec,7:F2} Mrec/s {dec.MbPerSec,6:F0} MB/s   sha ok");
        }

        string host = HostLabel();

        Directory.CreateDirectory(s_resultsDir);
        var result = new Dictionary<string, object>
        {
            ["lang"] = "C#",
            ["host"] = host,
            ["payloads"] = outResults,
        };
        var jsonOpts = new JsonSerializerOptions { WriteIndented = true };
        string json = JsonSerializer.Serialize(result, jsonOpts) + "\n";
        File.WriteAllText(Path.Combine(s_resultsDir, "csharp.json"), json);

        Console.WriteLine(
            $"\nHost: {host} · Total corpus: {(totalBytes / 1024.0):F1} KB · " +
            "Wrote bench/results/csharp.json");
        Console.WriteLine($"(sink {s_sink:x})");

        if (!allOk)
        {
            Console.Error.WriteLine("\nOne or more payloads failed byte-identity — see above.");
            return 1;
        }
        return 0;
    }
}

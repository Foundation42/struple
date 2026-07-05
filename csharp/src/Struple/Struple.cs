using System;
using System.Collections.Generic;
using System.Numerics;
using System.Text;

namespace Struple;

/// <summary>
/// struple — streaming, lexicographically-ordered tuple packing for C#/.NET.
///
/// <para>A <c>struple</c> value is a stream of self-delimiting, typed elements packed into a byte
/// buffer such that the raw encoded bytes are directly <c>memcmp</c>-comparable:</para>
///
/// <code>
///   Struple.Compare(Pack(a), Pack(b)) == the semantic order of a and b
/// </code>
///
/// <para>This is a faithful, zero-dependency (BCL-only) port of the Zig reference implementation,
/// byte-identical across all language ports and pinned by the shared conformance corpus.</para>
///
/// <para>Every element begins with a one-byte type code, assigned so a byte comparison of the type
/// byte alone gives the cross-type order:</para>
///
/// <code>
///   nil &lt; undefined &lt; false &lt; true
///       &lt; negative ints &lt; zero &lt; positive ints
///       &lt; float32 &lt; float64 &lt; decimal &lt; timestamp &lt; uuid
///       &lt; string &lt; bytes &lt; array &lt; map &lt; set
/// </code>
/// </summary>
public static class Struple
{
    // -----------------------------------------------------------------------
    // Type codes — the numeric values are load-bearing (their order IS the
    // cross-type sort order). Gaps are reserved for the future tower.
    // -----------------------------------------------------------------------

    /// <summary>Terminator / escape sentinel for variable-length framing. Never a type.</summary>
    public const int Terminator = 0x00;

    public const int Nil = 0x01;   // null (Python None / JS null)
    public const int Undef = 0x02; // JS undefined

    public const int BoolFalse = 0x05;
    public const int BoolTrue = 0x06;

    public const int IntNegBig = 0x0F; // arbitrary-precision negative (beyond i128)
    public const int IntNegMin = 0x10; // widest fixed negative (16-byte magnitude)
    public const int IntNegMax = 0x1F; // 1-byte fixed negative
    public const int IntZero = 0x20;
    public const int IntPosMin = 0x21; // 1-byte fixed positive
    public const int IntPosMax = 0x30; // widest fixed positive (16-byte magnitude)
    public const int IntPosBig = 0x31; // arbitrary-precision positive (beyond i128)

    public const int Float32 = 0x34;
    public const int Float64 = 0x35;

    public const int DecimalCode = 0x38; // arbitrary-precision base-10 number

    public const int Timestamp = 0x40;

    public const int Uuid = 0x44; // 16-byte fixed payload (no framing)

    public const int String = 0x48;
    public const int Bytes = 0x49;

    public const int Array = 0x50;
    public const int Map = 0x52;
    public const int Set = 0x54;

    /// <summary>Companion byte written after a literal 0x00 inside variable-length payloads.</summary>
    internal const int EscapeByte = 0xFF;

    // Leading sign markers inside a decimal payload, isolating the three sign groups so a byte
    // comparison keeps negative < zero < positive. For negatives the rest of the payload is
    // bit-complemented.
    internal const int DecSignNeg = 0x01;
    internal const int DecSignZero = 0x02;
    internal const int DecSignPos = 0x03;

    /// <summary>The i128 fixed-slot range — values beyond use the big-int codes.</summary>
    public static readonly BigInteger I128Max = (BigInteger.One << 127) - BigInteger.One;
    public static readonly BigInteger I128Min = -(BigInteger.One << 127);

    // -----------------------------------------------------------------------
    // Ordering (ordering IS memcmp)
    // -----------------------------------------------------------------------

    /// <summary>Lexicographic unsigned byte comparison (-1/0/1).</summary>
    public static int Compare(byte[] a, byte[] b)
    {
        int n = System.Math.Min(a.Length, b.Length);
        for (int i = 0; i < n; i++)
        {
            int c = a[i] - b[i]; // both already 0..255 as byte
            if (c != 0) return c < 0 ? -1 : 1;
        }
        return a.Length == b.Length ? 0 : (a.Length < b.Length ? -1 : 1);
    }

    public static bool BytesEqual(byte[] a, byte[] b)
    {
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++)
        {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Escaping helpers for variable-length payloads
    // -----------------------------------------------------------------------

    /// <summary>Un-escape a framed payload (0x00 0xFF -&gt; 0x00).</summary>
    public static byte[] Unescape(byte[] framed)
    {
        bool hasNul = false;
        foreach (byte b in framed)
        {
            if (b == 0x00) { hasNul = true; break; }
        }
        if (!hasNul) return framed;

        var outBuf = new ByteBuf();
        int i = 0;
        while (i < framed.Length)
        {
            outBuf.Add(framed[i]);
            if (framed[i] == 0x00) i++; // skip the 0xFF companion
            i++;
        }
        return outBuf.ToArray();
    }

    internal static int DecByte(byte b, bool complemented) => complemented ? (~b & 0xFF) : (b & 0xFF);

    internal static byte[] TrimLeadingZeros(byte[] b)
    {
        int s = 0;
        while (s < b.Length && b[s] == 0) s++;
        if (s == 0) return b;
        var outBuf = new byte[b.Length - s];
        System.Array.Copy(b, s, outBuf, 0, outBuf.Length);
        return outBuf;
    }

    // -----------------------------------------------------------------------
    // Integer encode
    // -----------------------------------------------------------------------

    // Fixed-path integer encode straight from a long — no BigInteger allocation
    // (a long always fits the i128 fixed slots). Byte-identical to AppendInteger.
    internal static void AppendLong(ByteBuf outBuf, long v)
    {
        if (v == 0) { outBuf.Add(IntZero); return; }
        bool negative = v < 0;
        ulong bits = (ulong)v;
        ulong mag = negative ? (~bits + 1UL) : bits; // unsigned magnitude (correct for long.MinValue)
        if (negative)
        {
            int n = System.Math.Max(1, ByteLenUlong(mag - 1UL));
            outBuf.Add(IntZero - n);
            WriteBigEndianUlong(outBuf, ~mag + 1UL, n); // low n bytes = 2^(8n) - magnitude
        }
        else
        {
            int n = ByteLenUlong(mag);
            outBuf.Add(IntZero + n);
            WriteBigEndianUlong(outBuf, mag, n);
        }
    }

    private static int ByteLenUlong(ulong m) =>
        m == 0 ? 0 : (64 - System.Numerics.BitOperations.LeadingZeroCount(m) + 7) / 8;

    private static void WriteBigEndianUlong(ByteBuf outBuf, ulong value, int n)
    {
        for (int i = n - 1; i >= 0; i--) outBuf.Add((int)((value >> (8 * i)) & 0xFF));
    }

    internal static void AppendInteger(ByteBuf outBuf, BigInteger value)
    {
        int sign = value.Sign;
        if (sign == 0)
        {
            outBuf.Add(IntZero);
            return;
        }
        bool negative = sign < 0;
        BigInteger mag = BigInteger.Abs(value);

        // The fixed slots span the whole i128 range (1–16 byte magnitudes).
        if (value >= I128Min && value <= I128Max)
        {
            if (negative)
            {
                BigInteger posVal = mag - BigInteger.One;
                int n = System.Math.Max(1, ByteLen(posVal));
                outBuf.Add(IntZero - n);
                // Excess form: store 2^(8n) - magnitude.
                BigInteger excess = (BigInteger.One << (8 * n)) - mag;
                WriteBigEndian(outBuf, excess, n);
            }
            else
            {
                int n = ByteLen(mag);
                outBuf.Add(IntZero + n);
                WriteBigEndian(outBuf, mag, n);
            }
            return;
        }

        // arbitrary precision beyond i128: [m][n][magnitude], complemented for negatives
        outBuf.Add(negative ? IntNegBig : IntPosBig);
        byte[] magBytes = MagnitudeBytes(mag);
        int len = magBytes.Length;
        int m = System.Math.Max(1, ByteLenInt(len));
        outBuf.Add(Comp(m, negative));
        for (int i = m - 1; i >= 0; i--)
        {
            outBuf.Add(Comp((len >> (8 * i)) & 0xFF, negative));
        }
        foreach (byte b in magBytes)
        {
            outBuf.Add(Comp(b & 0xFF, negative));
        }
    }

    private static int Comp(int b, bool negative) => negative ? (~b & 0xFF) : (b & 0xFF);

    /// <summary>Big-endian, normalized (no leading zeros) magnitude of a non-negative BigInteger.</summary>
    internal static byte[] MagnitudeBytes(BigInteger nonNeg)
    {
        if (nonNeg.Sign == 0) return System.Array.Empty<byte>();
        // ToByteArray is little-endian, unsigned form requested to avoid a sign byte.
        byte[] le = nonNeg.ToByteArray(isUnsigned: true, isBigEndian: false);
        // reverse to big-endian
        int len = le.Length;
        // trim trailing zeros in LE == leading zeros in BE
        while (len > 0 && le[len - 1] == 0) len--;
        var be = new byte[len];
        for (int i = 0; i < len; i++) be[i] = le[len - 1 - i];
        return be;
    }

    // -----------------------------------------------------------------------
    // Decimal encode
    // -----------------------------------------------------------------------

    internal static void AppendDecimalImpl(ByteBuf outBuf, bool negative, int[] digits, int exp)
    {
        int lead = 0;
        while (lead < digits.Length && digits[lead] == 0) lead++;
        outBuf.Add(DecimalCode);
        if (lead >= digits.Length)
        {
            // canonical zero — one form regardless of scale
            outBuf.Add(DecSignZero);
            return;
        }
        int sigLen = digits.Length - lead;
        // Adjusted exponent: place value of the most-significant digit (0.d…·10^E). Trailing zeros
        // change neither the value nor E, so drop them for storage.
        long adjExp = (long)sigLen + exp;
        int end = digits.Length;
        while (end > lead && digits[end - 1] == 0) end--;

        // Order-bearing tail: [E as a struple int][base-100 digits][terminator].
        var tail = new ByteBuf();
        AppendInteger(tail, new BigInteger(adjExp));
        for (int i = lead; i < end; i += 2)
        {
            int hi = digits[i];
            int lo = (i + 1 < end) ? digits[i + 1] : 0; // pad odd tail with 0
            tail.Add(hi * 10 + lo + 1); // pair 0–99 -> byte 1–100
        }
        tail.Add(Terminator);

        outBuf.Add(negative ? DecSignNeg : DecSignPos);
        byte[] tailBytes = tail.ToArray();
        foreach (byte b in tailBytes)
        {
            outBuf.Add(negative ? (~b & 0xFF) : (b & 0xFF));
        }
    }

    internal static void AppendDecimalStringImpl(ByteBuf outBuf, string s)
    {
        int i = 0;
        int n = s.Length;
        bool negative = false;
        if (i < n && (s[i] == '+' || s[i] == '-'))
        {
            negative = s[i] == '-';
            i++;
        }
        var digits = new int[n];
        int dlen = 0;
        int exp = 0;
        bool seenPoint = false;
        bool anyDigit = false;
        for (; i < n; i++)
        {
            char c = s[i];
            if (c == '.')
            {
                if (seenPoint) throw new StrupleException("invalid decimal");
                seenPoint = true;
                continue;
            }
            if (c == 'e' || c == 'E') break;
            if (c < '0' || c > '9') throw new StrupleException("invalid decimal");
            digits[dlen++] = c - '0';
            if (seenPoint) exp -= 1;
            anyDigit = true;
        }
        if (!anyDigit) throw new StrupleException("invalid decimal");
        if (i < n && (s[i] == 'e' || s[i] == 'E'))
        {
            i++;
            int esign = 1;
            if (i < n && (s[i] == '+' || s[i] == '-'))
            {
                if (s[i] == '-') esign = -1;
                i++;
            }
            int ev = 0;
            bool edig = false;
            for (; i < n; i++)
            {
                char c = s[i];
                if (c < '0' || c > '9') throw new StrupleException("invalid decimal");
                ev = ev * 10 + (c - '0');
                edig = true;
            }
            if (!edig) throw new StrupleException("invalid decimal");
            exp += esign * ev;
        }
        var trimmed = new int[dlen];
        System.Array.Copy(digits, trimmed, dlen);
        AppendDecimalImpl(outBuf, negative, trimmed, exp);
    }

    /// <summary>Decimal digits (0–9, most-significant first) of a non-negative BigInteger.</summary>
    internal static int[] DigitsOf(BigInteger nonNeg)
    {
        if (nonNeg.Sign == 0) return new[] { 0 };
        string s = nonNeg.ToString();
        var d = new int[s.Length];
        for (int i = 0; i < s.Length; i++) d[i] = s[i] - '0';
        return d;
    }

    // -----------------------------------------------------------------------
    // Float encode (IEEE-754 total ordering)
    // -----------------------------------------------------------------------

    internal static uint OrderableF32Bits(float value)
    {
        uint bits;
        if (float.IsNaN(value))
        {
            bits = 0x7fc00000u;
        }
        else
        {
            float v = (value == 0.0f) ? 0.0f : value; // squash -0.0
            bits = unchecked((uint)BitConverter.SingleToInt32Bits(v));
        }
        return (bits & 0x80000000u) != 0 ? ~bits : bits ^ 0x80000000u;
    }

    internal static ulong OrderableF64Bits(double value)
    {
        ulong bits;
        if (double.IsNaN(value))
        {
            bits = 0x7ff8000000000000ul;
        }
        else
        {
            double v = (value == 0.0) ? 0.0 : value;
            bits = unchecked((ulong)BitConverter.DoubleToInt64Bits(v));
        }
        return (bits & 0x8000000000000000ul) != 0 ? ~bits : bits ^ 0x8000000000000000ul;
    }

    // -----------------------------------------------------------------------
    // Variable-length framing
    // -----------------------------------------------------------------------

    internal static void WriteEscaped(ByteBuf outBuf, byte[] content)
    {
        foreach (byte b in content)
        {
            outBuf.Add(b);
            if (b == 0x00) outBuf.Add(EscapeByte);
        }
    }

    internal static void WriteFramed(ByteBuf outBuf, int typeCode, byte[] content)
    {
        outBuf.Add(typeCode);
        WriteEscaped(outBuf, content);
        outBuf.Add(Terminator);
    }

    // -----------------------------------------------------------------------
    // Byte / numeric helpers
    // -----------------------------------------------------------------------

    private static int ByteLen(BigInteger x)
    {
        if (x.Sign == 0) return 0;
        return (int)((BitLength(x) + 7) / 8);
    }

    private static long BitLength(BigInteger x)
    {
        // x is non-negative here.
        if (x.Sign == 0) return 0;
        byte[] le = x.ToByteArray(isUnsigned: true, isBigEndian: false);
        int top = le.Length - 1;
        while (top > 0 && le[top] == 0) top--;
        int bits = top * 8;
        int b = le[top];
        while (b != 0) { bits++; b >>= 1; }
        return bits;
    }

    private static int ByteLenInt(int x)
    {
        if (x == 0) return 0;
        int bits = 0;
        int v = x;
        while (v != 0) { bits++; v >>= 1; }
        return (bits + 7) / 8;
    }

    private static void WriteBigEndian(ByteBuf outBuf, BigInteger value, int n)
    {
        for (int i = n - 1; i >= 0; i--)
        {
            outBuf.Add((int)((value >> (8 * i)) & 0xFF));
        }
    }

    // -----------------------------------------------------------------------
    // Reader factory
    // -----------------------------------------------------------------------

    public static Reader NewReader(byte[] buf) => new Reader(buf);

    // -----------------------------------------------------------------------
    // Element kinds
    // -----------------------------------------------------------------------

    public enum Kind
    {
        Nil, Undef, Boolean, Int, BigIntKind, Float32, Float64, Decimal, Timestamp, Uuid, String,
        Bytes, Array, Map, Set,
    }

    /// <summary>View of an arbitrary-precision integer that did not fit the fixed (i128) path.</summary>
    public sealed class BigIntValue
    {
        public readonly bool Negative;

        /// <summary>Big-endian magnitude bytes, normalized (un-complemented).</summary>
        public readonly byte[] Magnitude;

        public BigIntValue(bool negative, byte[] magnitude)
        {
            Negative = negative;
            Magnitude = magnitude;
        }

        public BigInteger ToBigInteger()
        {
            BigInteger mag = Magnitude.Length == 0
                ? BigInteger.Zero
                : new BigInteger(Magnitude, isUnsigned: true, isBigEndian: true);
            return Negative ? -mag : mag;
        }
    }

    /// <summary>
    /// A decoded decimal: value = <c>(-1)^negative · coefficient · 10^exponent</c>. <c>AdjExp</c> is
    /// the adjusted exponent (the power of ten of the most-significant digit). The zero value has an
    /// empty coefficient.
    /// </summary>
    public sealed class DecimalValue
    {
        public readonly bool Negative;
        public readonly long AdjExp;

        /// <summary>Base-100 packed digit bytes, stored (each pair is value+1; never complemented).</summary>
        public readonly byte[] CoeffStored;

        internal DecimalValue(bool negative, long adjExp, byte[] coeffStored)
        {
            Negative = negative;
            AdjExp = adjExp;
            CoeffStored = coeffStored;
        }

        public bool IsZero => CoeffStored.Length == 0;

        /// <summary>Number of significant decimal digits in the coefficient.</summary>
        public int DigitCount()
        {
            if (CoeffStored.Length == 0) return 0;
            int pair = (CoeffStored[CoeffStored.Length - 1] & 0xFF) - 1;
            // An odd digit count pads the final pair's low digit with a (canonical) zero.
            return CoeffStored.Length * 2 - (pair % 10 == 0 ? 1 : 0);
        }

        /// <summary>The power of ten applied to the integer coefficient.</summary>
        public long Exponent() => AdjExp - DigitCount();

        /// <summary>Unpack the coefficient digits (each 0–9, most-significant first).</summary>
        public int[] CoefficientDigits()
        {
            var outBuf = new int[CoeffStored.Length * 2];
            int w = 0;
            for (int idx = 0; idx < CoeffStored.Length; idx++)
            {
                int pair = (CoeffStored[idx] & 0xFF) - 1;
                outBuf[w++] = pair / 10;
                int lo = pair % 10;
                bool isLast = idx + 1 == CoeffStored.Length;
                if (!(isLast && lo == 0)) // skip only the synthetic trailing pad
                {
                    outBuf[w++] = lo;
                }
            }
            var result = new int[w];
            System.Array.Copy(outBuf, result, w);
            return result;
        }

        /// <summary>The coefficient (sign-applied) as a BigInteger.</summary>
        public BigInteger Coefficient()
        {
            BigInteger coeff = BigInteger.Zero;
            foreach (int d in CoefficientDigits())
            {
                coeff = coeff * 10 + d;
            }
            return Negative ? -coeff : coeff;
        }
    }

    /// <summary>
    /// A decoded element. For string/bytes/array/map/set the payload is the un-escaped inner content
    /// (a copy), so containers can be re-read directly with a child Reader.
    /// </summary>
    public sealed class Element
    {
        public readonly Kind Kind;
        private readonly bool _bool;
        private readonly BigInteger _int;            // Int or BigInt
        private readonly BigIntValue? _bigInt;       // BigInt (beyond i128, sign+magnitude view)
        private readonly float _f32;
        private readonly double _f64;
        private readonly DecimalValue? _decimal;
        private readonly long _timestamp;            // microseconds since the Unix epoch, UTC
        private readonly byte[]? _bytes;             // uuid (16 raw) / string-utf8 / bytes / container inner

        private Element(Kind kind, bool b, BigInteger i, BigIntValue? bigInt, float f32, double f64,
            DecimalValue? dec, long ts, byte[]? bytes)
        {
            Kind = kind;
            _bool = b;
            _int = i;
            _bigInt = bigInt;
            _f32 = f32;
            _f64 = f64;
            _decimal = dec;
            _timestamp = ts;
            _bytes = bytes;
        }

        internal static Element MakeNil() => new(Kind.Nil, false, default, null, 0, 0, null, 0, null);
        internal static Element MakeUndef() => new(Kind.Undef, false, default, null, 0, 0, null, 0, null);
        internal static Element MakeBool(bool v) => new(Kind.Boolean, v, default, null, 0, 0, null, 0, null);
        internal static Element MakeInt(BigInteger v) => new(Kind.Int, false, v, null, 0, 0, null, 0, null);
        internal static Element MakeBigInt(BigIntValue bi) => new(Kind.BigIntKind, false, bi.ToBigInteger(), bi, 0, 0, null, 0, null);
        internal static Element MakeF32(float v) => new(Kind.Float32, false, default, null, v, 0, null, 0, null);
        internal static Element MakeF64(double v) => new(Kind.Float64, false, default, null, 0, v, null, 0, null);
        internal static Element MakeDecimal(DecimalValue d) => new(Kind.Decimal, false, default, null, 0, 0, d, 0, null);
        internal static Element MakeTimestamp(long micros) => new(Kind.Timestamp, false, default, null, 0, 0, null, micros, null);
        internal static Element MakeUuid(byte[] raw) => new(Kind.Uuid, false, default, null, 0, 0, null, 0, raw);
        internal static Element MakeString(byte[] utf8) => new(Kind.String, false, default, null, 0, 0, null, 0, utf8);
        internal static Element MakeBytes(byte[] b) => new(Kind.Bytes, false, default, null, 0, 0, null, 0, b);
        internal static Element MakeContainer(Kind kind, byte[] inner) => new(kind, false, default, null, 0, 0, null, 0, inner);

        public bool BoolValue => _bool;

        /// <summary>The integer value (for Int or BigInt) as a BigInteger.</summary>
        public BigInteger IntValue => _int;

        public BigIntValue? BigInt => _bigInt;
        public float Float32Value => _f32;
        public double Float64Value => _f64;
        public DecimalValue? Decimal => _decimal;
        public long TimestampValue => _timestamp;

        /// <summary>The 16 raw UUID bytes.</summary>
        public byte[] UuidValue => _bytes!;

        /// <summary>The string's decoded UTF-8 text.</summary>
        public string StringValue => Encoding.UTF8.GetString(_bytes!);

        /// <summary>The string's raw (un-escaped) UTF-8 bytes.</summary>
        public byte[] StringBytes => _bytes!;

        /// <summary>The raw (un-escaped) bytes payload.</summary>
        public byte[] BytesValue => _bytes!;

        /// <summary>A container's un-escaped inner element stream (array/map/set).</summary>
        public byte[] Inner => _bytes!;
    }

    // -----------------------------------------------------------------------
    // Packer (Writer) — builds an encoded tuple
    // -----------------------------------------------------------------------

    /// <summary>Builder for an encoded struple buffer. The bytes are memcmp-comparable.</summary>
    public sealed class Packer
    {
        private readonly ByteBuf _out = new();

        public byte[] Bytes() => _out.ToArray();

        public Packer AppendNil()
        {
            _out.Add(Nil);
            return this;
        }

        public Packer AppendUndefined()
        {
            _out.Add(Undef);
            return this;
        }

        public Packer AppendBool(bool v)
        {
            _out.Add(v ? BoolTrue : BoolFalse);
            return this;
        }

        public Packer AppendInt(long v)
        {
            AppendLong(_out, v);
            return this;
        }

        /// <summary>Encode an arbitrary-precision integer.</summary>
        public Packer AppendBigInteger(BigInteger v)
        {
            AppendInteger(_out, v);
            return this;
        }

        /// <summary>
        /// Encode an integer given its sign and big-endian magnitude bytes. Routes through the fixed
        /// path when the value fits i128, else the big-int codes.
        /// </summary>
        public Packer AppendBigInt(bool negative, byte[] magnitudeBe)
        {
            byte[] mag = TrimLeadingZeros(magnitudeBe);
            if (mag.Length == 0)
            {
                _out.Add(IntZero);
                return this;
            }
            BigInteger v = new BigInteger(mag, isUnsigned: true, isBigEndian: true);
            AppendInteger(_out, negative ? -v : v);
            return this;
        }

        public Packer AppendFloat32(float v)
        {
            _out.Add(Float32);
            WriteU32Be(_out, OrderableF32Bits(v));
            return this;
        }

        public Packer AppendFloat64(double v)
        {
            _out.Add(Float64);
            WriteU64Be(_out, OrderableF64Bits(v));
            return this;
        }

        /// <summary>
        /// Append an arbitrary-precision decimal <c>(-1)^negative · C · 10^exp</c>, where
        /// <c>digits</c> are C's decimal digits (each 0–9, most-significant first). Canonicalized on
        /// the way in.
        /// </summary>
        public Packer AppendDecimal(bool negative, int[] digits, int exp)
        {
            AppendDecimalImpl(_out, negative, digits, exp);
            return this;
        }

        /// <summary>Append a native System.Decimal (28–29 significant digits).</summary>
        public Packer AppendDecimal(decimal value)
        {
            // Decompose into unscaled integer * 10^-scale via the bit layout.
            int[] parts = decimal.GetBits(value);
            int scale = (parts[3] >> 16) & 0x7F;
            bool negative = (parts[3] & unchecked((int)0x80000000)) != 0;
            // 96-bit unsigned mantissa, little-endian 32-bit words.
            BigInteger unscaled =
                (new BigInteger((uint)parts[0]))
                | (new BigInteger((uint)parts[1]) << 32)
                | (new BigInteger((uint)parts[2]) << 64);
            int[] digits = DigitsOf(unscaled);
            AppendDecimalImpl(_out, negative, digits, -scale);
            return this;
        }

        /// <summary>Append a decimal parsed from text: <c>[+/-] digits [. digits] [ (e|E) [+/-] digits ]</c>.</summary>
        public Packer AppendDecimalString(string s)
        {
            AppendDecimalStringImpl(_out, s);
            return this;
        }

        /// <summary>Microseconds since the Unix epoch, UTC.</summary>
        public Packer AppendTimestamp(long micros)
        {
            _out.Add(Timestamp);
            // Flip the sign bit so two's-complement order matches unsigned byte order.
            WriteU64Be(_out, unchecked((ulong)micros) ^ 0x8000000000000000ul);
            return this;
        }

        /// <summary>A 128-bit UUID, stored as its 16 raw bytes.</summary>
        public Packer AppendUuid(byte[] raw)
        {
            if (raw.Length != 16) throw new ArgumentException("struple: uuid must be 16 bytes");
            _out.Add(Uuid);
            _out.AddAll(raw);
            return this;
        }

        /// <summary>A 128-bit UUID from a System.Guid (big-endian / RFC 4122 byte order).</summary>
        public Packer AppendUuid(Guid guid)
        {
            // Guid.ToByteArray() is mixed-endian; request big-endian for canonical network order.
            byte[] raw = guid.ToByteArray(bigEndian: true);
            return AppendUuid(raw);
        }

        public Packer AppendString(string s)
        {
            WriteFramed(_out, String, Encoding.UTF8.GetBytes(s));
            return this;
        }

        public Packer AppendStringBytes(byte[] utf8)
        {
            WriteFramed(_out, String, utf8);
            return this;
        }

        public Packer AppendBytes(byte[] content)
        {
            WriteFramed(_out, Struple.Bytes, content);
            return this;
        }

        /// <summary>Append a nested array. <c>child</c> is another tuple's encoded element stream.</summary>
        public Packer AppendArray(byte[] child)
        {
            WriteFramed(_out, Array, child);
            return this;
        }

        /// <summary>
        /// Frame an already-canonical container inner stream verbatim under <c>typeCode</c>
        /// (Array/Map/Set) without re-sorting. Used by the decoder round-trip (transcode), where the
        /// inner bytes are known canonical.
        /// </summary>
        public Packer AppendContainerBody(int typeCode, byte[] inner)
        {
            WriteFramed(_out, typeCode, inner);
            return this;
        }

        /// <summary>
        /// Append a map. <c>entries</c> is a list of <c>[keyEncoding, valueEncoding]</c> pairs,
        /// sorted by key into canonical order.
        /// </summary>
        public Packer AppendMap(IReadOnlyList<byte[][]> entries)
        {
            var sorted = new List<byte[][]>(entries);
            sorted.Sort((l, r) => Compare(l[0], r[0]));
            _out.Add(Map);
            foreach (var e in sorted)
            {
                WriteEscaped(_out, e[0]);
                WriteEscaped(_out, e[1]);
            }
            _out.Add(Terminator);
            return this;
        }

        /// <summary>Append a set. <c>elements</c> are sorted and de-duplicated into canonical order.</summary>
        public Packer AppendSet(IReadOnlyList<byte[]> elements)
        {
            var sorted = new List<byte[]>(elements);
            sorted.Sort((l, r) => Compare(l, r));
            _out.Add(Set);
            byte[]? prev = null;
            foreach (var e in sorted)
            {
                if (prev != null && BytesEqual(prev, e)) continue; // skip duplicate
                WriteEscaped(_out, e);
                prev = e;
            }
            _out.Add(Terminator);
            return this;
        }

        private static void WriteU32Be(ByteBuf outBuf, uint v)
        {
            outBuf.Add((int)((v >> 24) & 0xFF));
            outBuf.Add((int)((v >> 16) & 0xFF));
            outBuf.Add((int)((v >> 8) & 0xFF));
            outBuf.Add((int)(v & 0xFF));
        }

        private static void WriteU64Be(ByteBuf outBuf, ulong v)
        {
            for (int i = 7; i >= 0; i--)
            {
                outBuf.Add((int)((v >> (8 * i)) & 0xFF));
            }
        }
    }

    // -----------------------------------------------------------------------
    // Reader — streams elements back out
    // -----------------------------------------------------------------------

    public sealed class Reader
    {
        private readonly byte[] _buf;
        private int _pos;

        public Reader(byte[] buf)
        {
            _buf = buf;
            _pos = 0;
        }

        public Reader(byte[] buf, int pos)
        {
            _buf = buf;
            _pos = pos;
        }

        public bool Done => _pos >= _buf.Length;

        public Element? Next()
        {
            if (_pos >= _buf.Length) return null;
            int type = _buf[_pos++] & 0xFF;
            switch (type)
            {
                case Nil: return Element.MakeNil();
                case Undef: return Element.MakeUndef();
                case BoolFalse: return Element.MakeBool(false);
                case BoolTrue: return Element.MakeBool(true);
                case IntZero: return Element.MakeInt(BigInteger.Zero);
                case IntNegBig:
                case IntPosBig:
                    return ReadBigInt(type);
                case Float32: return Element.MakeF32(ReadF32());
                case Float64: return Element.MakeF64(ReadF64());
                case DecimalCode: return Element.MakeDecimal(ReadDecimal());
                case Timestamp:
                {
                    ulong raw = ReadU64Be(Take(8));
                    return Element.MakeTimestamp(unchecked((long)(raw ^ 0x8000000000000000ul)));
                }
                case Uuid: return Element.MakeUuid(Take(16));
                case String: return Element.MakeString(TakeFramedUnescaped());
                case Bytes: return Element.MakeBytes(TakeFramedUnescaped());
                case Array: return Element.MakeContainer(Kind.Array, TakeFramedUnescaped());
                case Map: return Element.MakeContainer(Kind.Map, TakeFramedUnescaped());
                case Set: return Element.MakeContainer(Kind.Set, TakeFramedUnescaped());
                default:
                    if ((type >= 0x10 && type <= 0x1F) || (type >= 0x21 && type <= 0x30))
                    {
                        return ReadFixedInt(type);
                    }
                    throw new StrupleException("invalid type code 0x" + type.ToString("x"));
            }
        }

        /// <summary>The type code of the next element without consuming it (-1 at end).</summary>
        public int PeekType => _pos < _buf.Length ? (_buf[_pos] & 0xFF) : -1;

        /// <summary>The remaining unread bytes (a valid struple stream).</summary>
        public byte[] Rest()
        {
            var outBuf = new byte[_buf.Length - _pos];
            System.Array.Copy(_buf, _pos, outBuf, 0, outBuf.Length);
            return outBuf;
        }

        /// <summary>The next element's raw bytes, advancing the cursor (null at end).</summary>
        public byte[]? NextView()
        {
            int start = _pos;
            if (Next() == null) return null;
            var outBuf = new byte[_pos - start];
            System.Array.Copy(_buf, start, outBuf, 0, outBuf.Length);
            return outBuf;
        }

        /// <summary>Advance past the next element; false at end of stream.</summary>
        public bool Skip() => NextView() != null;

        private Element ReadFixedInt(int type)
        {
            bool positive = type > IntZero;
            int n = positive ? type - IntZero : IntZero - type;
            byte[] payload = Take(n);
            // The widest (16-byte) slots can address values outside i128; reject non-canonical.
            if (n == 16 && ((positive && (payload[0] & 0xFF) >= 0x80)
                || (!positive && (payload[0] & 0xFF) < 0x80)))
            {
                throw new StrupleException("non-canonical 16-byte integer");
            }
            BigInteger raw = new BigInteger(payload, isUnsigned: true, isBigEndian: true);
            if (positive) return Element.MakeInt(raw);
            return Element.MakeInt(raw - (BigInteger.One << (8 * n)));
        }

        private Element ReadBigInt(int type)
        {
            bool negative = type == IntNegBig;
            int m = DecByte(Take(1)[0], negative);
            // Length-of-length is capped at 8 bytes: no real magnitude needs a length
            // that doesn't fit in u64, and without this bound `m` (0–255) lets the shift
            // below overflow and `n` address the whole address space. The take below then
            // rejects any n beyond the buffer cleanly.
            if (m > 8) throw new StrupleException("big-int length-of-length too large");
            byte[] mbytes = Take(m);
            // Assemble `n` as unsigned 64-bit (mirroring Zig's usize): a hostile length
            // stays a huge positive here rather than wrapping to a negative int32 (which
            // would slip past the guard and blow up at `new byte[n]` with OverflowException).
            ulong n = 0;
            foreach (byte b in mbytes)
            {
                n = (n << 8) | (byte)DecByte(b, negative);
            }
            // Guard as `n > remaining` so the huge length can't overflow; once it passes,
            // n fits an int (buffer length is an int) and the take is safe.
            if (n > (ulong)(_buf.Length - _pos)) throw new StrupleException("truncated");
            int nn = (int)n;
            byte[] stored = Take(nn);
            var mag = new byte[nn];
            for (int i = 0; i < nn; i++)
            {
                mag[i] = (byte)DecByte(stored[i], negative);
            }
            return Element.MakeBigInt(new BigIntValue(negative, mag));
        }

        private DecimalValue ReadDecimal()
        {
            int sign = Take(1)[0] & 0xFF;
            if (sign == DecSignZero) return new DecimalValue(false, 0, System.Array.Empty<byte>());
            if (sign != DecSignNeg && sign != DecSignPos) throw new StrupleException("invalid decimal sign");
            bool negative = sign == DecSignNeg;
            long adjExp = ReadDecExponent(negative);
            // Digit bytes are 1–100 (positive) or their complement (negative), and never collide
            // with the terminator (0x00, or 0xFF when complemented).
            int term = negative ? 0xFF : 0x00;
            int start = _pos;
            int i = _pos;
            while (i < _buf.Length && (_buf[i] & 0xFF) != term) i++;
            if (i >= _buf.Length) throw new StrupleException("truncated decimal");
            if (i == start) throw new StrupleException("nonzero decimal must carry digits");
            var coeffStored = new byte[i - start];
            for (int k = 0; k < coeffStored.Length; k++)
            {
                coeffStored[k] = (byte)DecByte(_buf[start + k], negative);
            }
            _pos = i + 1; // consume the terminator
            return new DecimalValue(negative, adjExp, coeffStored);
        }

        private long ReadDecExponent(bool complement)
        {
            int tb = DecByte(Take(1)[0], complement);
            if (tb == IntZero) return 0;
            if ((tb >= IntNegMin && tb <= IntNegMax) || (tb >= IntPosMin && tb <= IntPosMax))
            {
                bool positive = tb > IntZero;
                int n = positive ? tb - IntZero : IntZero - tb;
                byte[] raw = Take(n);
                var payload = new byte[n];
                for (int k = 0; k < n; k++)
                {
                    payload[k] = (byte)DecByte(raw[k], complement);
                }
                if (n == 16 && ((positive && (payload[0] & 0xFF) >= 0x80)
                    || (!positive && (payload[0] & 0xFF) < 0x80)))
                {
                    throw new StrupleException("non-canonical 16-byte decimal exponent");
                }
                BigInteger v = new BigInteger(payload, isUnsigned: true, isBigEndian: true);
                BigInteger value = positive ? v : v - (BigInteger.One << (8 * n));
                if (value < long.MinValue || value > long.MaxValue)
                {
                    throw new StrupleException("decimal exponent out of range");
                }
                return (long)value;
            }
            throw new StrupleException("invalid decimal exponent");
        }

        private float ReadF32()
        {
            uint bits = (uint)ReadU32Be(Take(4));
            bits = (bits & 0x80000000u) != 0 ? bits ^ 0x80000000u : ~bits;
            return BitConverter.Int32BitsToSingle(unchecked((int)bits));
        }

        private double ReadF64()
        {
            ulong bits = ReadU64Be(Take(8));
            bits = (bits & 0x8000000000000000ul) != 0 ? bits ^ 0x8000000000000000ul : ~bits;
            return BitConverter.Int64BitsToDouble(unchecked((long)bits));
        }

        private byte[] Take(int n)
        {
            // Guard written as `n > remaining` (never `pos + n > len`): the addition
            // would overflow for an attacker-supplied length before it could be
            // caught. `_pos <= _buf.Length` is a Reader invariant, so `_buf.Length - _pos`
            // never underflows.
            if (n > _buf.Length - _pos) throw new StrupleException("truncated");
            var slice = new byte[n];
            System.Array.Copy(_buf, _pos, slice, 0, n);
            _pos += n;
            return slice;
        }

        private byte[] TakeFramed()
        {
            int start = _pos;
            int i = _pos;
            while (i < _buf.Length)
            {
                if ((_buf[i] & 0xFF) == 0x00)
                {
                    if (i + 1 < _buf.Length && (_buf[i + 1] & 0xFF) == EscapeByte)
                    {
                        i += 2; // escaped literal 0x00
                        continue;
                    }
                    _pos = i + 1; // consume terminator
                    var outBuf = new byte[i - start];
                    System.Array.Copy(_buf, start, outBuf, 0, outBuf.Length);
                    return outBuf;
                }
                i++;
            }
            throw new StrupleException("truncated (unterminated framed value)");
        }

        private byte[] TakeFramedUnescaped() => Unescape(TakeFramed());

        private static ulong ReadU32Be(byte[] b)
        {
            ulong v = 0;
            foreach (byte x in b) v = (v << 8) | (x & 0xFFu);
            return v;
        }

        private static ulong ReadU64Be(byte[] b)
        {
            ulong v = 0;
            foreach (byte x in b) v = (v << 8) | (x & 0xFFu);
            return v;
        }
    }

    // -----------------------------------------------------------------------
    // Internal growable byte buffer
    // -----------------------------------------------------------------------

    internal sealed class ByteBuf
    {
        private byte[] _data = new byte[64];
        private int _len;

        public void Add(int b)
        {
            if (_len == _data.Length)
            {
                var grown = new byte[_data.Length * 2];
                System.Array.Copy(_data, grown, _len);
                _data = grown;
            }
            _data[_len++] = (byte)b;
        }

        public void AddAll(byte[] bs)
        {
            foreach (byte b in bs) Add(b & 0xFF);
        }

        public byte[] ToArray()
        {
            var outBuf = new byte[_len];
            System.Array.Copy(_data, outBuf, _len);
            return outBuf;
        }
    }

    /// <summary>Exception for malformed / truncated struple input.</summary>
    public sealed class StrupleException : Exception
    {
        public StrupleException(string message) : base("struple: " + message) { }
    }
}

using System;
using System.Numerics;

namespace Struple;

/// <summary>
/// Semantic (value-based) ordering over encoded struple streams.
///
/// <para><see cref="Struple.Compare"/> gives the raw <c>memcmp</c> order: the type byte dominates, so
/// an integer and a float never interleave by magnitude. <see cref="SemanticOrder"/> instead compares
/// by <em>value</em> — int, big-int, float32, float64 and decimal all compare by their exact
/// mathematical value, so <c>int 5 == float 5.0</c>, <c>int 2^53+1 &gt; float 2^53</c>, and
/// <c>decimal 0.1 &lt; float 0.1</c>, with no precision loss.</para>
///
/// <para>Cross-type order (when the two values aren't both numbers):</para>
///
/// <code>
///   nil &lt; undefined &lt; bool &lt; number &lt; timestamp &lt; uuid &lt; string &lt; bytes
///       &lt; array &lt; map &lt; set
/// </code>
///
/// <para>NaN sorts as the greatest number (above +inf); <c>-0.0 == 0.0 == int 0</c>. Containers
/// recurse element-wise; a shorter value sorts before a longer one that extends it.</para>
///
/// <para>The BCL has no exact decimal/rational big type, so each finite number is represented as an
/// exact rational (BigInteger numerator/denominator) and compared by cross-multiplication. A double's
/// exact value comes from its bits (mantissa·2^exp); a struple decimal is coefficient·10^exp.</para>
/// </summary>
public static class Semantic
{
    /// <summary>Compare two encoded streams element-by-element by semantic value (-1/0/1).</summary>
    public static int SemanticOrder(byte[] a, byte[] b) => SemanticOrderDepth(a, b, 0);

    // depth = 0 at the top-level stream, +1 per container descent; reject past MaxDepth so a
    // hostile deeply-nested encoding is rejected instead of overflowing the stack.
    private static int SemanticOrderDepth(byte[] a, byte[] b, int depth)
    {
        if (depth > Struple.MaxDepth) throw new Struple.StrupleException("nesting too deep");
        var ra = new Struple.Reader(a);
        var rb = new Struple.Reader(b);
        while (true)
        {
            var ea = ra.Next();
            var eb = rb.Next();
            if (ea == null && eb == null) return 0;
            if (ea == null) return -1; // a is a prefix of b
            if (eb == null) return 1;
            int c = CompareElements(ea, eb, depth);
            if (c != 0) return c;
        }
    }

    public static bool SemanticEqual(byte[] a, byte[] b) => SemanticOrder(a, b) == 0;

    private static int ClassRank(Struple.Kind k)
    {
        switch (k)
        {
            case Struple.Kind.Nil: return 0;
            case Struple.Kind.Undef: return 1;
            case Struple.Kind.Boolean: return 2;
            case Struple.Kind.Int:
            case Struple.Kind.BigIntKind:
            case Struple.Kind.Float32:
            case Struple.Kind.Float64:
            case Struple.Kind.Decimal:
                return 3; // unified "number" class
            case Struple.Kind.Timestamp: return 4;
            case Struple.Kind.Uuid: return 5;
            case Struple.Kind.String: return 6;
            case Struple.Kind.Bytes: return 7;
            case Struple.Kind.Array: return 8;
            case Struple.Kind.Map: return 9;
            case Struple.Kind.Set: return 10;
            default: throw new InvalidOperationException();
        }
    }

    private static int CompareElements(Struple.Element a, Struple.Element b, int depth)
    {
        int ra = ClassRank(a.Kind);
        int rb = ClassRank(b.Kind);
        if (ra != rb) return ra < rb ? -1 : 1;
        switch (a.Kind)
        {
            case Struple.Kind.Nil:
            case Struple.Kind.Undef:
                return 0;
            case Struple.Kind.Boolean:
                return CompareBool(a.BoolValue, b.BoolValue);
            case Struple.Kind.Int:
            case Struple.Kind.BigIntKind:
            case Struple.Kind.Float32:
            case Struple.Kind.Float64:
            case Struple.Kind.Decimal:
                return CompareNumbers(a, b);
            case Struple.Kind.Timestamp:
                return a.TimestampValue.CompareTo(b.TimestampValue);
            case Struple.Kind.Uuid:
                return Struple.Compare(a.UuidValue, b.UuidValue);
            case Struple.Kind.String:
                // string content order == UTF-8 byte order (StringBytes are the raw UTF-8 bytes)
                return Struple.Compare(a.StringBytes, b.StringBytes);
            case Struple.Kind.Bytes:
                return Struple.Compare(a.BytesValue, b.BytesValue);
            case Struple.Kind.Array:
            case Struple.Kind.Map:
            case Struple.Kind.Set:
                // a.Inner/b.Inner are already the un-escaped inner streams
                return SemanticOrderDepth(a.Inner, b.Inner, depth + 1);
            default:
                throw new InvalidOperationException();
        }
    }

    private static int CompareBool(bool a, bool b) => (a ? 1 : 0).CompareTo(b ? 1 : 0);

    // -----------------------------------------------------------------------
    // Numbers
    // -----------------------------------------------------------------------

    // Rank within the number class: -inf < finite < +inf < NaN. Ints and decimals are finite.
    private static int NumClass(Struple.Element e)
    {
        double f;
        switch (e.Kind)
        {
            case Struple.Kind.Int:
            case Struple.Kind.BigIntKind:
            case Struple.Kind.Decimal:
                return 1;
            case Struple.Kind.Float32:
                f = e.Float32Value;
                break;
            case Struple.Kind.Float64:
                f = e.Float64Value;
                break;
            default:
                throw new InvalidOperationException();
        }
        if (double.IsNaN(f)) return 3;
        if (double.IsPositiveInfinity(f)) return 2;
        if (double.IsNegativeInfinity(f)) return 0;
        return 1;
    }

    private static int CompareNumbers(Struple.Element a, Struple.Element b)
    {
        int ca = NumClass(a);
        int cb = NumClass(b);
        if (ca != cb) return ca < cb ? -1 : 1;
        if (ca != 1) return 0; // both -inf, both +inf, or both NaN
        // Both finite. A decimal on either side can carry an i32-sized exponent, so route it
        // through the order-of-magnitude short-circuit (Item 2) rather than materializing
        // 10^exp. Int/big-int/float never scale by a base-10 exponent, so they stay on the
        // exact-rational path (a double's 2^exp shift is bounded to [-1074, 1024]).
        if (a.Kind == Struple.Kind.Decimal || b.Kind == Struple.Kind.Decimal)
        {
            return CompareWithDecimal(a, b);
        }
        Rational va = ToRational(a);
        Rational vb = ToRational(b);
        return va.CompareTo(vb);
    }

    /// <summary>
    /// The exact value of a finite non-decimal number element as a rational (numerator /
    /// denominator, with a positive denominator).
    /// </summary>
    private static Rational ToRational(Struple.Element e)
    {
        switch (e.Kind)
        {
            case Struple.Kind.Int:
                return new Rational(e.IntValue, BigInteger.One);
            case Struple.Kind.BigIntKind:
                return new Rational(e.IntValue, BigInteger.One);
            case Struple.Kind.Float32:
                return DoubleToRational(e.Float32Value);
            case Struple.Kind.Float64:
                return DoubleToRational(e.Float64Value);
            default:
                throw new InvalidOperationException();
        }
    }

    // -----------------------------------------------------------------------
    // Decimal vs the rest of the number class — base-10 order-of-magnitude
    // short-circuit (Item 2). Before scaling/materializing a magnitude by an
    // i32-sized exponent, compare the operands' base-10 orders of magnitude;
    // build the exact value only when those bounds overlap (then the exponents
    // are close, so it is cheap).
    // -----------------------------------------------------------------------

    /// <summary>An exact base-10 value <c>sign · mag · 10^exp10</c> (mag big-endian, non-negative;
    /// empty mag == 0).</summary>
    private readonly struct B10
    {
        public readonly int Sign;
        public readonly byte[] Mag; // big-endian, leading zeros trimmed
        public readonly long Exp10;

        public B10(int sign, byte[] mag, long exp10)
        {
            Sign = sign;
            Mag = mag;
            Exp10 = exp10;
        }
    }

    private static bool IsExactKind(Struple.Element e) =>
        e.Kind == Struple.Kind.Int || e.Kind == Struple.Kind.BigIntKind || e.Kind == Struple.Kind.Decimal;

    private static double FloatVal(Struple.Element e) =>
        e.Kind == Struple.Kind.Float32 ? e.Float32Value : e.Float64Value;

    /// <summary>Decompose an int / big-int / decimal into its exact base-10 value.</summary>
    private static B10 NumToB10(Struple.Element e)
    {
        switch (e.Kind)
        {
            case Struple.Kind.Int:
            case Struple.Kind.BigIntKind:
            {
                BigInteger v = e.IntValue;
                if (v.Sign == 0) return new B10(0, System.Array.Empty<byte>(), 0);
                return new B10(v.Sign, Struple.MagnitudeBytes(BigInteger.Abs(v)), 0);
            }
            case Struple.Kind.Decimal:
            {
                var d = e.Decimal!;
                if (d.IsZero) return new B10(0, System.Array.Empty<byte>(), 0);
                BigInteger coeff = BigInteger.Abs(d.Coefficient());
                return new B10(d.Negative ? -1 : 1, Struple.MagnitudeBytes(coeff), d.Exponent());
            }
            default:
                throw new InvalidOperationException();
        }
    }

    private static int CompareWithDecimal(Struple.Element a, Struple.Element b)
    {
        if (IsExactKind(a) && IsExactKind(b))
        {
            B10 va = NumToB10(a);
            B10 vb = NumToB10(b);
            if (va.Sign != vb.Sign) return va.Sign.CompareTo(vb.Sign);
            if (va.Sign == 0) return 0;
            int c = CompareB10Mag(va, vb);
            return va.Sign < 0 ? -c : c;
        }
        // exactly one side is a finite float
        if (IsExactKind(a))
        {
            return CompareB10Float(NumToB10(a), FloatVal(b));
        }
        return -CompareB10Float(NumToB10(b), FloatVal(a));
    }

    /// <summary>
    /// Bounds on the base-10 order of magnitude of a nonzero <c>mag · 10^exp10</c>: returns
    /// <c>(lo, hi)</c> with <c>|value| ∈ [10^lo, 10^hi)</c>. Uses byte-length bounds on the
    /// base-256 magnitude (<c>256^(n-1) ≥ 10^(2(n-1))</c>, <c>256^n &lt; 10^(3n)</c>). Lets the
    /// comparators reject a far-apart pair without materializing a magnitude scaled by an
    /// i32-sized exponent.
    /// </summary>
    private static (long lo, long hi) B10OomBounds(B10 v)
    {
        long na = v.Mag.Length; // ≥ 1 for a nonzero value (MagnitudeBytes trims leading zeros)
        return (v.Exp10 + 2 * na - 2, v.Exp10 + 3 * na);
    }

    /// <summary>Compare two same-sign, nonzero base-10 magnitudes (<c>mag · 10^exp10</c>).</summary>
    private static int CompareB10Mag(B10 a, B10 b)
    {
        // If the orders of magnitude are disjoint, decide by them — no scaling. When they
        // overlap, |a.Exp10 − b.Exp10| is bounded by the digit counts, so the exact scaling
        // below is cheap (never proportional to the raw exponent).
        var ba = B10OomBounds(a);
        var bb = B10OomBounds(b);
        if (ba.hi <= bb.lo) return -1;
        if (bb.hi <= ba.lo) return 1;
        long e = System.Math.Min(a.Exp10, b.Exp10);
        BigInteger sa = MagValue(a.Mag) * BigInteger.Pow(10, (int)(a.Exp10 - e));
        BigInteger sb = MagValue(b.Mag) * BigInteger.Pow(10, (int)(b.Exp10 - e));
        return sa.CompareTo(sb);
    }

    private static int CompareB10Float(B10 v, double f)
    {
        int sf = SignRank(f);
        if (v.Sign != sf) return v.Sign.CompareTo(sf);
        if (v.Sign == 0) return 0; // both zero
        // Any finite nonzero f64 has |f| ∈ (10^-324, 10^309). If the exact value's order of
        // magnitude is clear of that window, decide without scaling — this is what stops a huge
        // decimal exponent from driving a 2^31-digit materialization (Item 2). When the bounds
        // overlap the window, v.Exp10 is bounded by it, so the exact path's 10^exp is cheap.
        var bnd = B10OomBounds(v);
        int c;
        if (bnd.lo >= 310) c = 1;        // decimal magnitude exceeds any finite f64
        else if (bnd.hi <= -325) c = -1; // decimal magnitude below any finite nonzero f64
        else c = ExactB10MagVsFloat(v, System.Math.Abs(f));
        return v.Sign < 0 ? -c : c;
    }

    /// <summary>Compare <c>|mag · 10^exp10|</c> to <c>g = |f|</c> (> 0) exactly. Only reached when
    /// exp10 is bounded to the f64 order-of-magnitude window, so <c>10^|exp10|</c> is cheap.</summary>
    private static int ExactB10MagVsFloat(B10 v, double g)
    {
        BigInteger mag = MagValue(v.Mag);
        Rational rv = v.Exp10 >= 0
            ? new Rational(mag * BigInteger.Pow(10, (int)v.Exp10), BigInteger.One)
            : new Rational(mag, BigInteger.Pow(10, (int)(-v.Exp10)));
        Rational rf = DoubleToRational(g);
        return rv.CompareTo(rf);
    }

    private static BigInteger MagValue(byte[] mag) =>
        mag.Length == 0 ? BigInteger.Zero : new BigInteger(mag, isUnsigned: true, isBigEndian: true);

    private static int SignRank(double f)
    {
        if (f > 0) return 1;
        if (f < 0) return -1;
        return 0; // ±0.0
    }

    /// <summary>A finite double's exact value (mantissa·2^exp) as an exact rational.</summary>
    private static Rational DoubleToRational(double value)
    {
        if (value == 0.0) return new Rational(BigInteger.Zero, BigInteger.One);
        long bits = BitConverter.DoubleToInt64Bits(value);
        bool negative = bits < 0;
        int rawExp = (int)((bits >> 52) & 0x7FF);
        long frac = bits & 0xFFFFFFFFFFFFFL;
        BigInteger mantissa;
        int exp;
        if (rawExp == 0)
        {
            // subnormal: value = frac · 2^-1074
            mantissa = new BigInteger(frac);
            exp = -1074;
        }
        else
        {
            // normal: value = (2^52 | frac) · 2^(rawExp - 1075)
            mantissa = new BigInteger((1L << 52) | frac);
            exp = rawExp - 1075;
        }
        if (negative) mantissa = -mantissa;
        if (exp >= 0)
        {
            return new Rational(mantissa * (BigInteger.One << exp), BigInteger.One);
        }
        return new Rational(mantissa, BigInteger.One << (-exp));
    }

    /// <summary>An exact rational with a strictly positive denominator (not reduced — compared by cross-multiply).</summary>
    private readonly struct Rational
    {
        public readonly BigInteger Num;
        public readonly BigInteger Den; // > 0

        public Rational(BigInteger num, BigInteger den)
        {
            // den is always passed > 0 here (constructed from 10^k / 2^k).
            Num = num;
            Den = den;
        }

        // a/b vs c/d (b, d > 0)  ==  a·d vs c·b
        public int CompareTo(Rational other)
        {
            BigInteger left = Num * other.Den;
            BigInteger right = other.Num * Den;
            return left.CompareTo(right);
        }
    }
}

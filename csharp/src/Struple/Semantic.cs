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
    public static int SemanticOrder(byte[] a, byte[] b)
    {
        var ra = new Struple.Reader(a);
        var rb = new Struple.Reader(b);
        while (true)
        {
            var ea = ra.Next();
            var eb = rb.Next();
            if (ea == null && eb == null) return 0;
            if (ea == null) return -1; // a is a prefix of b
            if (eb == null) return 1;
            int c = CompareElements(ea, eb);
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

    private static int CompareElements(Struple.Element a, Struple.Element b)
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
                return SemanticOrder(a.Inner, b.Inner);
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
        // Both finite; compare exact rational values.
        Rational va = ToRational(a);
        Rational vb = ToRational(b);
        return va.CompareTo(vb);
    }

    /// <summary>
    /// The exact value of a finite number element as a rational (numerator / denominator, with a
    /// positive denominator).
    /// </summary>
    private static Rational ToRational(Struple.Element e)
    {
        switch (e.Kind)
        {
            case Struple.Kind.Int:
                return new Rational(e.IntValue, BigInteger.One);
            case Struple.Kind.BigIntKind:
                return new Rational(e.IntValue, BigInteger.One);
            case Struple.Kind.Decimal:
                return DecimalToRational(e.Decimal!);
            case Struple.Kind.Float32:
                return DoubleToRational(e.Float32Value);
            case Struple.Kind.Float64:
                return DoubleToRational(e.Float64Value);
            default:
                throw new InvalidOperationException();
        }
    }

    /// <summary>A struple decimal coefficient·10^exp as an exact rational.</summary>
    private static Rational DecimalToRational(Struple.DecimalValue d)
    {
        if (d.IsZero) return new Rational(BigInteger.Zero, BigInteger.One);
        BigInteger coeff = d.Coefficient(); // sign-applied
        long exp = d.Exponent();
        if (exp >= 0)
        {
            return new Rational(coeff * BigInteger.Pow(10, (int)exp), BigInteger.One);
        }
        return new Rational(coeff, BigInteger.Pow(10, (int)(-exp)));
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

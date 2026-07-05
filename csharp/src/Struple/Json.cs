using System;
using System.Collections.Generic;
using System.Numerics;
using System.Text;

namespace Struple;

/// <summary>
/// JSON &lt;-&gt; struple conversion, mirroring the reference.
///
/// <code>
///   FromJson: JSON text     -&gt; struple encoding (one element for the root value)
///   ToJson:   struple bytes -&gt; canonical JSON text (renders the first element)
/// </code>
///
/// <para>JSON integers stay at arbitrary precision (a big integer a JS f64 would corrupt round-trips
/// losslessly); fractional/exponent numbers become float64; objects encode to canonical (key-sorted)
/// maps. The ToJson text is byte-identical to the shared corpus. A tiny recursive-descent parser +
/// serializer is hand-rolled here (BCL-only, no System.Text.Json) so number tokens keep full
/// precision.</para>
/// </summary>
public static class Json
{
    /// <summary>Parse JSON text and return its struple encoding.</summary>
    public static byte[] FromJson(string json)
    {
        var p = new Parser(json);
        object? root = p.ParseValue(0);
        p.SkipWs();
        if (!p.AtEnd()) throw new Struple.StrupleException("trailing JSON content");
        var outP = new Struple.Packer();
        EncodeValue(outP, root);
        return outP.Bytes();
    }

    /// <summary>
    /// Parse arbitrary JSON text into the generic value model (null / bool / BigInteger / double /
    /// string / List&lt;object&gt; / JsonObject). Integer-valued number tokens become BigInteger
    /// (lossless); fractional/exponent tokens become double. Exposed so the conformance runner can
    /// read the corpus with no dependencies.
    /// </summary>
    public static object? Parse(string json)
    {
        var p = new Parser(json);
        object? root = p.ParseValue(0);
        p.SkipWs();
        if (!p.AtEnd()) throw new Struple.StrupleException("trailing JSON content");
        return root;
    }

    /// <summary>Render a struple encoding's first element as canonical JSON text.</summary>
    public static string ToJson(byte[] encoded)
    {
        var e = new Struple.Reader(encoded).Next();
        if (e == null) return "null";
        var sb = new StringBuilder();
        RenderElement(sb, e, 0);
        return sb.ToString();
    }

    // -----------------------------------------------------------------------
    // JSON -> struple
    // -----------------------------------------------------------------------

    private static void EncodeValue(Struple.Packer outP, object? value)
    {
        switch (value)
        {
            case null:
                outP.AppendNil();
                break;
            case bool b:
                outP.AppendBool(b);
                break;
            case BigInteger i:
                outP.AppendBigInteger(i);
                break;
            case double d:
                outP.AppendFloat64(d);
                break;
            case string s:
                outP.AppendString(s);
                break;
            case List<object?> arr:
            {
                var child = new Struple.Packer();
                foreach (var item in arr) EncodeValue(child, item);
                outP.AppendArray(child.Bytes());
                break;
            }
            case JsonObject obj:
            {
                var entries = new List<byte[][]>();
                for (int k = 0; k < obj.Keys.Count; k++)
                {
                    var kp = new Struple.Packer();
                    kp.AppendString(obj.Keys[k]);
                    var vp = new Struple.Packer();
                    EncodeValue(vp, obj.Values[k]);
                    entries.Add(new[] { kp.Bytes(), vp.Bytes() });
                }
                outP.AppendMap(entries);
                break;
            }
            default:
                throw new Struple.StrupleException("cannot encode JSON value " + value.GetType());
        }
    }

    // -----------------------------------------------------------------------
    // struple -> JSON
    // -----------------------------------------------------------------------

    // depth = 0 at the top-level element, +1 per container descent; reject past MaxDepth so a
    // hostile deeply-nested encoding is rejected instead of overflowing the stack.
    private static void RenderElement(StringBuilder sb, Struple.Element e, int depth)
    {
        if (depth > Struple.MaxDepth) throw new Struple.StrupleException("JSON nesting too deep");
        switch (e.Kind)
        {
            case Struple.Kind.Nil:
            case Struple.Kind.Undef:
                sb.Append("null");
                return;
            case Struple.Kind.Boolean:
                sb.Append(e.BoolValue ? "true" : "false");
                return;
            case Struple.Kind.Int:
            case Struple.Kind.BigIntKind:
                sb.Append(e.IntValue.ToString());
                return;
            case Struple.Kind.Float32:
                sb.Append(FormatNumber((double)e.Float32Value));
                return;
            case Struple.Kind.Float64:
                sb.Append(FormatNumber(e.Float64Value));
                return;
            case Struple.Kind.Decimal:
                RenderDecimal(sb, e.Decimal!);
                return;
            case Struple.Kind.Timestamp:
                sb.Append(e.TimestampValue.ToString());
                return;
            case Struple.Kind.Uuid:
                WriteQuoted(sb, ToUuidString(e.UuidValue));
                return;
            case Struple.Kind.String:
                WriteQuoted(sb, e.StringValue);
                return;
            case Struple.Kind.Bytes:
                WriteQuoted(sb, Base64(e.BytesValue));
                return;
            case Struple.Kind.Array:
            case Struple.Kind.Set:
                RenderArray(sb, e.Inner, depth);
                return;
            case Struple.Kind.Map:
                RenderMap(sb, e.Inner, depth);
                return;
            default:
                throw new InvalidOperationException();
        }
    }

    private static string FormatNumber(double v)
    {
        if (!double.IsFinite(v)) return "null"; // JSON has no inf/nan
        return DoubleFormat.ToStr(v);
    }

    private static void RenderArray(StringBuilder sb, byte[] body, int depth)
    {
        var r = new Struple.Reader(body);
        sb.Append('[');
        bool first = true;
        Struple.Element? e;
        while ((e = r.Next()) != null)
        {
            if (!first) sb.Append(',');
            first = false;
            RenderElement(sb, e, depth + 1);
        }
        sb.Append(']');
    }

    private static void RenderMap(StringBuilder sb, byte[] body, int depth)
    {
        var r = new Struple.Reader(body);
        sb.Append('{');
        bool first = true;
        Struple.Element? k;
        while ((k = r.Next()) != null)
        {
            var v = r.Next();
            if (v == null) throw new Struple.StrupleException("malformed map");
            if (!first) sb.Append(',');
            first = false;
            if (k.Kind == Struple.Kind.String)
            {
                WriteQuoted(sb, k.StringValue);
            }
            else
            {
                // Non-string key: render its JSON, then quote the result.
                var tmp = new StringBuilder();
                RenderElement(tmp, k, depth + 1);
                WriteQuoted(sb, tmp.ToString());
            }
            sb.Append(':');
            RenderElement(sb, v, depth + 1);
        }
        sb.Append('}');
    }

    /// <summary>Render a decimal as an exact JSON number literal (plain notation, no exponent).</summary>
    private static void RenderDecimal(StringBuilder sb, Struple.DecimalValue d)
    {
        if (d.IsZero)
        {
            sb.Append('0');
            return;
        }
        int[] digs = d.CoefficientDigits();
        int k = digs.Length;
        long exp10 = d.Exponent();
        if (d.Negative) sb.Append('-');

        // Plain notation would pad this many zeros; past the threshold, render in scientific
        // notation so a huge (i32-bounded) exponent can't emit gigabytes (Item 2).
        const long maxPlainPad = 40;
        long pad = exp10 >= 0 ? exp10 : (k + exp10 > 0 ? 0 : -(k + exp10));
        if (pad > maxPlainPad)
        {
            // d1[.d2…dk]e±E, where E = exp10 + k − 1 (the power of ten of the MSD).
            sb.Append((char)('0' + digs[0]));
            if (digs.Length > 1)
            {
                sb.Append('.');
                for (int i = 1; i < digs.Length; i++) sb.Append((char)('0' + digs[i]));
            }
            long sciExp = exp10 + k - 1;
            sb.Append('e');
            sb.Append(sciExp >= 0 ? '+' : '-');
            sb.Append(System.Math.Abs(sciExp).ToString(System.Globalization.CultureInfo.InvariantCulture));
            return;
        }

        if (exp10 >= 0)
        {
            foreach (int dd in digs) sb.Append((char)('0' + dd));
            for (long z = 0; z < exp10; z++) sb.Append('0');
            return;
        }
        long pointPos = k + exp10; // number of integer-part digits
        if (pointPos > 0)
        {
            int pp = (int)pointPos;
            for (int i = 0; i < pp; i++) sb.Append((char)('0' + digs[i]));
            sb.Append('.');
            for (int i = pp; i < k; i++) sb.Append((char)('0' + digs[i]));
        }
        else
        {
            sb.Append("0.");
            for (long z = pointPos; z < 0; z++) sb.Append('0');
            foreach (int dd in digs) sb.Append((char)('0' + dd));
        }
    }

    private static void WriteQuoted(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    private static string ToUuidString(byte[] u)
    {
        var sb = new StringBuilder(36);
        for (int i = 0; i < 16; i++)
        {
            if (i == 4 || i == 6 || i == 8 || i == 10) sb.Append('-');
            sb.Append(HexDigit((u[i] >> 4) & 0xF));
            sb.Append(HexDigit(u[i] & 0xF));
        }
        return sb.ToString();
    }

    private static char HexDigit(int v) => (char)(v < 10 ? '0' + v : 'a' + (v - 10));

    private static readonly char[] B64 =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".ToCharArray();

    private static string Base64(byte[] data)
    {
        var sb = new StringBuilder();
        int i = 0;
        while (i + 3 <= data.Length)
        {
            int n = ((data[i] & 0xFF) << 16) | ((data[i + 1] & 0xFF) << 8) | (data[i + 2] & 0xFF);
            sb.Append(B64[(n >> 18) & 0x3F]).Append(B64[(n >> 12) & 0x3F]);
            sb.Append(B64[(n >> 6) & 0x3F]).Append(B64[n & 0x3F]);
            i += 3;
        }
        int rem = data.Length - i;
        if (rem == 1)
        {
            int n = (data[i] & 0xFF) << 16;
            sb.Append(B64[(n >> 18) & 0x3F]).Append(B64[(n >> 12) & 0x3F]).Append("==");
        }
        else if (rem == 2)
        {
            int n = ((data[i] & 0xFF) << 16) | ((data[i + 1] & 0xFF) << 8);
            sb.Append(B64[(n >> 18) & 0x3F]).Append(B64[(n >> 12) & 0x3F]);
            sb.Append(B64[(n >> 6) & 0x3F]).Append('=');
        }
        return sb.ToString();
    }

    // -----------------------------------------------------------------------
    // Hand-rolled JSON parser
    // -----------------------------------------------------------------------

    /// <summary>Preserves object key order so non-canonical input round-trips through the canonical encoder.</summary>
    public sealed class JsonObject
    {
        public readonly List<string> Keys = new();
        public readonly List<object?> Values = new();

        /// <summary>The value for <c>key</c>, or null if absent.</summary>
        public object? Get(string key)
        {
            int idx = Keys.IndexOf(key);
            return idx >= 0 ? Values[idx] : null;
        }

        public bool Has(string key) => Keys.Contains(key);
    }

    private sealed class Parser
    {
        private readonly string _s;
        private int _i;

        public Parser(string s)
        {
            _s = s;
            _i = 0;
        }

        public bool AtEnd() => _i >= _s.Length;

        public void SkipWs()
        {
            while (_i < _s.Length)
            {
                char c = _s[_i];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') _i++;
                else break;
            }
        }

        // depth = 0 at the top-level value, +1 per container descent; reject past MaxDepth so a
        // hostile deeply-nested document is rejected here instead of overflowing the stack.
        public object? ParseValue(int depth)
        {
            if (depth > Struple.MaxDepth) throw new Struple.StrupleException("JSON nesting too deep");
            SkipWs();
            if (_i >= _s.Length) throw new Struple.StrupleException("unexpected end of JSON");
            char c = _s[_i];
            switch (c)
            {
                case '{': return ParseObject(depth);
                case '[': return ParseArray(depth);
                case '"': return ParseString();
                case 't': Expect("true"); return true;
                case 'f': Expect("false"); return false;
                case 'n': Expect("null"); return null;
                default: return ParseNumber();
            }
        }

        private void Expect(string lit)
        {
            if (_i + lit.Length > _s.Length
                || string.CompareOrdinal(_s, _i, lit, 0, lit.Length) != 0)
            {
                throw new Struple.StrupleException("invalid JSON literal");
            }
            _i += lit.Length;
        }

        private JsonObject ParseObject(int depth)
        {
            var obj = new JsonObject();
            _i++; // '{'
            SkipWs();
            if (_i < _s.Length && _s[_i] == '}')
            {
                _i++;
                return obj;
            }
            while (true)
            {
                SkipWs();
                if (_i >= _s.Length || _s[_i] != '"') throw new Struple.StrupleException("expected object key");
                string key = ParseString();
                SkipWs();
                if (_i >= _s.Length || _s[_i] != ':') throw new Struple.StrupleException("expected ':'");
                _i++;
                object? value = ParseValue(depth + 1);
                obj.Keys.Add(key);
                obj.Values.Add(value);
                SkipWs();
                if (_i >= _s.Length) throw new Struple.StrupleException("unterminated object");
                char c = _s[_i++];
                if (c == '}') break;
                if (c != ',') throw new Struple.StrupleException("expected ',' or '}'");
            }
            return obj;
        }

        private List<object?> ParseArray(int depth)
        {
            var arr = new List<object?>();
            _i++; // '['
            SkipWs();
            if (_i < _s.Length && _s[_i] == ']')
            {
                _i++;
                return arr;
            }
            while (true)
            {
                arr.Add(ParseValue(depth + 1));
                SkipWs();
                if (_i >= _s.Length) throw new Struple.StrupleException("unterminated array");
                char c = _s[_i++];
                if (c == ']') break;
                if (c != ',') throw new Struple.StrupleException("expected ',' or ']'");
            }
            return arr;
        }

        private string ParseString()
        {
            _i++; // opening quote
            var sb = new StringBuilder();
            while (_i < _s.Length)
            {
                char c = _s[_i++];
                if (c == '"') return sb.ToString();
                if (c == '\\')
                {
                    if (_i >= _s.Length) break;
                    char esc = _s[_i++];
                    switch (esc)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (_i + 4 > _s.Length) throw new Struple.StrupleException("bad unicode escape");
                            int cp = Convert.ToInt32(_s.Substring(_i, 4), 16);
                            _i += 4;
                            sb.Append((char)cp);
                            break;
                        default:
                            throw new Struple.StrupleException("bad string escape");
                    }
                }
                else
                {
                    sb.Append(c);
                }
            }
            throw new Struple.StrupleException("unterminated string");
        }

        /// <summary>Parse a number token: integer-valued -&gt; BigInteger; fractional/exponent -&gt; double.</summary>
        private object ParseNumber()
        {
            int start = _i;
            if (_i < _s.Length && _s[_i] == '-') _i++;
            while (_i < _s.Length && IsDigit(_s[_i])) _i++;
            bool isFloat = false;
            if (_i < _s.Length && _s[_i] == '.')
            {
                isFloat = true;
                _i++;
                while (_i < _s.Length && IsDigit(_s[_i])) _i++;
            }
            if (_i < _s.Length && (_s[_i] == 'e' || _s[_i] == 'E'))
            {
                isFloat = true;
                _i++;
                if (_i < _s.Length && (_s[_i] == '+' || _s[_i] == '-')) _i++;
                while (_i < _s.Length && IsDigit(_s[_i])) _i++;
            }
            string tok = _s.Substring(start, _i - start);
            if (tok.Length == 0 || tok == "-") throw new Struple.StrupleException("invalid number");
            if (isFloat)
            {
                return double.Parse(tok, System.Globalization.CultureInfo.InvariantCulture);
            }
            return BigInteger.Parse(tok, System.Globalization.CultureInfo.InvariantCulture);
        }

        private static bool IsDigit(char c) => c >= '0' && c <= '9';
    }

    // -----------------------------------------------------------------------
    // Shortest round-trip double formatting, JS/Zig {d}-style (no trailing ".0",
    // plain decimal where reasonable). Matches the corpus float text exactly.
    // -----------------------------------------------------------------------

    internal static class DoubleFormat
    {
        public static string ToStr(double v)
        {
            if (v == 0.0) return "0";
            bool neg = v < 0;
            double av = System.Math.Abs(v);

            // .NET's "R"/default ToString gives the shortest round-trip digit string. Normalize to
            // ECMAScript Number#toString plain/exponential form, which the corpus uses.
            // Use round-trippable "R" then re-extract digits + decimal exponent.
            string repr = av.ToString("R", System.Globalization.CultureInfo.InvariantCulture);
            ParseSci(repr, out string digits, out int pointExp);

            string outStr;
            // ECMAScript Number::toString plain vs exponential by the 21 / -6 rule.
            if (pointExp >= -5 && pointExp <= 21)
            {
                outStr = Plain(digits, pointExp);
            }
            else
            {
                outStr = Exponential(digits, pointExp);
            }
            return neg ? "-" + outStr : outStr;
        }

        // Decompose a positive shortest-form decimal string (possibly with 'E') into the minimal
        // significant digit string and pointExp = number of digits before the decimal point.
        private static void ParseSci(string repr, out string digits, out int pointExp)
        {
            int e = 0;
            int eIdx = repr.IndexOfAny(new[] { 'e', 'E' });
            string mant = repr;
            if (eIdx >= 0)
            {
                mant = repr.Substring(0, eIdx);
                e = int.Parse(repr.Substring(eIdx + 1), System.Globalization.CultureInfo.InvariantCulture);
            }
            int dot = mant.IndexOf('.');
            string intPart, fracPart;
            if (dot >= 0)
            {
                intPart = mant.Substring(0, dot);
                fracPart = mant.Substring(dot + 1);
            }
            else
            {
                intPart = mant;
                fracPart = "";
            }
            // all significant digits, then strip leading/trailing zeros tracking the exponent.
            string allDigits = intPart + fracPart;
            // pointExp for "intPart.fracPart × 10^e" with no leading-zero adjustment yet:
            int rawPointExp = intPart.Length + e;

            // strip leading zeros (each shifts pointExp down by 1)
            int lead = 0;
            while (lead < allDigits.Length - 1 && allDigits[lead] == '0')
            {
                lead++;
                rawPointExp--;
            }
            allDigits = allDigits.Substring(lead);
            // strip trailing zeros (do not affect pointExp)
            int end = allDigits.Length;
            while (end > 1 && allDigits[end - 1] == '0') end--;
            allDigits = allDigits.Substring(0, end);
            // a single "0" digit collapses (caller never passes 0 here, but guard)
            if (allDigits == "0")
            {
                digits = "0";
                pointExp = 1;
                return;
            }
            digits = allDigits;
            pointExp = rawPointExp;
        }

        // value = D · 10^(pointExp - k), where D = digits string (length k).
        private static string Plain(string digits, int pointExp)
        {
            int k = digits.Length;
            if (pointExp <= 0)
            {
                var sb = new StringBuilder("0.");
                for (int i = 0; i < -pointExp; i++) sb.Append('0');
                sb.Append(digits);
                return sb.ToString();
            }
            if (pointExp >= k)
            {
                var sb = new StringBuilder(digits);
                for (int i = 0; i < pointExp - k; i++) sb.Append('0');
                return sb.ToString();
            }
            return digits.Substring(0, pointExp) + "." + digits.Substring(pointExp);
        }

        private static string Exponential(string digits, int pointExp)
        {
            int e = pointExp - 1; // exponent for d.ddd form
            var sb = new StringBuilder();
            sb.Append(digits[0]);
            if (digits.Length > 1) sb.Append('.').Append(digits.Substring(1));
            sb.Append('e');
            if (e >= 0)
            {
                sb.Append('+');
            }
            else
            {
                sb.Append('-');
                e = -e;
            }
            sb.Append(e);
            return sb.ToString();
        }
    }
}

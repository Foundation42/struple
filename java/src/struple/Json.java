package struple;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import struple.Struple.Element;
import struple.Struple.Packer;
import struple.Struple.Reader;

/**
 * JSON &lt;-&gt; struple conversion, mirroring the reference.
 *
 * <pre>
 *   fromJson: JSON text     -&gt; struple encoding (one element for the root value)
 *   toJson:   struple bytes -&gt; canonical JSON text (renders the first element)
 * </pre>
 *
 * <p>JSON integers stay at arbitrary precision (a big integer a JS f64 would corrupt round-trips
 * losslessly); fractional/exponent numbers become float64; objects encode to canonical (key-sorted)
 * maps. The toJson text is byte-identical to the shared corpus. Java has no stdlib JSON, so a tiny
 * recursive-descent parser + serializer is hand-rolled here (zero dependencies).
 */
public final class Json {

    private Json() {}

    /** Parse JSON text and return its struple encoding. */
    public static byte[] fromJson(String json) {
        Parser p = new Parser(json);
        Object root = p.parseValue(0);
        p.skipWs();
        if (!p.atEnd()) {
            throw new Struple.StrupleException("trailing JSON content");
        }
        Packer out = new Packer();
        encodeValue(out, root);
        return out.bytes();
    }

    /**
     * Parse arbitrary JSON text into the generic value model (null / {@link Boolean} /
     * {@link BigInteger} / {@link Double} / {@link String} / {@link List} / {@link JsonObject}).
     * Integer-valued number tokens become {@link BigInteger} (lossless); fractional/exponent tokens
     * become {@link Double}. Exposed so the conformance runner can read the corpus with no
     * dependencies.
     */
    public static Object parse(String json) {
        Parser p = new Parser(json);
        Object root = p.parseValue(0);
        p.skipWs();
        if (!p.atEnd()) {
            throw new Struple.StrupleException("trailing JSON content");
        }
        return root;
    }

    /** Render a struple encoding's first element as canonical JSON text. */
    public static String toJson(byte[] encoded) {
        Element e = new Reader(encoded).next();
        if (e == null) {
            return "null";
        }
        StringBuilder sb = new StringBuilder();
        renderElement(sb, e, 0);
        return sb.toString();
    }

    // -----------------------------------------------------------------------
    // JSON -> struple
    // -----------------------------------------------------------------------

    private static void encodeValue(Packer out, Object value) {
        if (value == null) {
            out.appendNil();
        } else if (value instanceof Boolean b) {
            out.appendBool(b);
        } else if (value instanceof BigInteger i) {
            out.appendBigInteger(i);
        } else if (value instanceof Double d) {
            out.appendFloat64(d);
        } else if (value instanceof String s) {
            out.appendString(s);
        } else if (value instanceof List<?> arr) {
            Packer child = new Packer();
            for (Object item : arr) {
                encodeValue(child, item);
            }
            out.appendArray(child.bytes());
        } else if (value instanceof JsonObject obj) {
            List<byte[][]> entries = new ArrayList<>();
            for (int i = 0; i < obj.keys.size(); i++) {
                Packer kp = new Packer();
                kp.appendString(obj.keys.get(i));
                Packer vp = new Packer();
                encodeValue(vp, obj.values.get(i));
                entries.add(new byte[][] {kp.bytes(), vp.bytes()});
            }
            out.appendMap(entries);
        } else {
            throw new Struple.StrupleException("cannot encode JSON value " + value.getClass());
        }
    }

    // -----------------------------------------------------------------------
    // struple -> JSON
    // -----------------------------------------------------------------------

    private static void renderElement(StringBuilder sb, Element e, int depth) {
        // Bound recursion into nested containers so hostile deeply-nested input is rejected rather
        // than overflowing the stack (mirrors src/json.zig writeValue: depth 0 at the top-level
        // element, +1 per container descent, reject when depth > max_depth).
        if (depth > Struple.MAX_DEPTH) {
            throw new Struple.StrupleException("JSON nesting too deep");
        }
        switch (e.kind) {
            case NIL:
            case UNDEF:
                sb.append("null");
                return;
            case BOOLEAN:
                sb.append(e.boolValue() ? "true" : "false");
                return;
            case INT:
            case BIG_INT:
                sb.append(e.intValue().toString());
                return;
            case FLOAT32:
                sb.append(formatNumber((double) e.float32()));
                return;
            case FLOAT64:
                sb.append(formatNumber(e.float64()));
                return;
            case DECIMAL:
                renderDecimal(sb, e.decimal());
                return;
            case TIMESTAMP:
                sb.append(Long.toString(e.timestamp()));
                return;
            case UUID:
                writeQuoted(sb, toUuidString(e.uuid()));
                return;
            case STRING:
                writeQuoted(sb, e.string());
                return;
            case BYTES:
                writeQuoted(sb, base64(e.bytesValue()));
                return;
            case ARRAY:
            case SET:
                renderArray(sb, e.inner(), depth);
                return;
            case MAP:
                renderMap(sb, e.inner(), depth);
                return;
            default:
                throw new IllegalStateException();
        }
    }

    private static String formatNumber(double v) {
        if (!Double.isFinite(v)) {
            return "null"; // JSON has no inf/nan
        }
        return DoubleFormat.toString(v);
    }

    private static void renderArray(StringBuilder sb, byte[] body, int depth) {
        Reader r = new Reader(body);
        sb.append('[');
        boolean first = true;
        Element e;
        while ((e = r.next()) != null) {
            if (!first) {
                sb.append(',');
            }
            first = false;
            renderElement(sb, e, depth + 1);
        }
        sb.append(']');
    }

    private static void renderMap(StringBuilder sb, byte[] body, int depth) {
        Reader r = new Reader(body);
        sb.append('{');
        boolean first = true;
        Element k;
        while ((k = r.next()) != null) {
            Element v = r.next();
            if (v == null) {
                throw new Struple.StrupleException("malformed map");
            }
            if (!first) {
                sb.append(',');
            }
            first = false;
            if (k.kind == Struple.Kind.STRING) {
                writeQuoted(sb, k.string());
            } else {
                // Non-string key: render its JSON, then quote the result.
                StringBuilder tmp = new StringBuilder();
                renderElement(tmp, k, depth + 1);
                writeQuoted(sb, tmp.toString());
            }
            sb.append(':');
            renderElement(sb, v, depth + 1);
        }
        sb.append('}');
    }

    /**
     * Render a decimal as an exact JSON number literal — plain notation, or scientific notation for
     * an extreme exponent so a huge (i32-bounded) exponent can't emit gigabytes (Item 2). Mirrors
     * src/json.zig writeDecimal.
     */
    private static void renderDecimal(StringBuilder sb, Struple.Decimal d) {
        if (d.isZero()) {
            sb.append('0');
            return;
        }
        int[] digs = d.coefficientDigits();
        int k = digs.length;
        long exp10 = d.exponent();
        if (d.negative) {
            sb.append('-');
        }
        // Plain notation would pad this many zeros; past the threshold, render in scientific
        // notation so a huge (i32-bounded) exponent can't emit gigabytes.
        final long maxPlainPad = 40;
        long pad;
        if (exp10 >= 0) {
            pad = exp10;
        } else {
            long pp = k + exp10;
            pad = pp > 0 ? 0 : -pp;
        }
        if (pad > maxPlainPad) {
            // d1[.d2…dk]e±E, where E = exp10 + k − 1 (the power of ten of the MSD).
            sb.append((char) ('0' + digs[0]));
            if (digs.length > 1) {
                sb.append('.');
                for (int i = 1; i < digs.length; i++) {
                    sb.append((char) ('0' + digs[i]));
                }
            }
            long sciExp = exp10 + k - 1;
            sb.append('e');
            sb.append(sciExp >= 0 ? '+' : '-');
            sb.append(Long.toString(Math.abs(sciExp)));
            return;
        }
        if (exp10 >= 0) {
            for (int dd : digs) {
                sb.append((char) ('0' + dd));
            }
            for (long z = 0; z < exp10; z++) {
                sb.append('0');
            }
            return;
        }
        long pointPos = k + exp10; // number of integer-part digits
        if (pointPos > 0) {
            int pp = (int) pointPos;
            for (int i = 0; i < pp; i++) {
                sb.append((char) ('0' + digs[i]));
            }
            sb.append('.');
            for (int i = pp; i < k; i++) {
                sb.append((char) ('0' + digs[i]));
            }
        } else {
            sb.append("0.");
            for (long z = pointPos; z < 0; z++) {
                sb.append('0');
            }
            for (int dd : digs) {
                sb.append((char) ('0' + dd));
            }
        }
    }

    private static void writeQuoted(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':
                    sb.append("\\\"");
                    break;
                case '\\':
                    sb.append("\\\\");
                    break;
                case '\n':
                    sb.append("\\n");
                    break;
                case '\r':
                    sb.append("\\r");
                    break;
                case '\t':
                    sb.append("\\t");
                    break;
                case '\b':
                    sb.append("\\b");
                    break;
                case '\f':
                    sb.append("\\f");
                    break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        sb.append('"');
    }

    private static String toUuidString(byte[] u) {
        StringBuilder sb = new StringBuilder(36);
        for (int i = 0; i < 16; i++) {
            if (i == 4 || i == 6 || i == 8 || i == 10) {
                sb.append('-');
            }
            sb.append(hexDigit((u[i] >> 4) & 0xF));
            sb.append(hexDigit(u[i] & 0xF));
        }
        return sb.toString();
    }

    private static char hexDigit(int v) {
        return (char) (v < 10 ? '0' + v : 'a' + (v - 10));
    }

    private static final char[] B64 =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

    private static String base64(byte[] data) {
        StringBuilder sb = new StringBuilder();
        int i = 0;
        while (i + 3 <= data.length) {
            int n = ((data[i] & 0xFF) << 16) | ((data[i + 1] & 0xFF) << 8) | (data[i + 2] & 0xFF);
            sb.append(B64[(n >> 18) & 0x3F]).append(B64[(n >> 12) & 0x3F]);
            sb.append(B64[(n >> 6) & 0x3F]).append(B64[n & 0x3F]);
            i += 3;
        }
        int rem = data.length - i;
        if (rem == 1) {
            int n = (data[i] & 0xFF) << 16;
            sb.append(B64[(n >> 18) & 0x3F]).append(B64[(n >> 12) & 0x3F]).append("==");
        } else if (rem == 2) {
            int n = ((data[i] & 0xFF) << 16) | ((data[i + 1] & 0xFF) << 8);
            sb.append(B64[(n >> 18) & 0x3F]).append(B64[(n >> 12) & 0x3F]);
            sb.append(B64[(n >> 6) & 0x3F]).append('=');
        }
        return sb.toString();
    }

    // -----------------------------------------------------------------------
    // Hand-rolled JSON parser
    // -----------------------------------------------------------------------

    /** Preserves object key order so non-canonical input round-trips through the canonical encoder. */
    public static final class JsonObject {
        public final List<String> keys = new ArrayList<>();
        public final List<Object> values = new ArrayList<>();

        /** The value for {@code key}, or null if absent. */
        public Object get(String key) {
            int idx = keys.indexOf(key);
            return idx >= 0 ? values.get(idx) : null;
        }

        public boolean has(String key) {
            return keys.contains(key);
        }
    }

    private static final class Parser {
        private final String s;
        private int i;

        Parser(String s) {
            this.s = s;
            this.i = 0;
        }

        boolean atEnd() {
            return i >= s.length();
        }

        void skipWs() {
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                    i++;
                } else {
                    break;
                }
            }
        }

        Object parseValue(int depth) {
            // Bound recursion into nested containers so hostile deeply-nested input is rejected
            // rather than overflowing the stack (mirrors src/json.zig checkJsonDepth: depth 0 at
            // the top-level element, +1 per container descent, reject when depth > max_depth).
            if (depth > Struple.MAX_DEPTH) {
                throw new Struple.StrupleException("JSON nesting too deep");
            }
            skipWs();
            if (i >= s.length()) {
                throw new Struple.StrupleException("unexpected end of JSON");
            }
            char c = s.charAt(i);
            switch (c) {
                case '{':
                    return parseObject(depth);
                case '[':
                    return parseArray(depth);
                case '"':
                    return parseString();
                case 't':
                    expect("true");
                    return Boolean.TRUE;
                case 'f':
                    expect("false");
                    return Boolean.FALSE;
                case 'n':
                    expect("null");
                    return null;
                default:
                    return parseNumber();
            }
        }

        private void expect(String lit) {
            if (i + lit.length() > s.length() || !s.regionMatches(i, lit, 0, lit.length())) {
                throw new Struple.StrupleException("invalid JSON literal");
            }
            i += lit.length();
        }

        private JsonObject parseObject(int depth) {
            JsonObject obj = new JsonObject();
            i++; // '{'
            skipWs();
            if (i < s.length() && s.charAt(i) == '}') {
                i++;
                return obj;
            }
            while (true) {
                skipWs();
                if (i >= s.length() || s.charAt(i) != '"') {
                    throw new Struple.StrupleException("expected object key");
                }
                String key = parseString();
                skipWs();
                if (i >= s.length() || s.charAt(i) != ':') {
                    throw new Struple.StrupleException("expected ':'");
                }
                i++;
                Object value = parseValue(depth + 1);
                obj.keys.add(key);
                obj.values.add(value);
                skipWs();
                if (i >= s.length()) {
                    throw new Struple.StrupleException("unterminated object");
                }
                char c = s.charAt(i++);
                if (c == '}') {
                    break;
                }
                if (c != ',') {
                    throw new Struple.StrupleException("expected ',' or '}'");
                }
            }
            return obj;
        }

        private List<Object> parseArray(int depth) {
            List<Object> arr = new ArrayList<>();
            i++; // '['
            skipWs();
            if (i < s.length() && s.charAt(i) == ']') {
                i++;
                return arr;
            }
            while (true) {
                arr.add(parseValue(depth + 1));
                skipWs();
                if (i >= s.length()) {
                    throw new Struple.StrupleException("unterminated array");
                }
                char c = s.charAt(i++);
                if (c == ']') {
                    break;
                }
                if (c != ',') {
                    throw new Struple.StrupleException("expected ',' or ']'");
                }
            }
            return arr;
        }

        private String parseString() {
            i++; // opening quote
            StringBuilder sb = new StringBuilder();
            while (i < s.length()) {
                char c = s.charAt(i++);
                if (c == '"') {
                    return sb.toString();
                }
                if (c == '\\') {
                    if (i >= s.length()) {
                        break;
                    }
                    char esc = s.charAt(i++);
                    switch (esc) {
                        case '"':
                            sb.append('"');
                            break;
                        case '\\':
                            sb.append('\\');
                            break;
                        case '/':
                            sb.append('/');
                            break;
                        case 'b':
                            sb.append('\b');
                            break;
                        case 'f':
                            sb.append('\f');
                            break;
                        case 'n':
                            sb.append('\n');
                            break;
                        case 'r':
                            sb.append('\r');
                            break;
                        case 't':
                            sb.append('\t');
                            break;
                        case 'u':
                            if (i + 4 > s.length()) {
                                throw new Struple.StrupleException("bad unicode escape");
                            }
                            int cp = Integer.parseInt(s.substring(i, i + 4), 16);
                            i += 4;
                            sb.append((char) cp);
                            break;
                        default:
                            throw new Struple.StrupleException("bad string escape");
                    }
                } else {
                    sb.append(c);
                }
            }
            throw new Struple.StrupleException("unterminated string");
        }

        /** Parse a number token: integer-valued -> BigInteger; fractional/exponent -> Double. */
        private Object parseNumber() {
            int start = i;
            if (i < s.length() && s.charAt(i) == '-') {
                i++;
            }
            while (i < s.length() && Character.isDigit(s.charAt(i))) {
                i++;
            }
            boolean isFloat = false;
            if (i < s.length() && s.charAt(i) == '.') {
                isFloat = true;
                i++;
                while (i < s.length() && Character.isDigit(s.charAt(i))) {
                    i++;
                }
            }
            if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
                isFloat = true;
                i++;
                if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) {
                    i++;
                }
                while (i < s.length() && Character.isDigit(s.charAt(i))) {
                    i++;
                }
            }
            String tok = s.substring(start, i);
            if (tok.isEmpty() || tok.equals("-")) {
                throw new Struple.StrupleException("invalid number");
            }
            if (isFloat) {
                return Double.valueOf(Double.parseDouble(tok));
            }
            return new BigInteger(tok);
        }
    }

    // -----------------------------------------------------------------------
    // Shortest round-trip double formatting, JS/Zig {d}-style (no trailing ".0",
    // plain decimal where reasonable). Matches the corpus float text exactly.
    // -----------------------------------------------------------------------

    static final class DoubleFormat {
        private DoubleFormat() {}

        static String toString(double v) {
            if (v == 0.0) {
                return "0";
            }
            // Java's Double.toString is shortest round-trip, but emits a trailing ".0"
            // for integral values and uses 'E' notation outside [1e-3, 1e7]. We post-process
            // to the JS Number#toString form, which is what the corpus uses.
            boolean neg = v < 0;
            double av = Math.abs(v);

            // BigDecimal of the shortest digits: parse Java's shortest representation, then
            // re-render. Double.toString gives the minimal digit string we need.
            String javaRepr = Double.toString(av);
            // javaRepr is like "1.5", "100.0", "1.0E20", "1.0E-7".
            BigDecimal bd = new BigDecimal(javaRepr);
            // Extract the minimal significant digits + decimal exponent.
            BigDecimal stripped = bd.stripTrailingZeros();
            String unscaled = stripped.unscaledValue().abs().toString();
            int scale = stripped.scale();
            // value = unscaled * 10^(-scale); let k = number of digits, n = exponent of the
            // first digit (so the JS/ECMAScript "n" where value's MSD has place value 10^(n-1)).
            int k = unscaled.length();
            int pointExp = k - scale; // digits before the decimal point if we wrote plain
            // ECMAScript Number::toString: choose plain vs exponential by the 21 / -6 rule.
            String out;
            if (pointExp >= -5 && pointExp <= 21) {
                out = plain(unscaled, pointExp);
            } else {
                out = exponential(unscaled, pointExp);
            }
            return neg ? "-" + out : out;
        }

        // value = D · 10^(pointExp - k), where D = digits string (length k).
        private static String plain(String digits, int pointExp) {
            int k = digits.length();
            if (pointExp <= 0) {
                StringBuilder sb = new StringBuilder("0.");
                for (int i = 0; i < -pointExp; i++) {
                    sb.append('0');
                }
                sb.append(digits);
                return sb.toString();
            }
            if (pointExp >= k) {
                StringBuilder sb = new StringBuilder(digits);
                for (int i = 0; i < pointExp - k; i++) {
                    sb.append('0');
                }
                return sb.toString();
            }
            return digits.substring(0, pointExp) + "." + digits.substring(pointExp);
        }

        private static String exponential(String digits, int pointExp) {
            int e = pointExp - 1; // exponent for d.ddd form
            StringBuilder sb = new StringBuilder();
            sb.append(digits.charAt(0));
            if (digits.length() > 1) {
                sb.append('.').append(digits.substring(1));
            }
            sb.append('e');
            if (e >= 0) {
                sb.append('+');
            } else {
                sb.append('-');
                e = -e;
            }
            sb.append(e);
            return sb.toString();
        }
    }

    /** UTF-8 byte view of JSON text, for callers that want bytes. */
    public static byte[] fromJsonBytes(byte[] jsonUtf8) {
        return fromJson(new String(jsonUtf8, StandardCharsets.UTF_8));
    }
}

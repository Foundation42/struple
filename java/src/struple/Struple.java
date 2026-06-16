package struple;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * struple — streaming, lexicographically-ordered tuple packing for Java.
 *
 * <p>A {@code struple} value is a stream of self-delimiting, typed elements packed into a byte
 * buffer such that the raw encoded bytes are directly {@code memcmp}-comparable:
 *
 * <pre>{@code
 *   Arrays.compareUnsigned(pack(a), pack(b)) == the semantic order of a and b
 * }</pre>
 *
 * <p>This is a faithful, zero-dependency port of the Zig reference implementation, byte-identical
 * across all language ports and pinned by the shared conformance corpus.
 *
 * <p>Every element begins with a one-byte type code, assigned so {@code memcmp} of the type byte
 * alone gives the cross-type order:
 *
 * <pre>
 *   nil &lt; undefined &lt; false &lt; true
 *       &lt; negative ints &lt; zero &lt; positive ints
 *       &lt; float32 &lt; float64 &lt; decimal &lt; timestamp &lt; uuid
 *       &lt; string &lt; bytes &lt; array &lt; map &lt; set
 * </pre>
 */
public final class Struple {

    private Struple() {}

    // -----------------------------------------------------------------------
    // Type codes — the numeric values are load-bearing (their order IS the
    // cross-type sort order). Gaps are reserved for the future tower.
    // -----------------------------------------------------------------------

    /** Terminator / escape sentinel for variable-length framing. Never a type. */
    public static final int TERMINATOR = 0x00;

    public static final int NIL = 0x01; // null (Python None / JS null)
    public static final int UNDEF = 0x02; // JS undefined

    public static final int BOOL_FALSE = 0x05;
    public static final int BOOL_TRUE = 0x06;

    public static final int INT_NEG_BIG = 0x0F; // arbitrary-precision negative (beyond i128)
    public static final int INT_NEG_MIN = 0x10; // widest fixed negative (16-byte magnitude)
    public static final int INT_NEG_MAX = 0x1F; // 1-byte fixed negative
    public static final int INT_ZERO = 0x20;
    public static final int INT_POS_MIN = 0x21; // 1-byte fixed positive
    public static final int INT_POS_MAX = 0x30; // widest fixed positive (16-byte magnitude)
    public static final int INT_POS_BIG = 0x31; // arbitrary-precision positive (beyond i128)

    public static final int FLOAT32 = 0x34;
    public static final int FLOAT64 = 0x35;

    public static final int DECIMAL = 0x38; // arbitrary-precision base-10 number

    public static final int TIMESTAMP = 0x40;

    public static final int UUID = 0x44; // 16-byte fixed payload (no framing)

    public static final int STRING = 0x48;
    public static final int BYTES = 0x49;

    public static final int ARRAY = 0x50;
    public static final int MAP = 0x52;
    public static final int SET = 0x54;

    /** Companion byte written after a literal 0x00 inside variable-length payloads. */
    static final int ESCAPE_BYTE = 0xFF;

    // Leading sign markers inside a decimal payload, isolating the three sign groups so memcmp
    // keeps negative < zero < positive. For negatives the rest of the payload is bit-complemented.
    static final int DEC_SIGN_NEG = 0x01;
    static final int DEC_SIGN_ZERO = 0x02;
    static final int DEC_SIGN_POS = 0x03;

    /** The i128 fixed-slot range — values beyond use the big-int codes. */
    static final BigInteger I128_MAX = BigInteger.ONE.shiftLeft(127).subtract(BigInteger.ONE);
    static final BigInteger I128_MIN = BigInteger.ONE.shiftLeft(127).negate();

    // -----------------------------------------------------------------------
    // Element kinds + decoded element view
    // -----------------------------------------------------------------------

    public enum Kind {
        NIL, UNDEF, BOOLEAN, INT, BIG_INT, FLOAT32, FLOAT64, DECIMAL, TIMESTAMP, UUID, STRING,
        BYTES, ARRAY, MAP, SET
    }

    /**
     * A decoded element. For string/bytes/array/map/set the slice is the <em>un-escaped</em> inner
     * content (a copy), so containers can be re-read directly with a child {@link Reader}.
     */
    public static final class Element {
        public final Kind kind;
        private final boolean boolValue;
        private final BigInteger intValue; // INT or BIG_INT
        private final BigInt bigInt; // BIG_INT (beyond i128, sign+magnitude view)
        private final float f32;
        private final double f64;
        private final Decimal decimal;
        private final long timestamp; // microseconds since the Unix epoch, UTC
        private final byte[] bytes; // uuid (16 raw) / string-utf8 / bytes / container inner

        private Element(Kind kind, boolean boolValue, BigInteger intValue, BigInt bigInt, float f32,
                double f64, Decimal decimal, long timestamp, byte[] bytes) {
            this.kind = kind;
            this.boolValue = boolValue;
            this.intValue = intValue;
            this.bigInt = bigInt;
            this.f32 = f32;
            this.f64 = f64;
            this.decimal = decimal;
            this.timestamp = timestamp;
            this.bytes = bytes;
        }

        static Element nil() {
            return new Element(Kind.NIL, false, null, null, 0, 0, null, 0, null);
        }

        static Element undef() {
            return new Element(Kind.UNDEF, false, null, null, 0, 0, null, 0, null);
        }

        static Element bool(boolean v) {
            return new Element(Kind.BOOLEAN, v, null, null, 0, 0, null, 0, null);
        }

        static Element ofInt(BigInteger v) {
            return new Element(Kind.INT, false, v, null, 0, 0, null, 0, null);
        }

        static Element ofBigInt(BigInt bi) {
            return new Element(Kind.BIG_INT, false, bi.toBigInteger(), bi, 0, 0, null, 0, null);
        }

        static Element ofF32(float v) {
            return new Element(Kind.FLOAT32, false, null, null, v, 0, null, 0, null);
        }

        static Element ofF64(double v) {
            return new Element(Kind.FLOAT64, false, null, null, 0, v, null, 0, null);
        }

        static Element ofDecimal(Decimal d) {
            return new Element(Kind.DECIMAL, false, null, null, 0, 0, d, 0, null);
        }

        static Element ofTimestamp(long micros) {
            return new Element(Kind.TIMESTAMP, false, null, null, 0, 0, null, micros, null);
        }

        static Element ofUuid(byte[] raw) {
            return new Element(Kind.UUID, false, null, null, 0, 0, null, 0, raw);
        }

        static Element ofString(byte[] utf8) {
            return new Element(Kind.STRING, false, null, null, 0, 0, null, 0, utf8);
        }

        static Element ofBytes(byte[] b) {
            return new Element(Kind.BYTES, false, null, null, 0, 0, null, 0, b);
        }

        static Element container(Kind kind, byte[] inner) {
            return new Element(kind, false, null, null, 0, 0, null, 0, inner);
        }

        public boolean boolValue() {
            return boolValue;
        }

        /** The integer value (for INT or BIG_INT) as a {@link BigInteger}. */
        public BigInteger intValue() {
            return intValue;
        }

        public BigInt bigInt() {
            return bigInt;
        }

        public float float32() {
            return f32;
        }

        public double float64() {
            return f64;
        }

        public Decimal decimal() {
            return decimal;
        }

        public long timestamp() {
            return timestamp;
        }

        /** The 16 raw UUID bytes. */
        public byte[] uuid() {
            return bytes;
        }

        /** The string's decoded UTF-8 text. */
        public String string() {
            return new String(bytes, java.nio.charset.StandardCharsets.UTF_8);
        }

        /** The string's raw (un-escaped) UTF-8 bytes. */
        public byte[] stringBytes() {
            return bytes;
        }

        /** The raw (un-escaped) bytes payload. */
        public byte[] bytesValue() {
            return bytes;
        }

        /** A container's un-escaped inner element stream (array/map/set). */
        public byte[] inner() {
            return bytes;
        }
    }

    /** View of an arbitrary-precision integer that did not fit the fixed (i128) path. */
    public static final class BigInt {
        public final boolean negative;
        /** Big-endian magnitude bytes, normalized (un-complemented). */
        public final byte[] magnitude;

        public BigInt(boolean negative, byte[] magnitude) {
            this.negative = negative;
            this.magnitude = magnitude;
        }

        public BigInteger toBigInteger() {
            BigInteger mag = new BigInteger(1, magnitude);
            return negative ? mag.negate() : mag;
        }
    }

    /**
     * A decoded decimal: value = {@code (-1)^negative · coefficient · 10^exponent}. {@code adjExp}
     * is the adjusted exponent (the power of ten of the most-significant digit). The zero value has
     * an empty coefficient.
     */
    public static final class Decimal {
        public final boolean negative;
        public final long adjExp;
        /** Base-100 packed digit bytes, stored (each pair is {@code value+1}; never complemented). */
        public final byte[] coeffStored;

        Decimal(boolean negative, long adjExp, byte[] coeffStored) {
            this.negative = negative;
            this.adjExp = adjExp;
            this.coeffStored = coeffStored;
        }

        public boolean isZero() {
            return coeffStored.length == 0;
        }

        /** Number of significant decimal digits in the coefficient. */
        public int digitCount() {
            if (coeffStored.length == 0) {
                return 0;
            }
            int pair = (coeffStored[coeffStored.length - 1] & 0xFF) - 1;
            // An odd digit count pads the final pair's low digit with a (canonical) zero.
            return coeffStored.length * 2 - (pair % 10 == 0 ? 1 : 0);
        }

        /** The power of ten applied to the integer coefficient. */
        public long exponent() {
            return adjExp - digitCount();
        }

        /** Unpack the coefficient digits (each 0–9, most-significant first). */
        public int[] coefficientDigits() {
            int[] out = new int[coeffStored.length * 2];
            int w = 0;
            for (int idx = 0; idx < coeffStored.length; idx++) {
                int pair = (coeffStored[idx] & 0xFF) - 1;
                out[w++] = pair / 10;
                int lo = pair % 10;
                boolean isLast = idx + 1 == coeffStored.length;
                if (!(isLast && lo == 0)) { // skip only the synthetic trailing pad
                    out[w++] = lo;
                }
            }
            return Arrays.copyOf(out, w);
        }

        /** As a {@link BigDecimal} (exact). */
        public BigDecimal toBigDecimal() {
            if (isZero()) {
                return BigDecimal.ZERO;
            }
            int[] digits = coefficientDigits();
            BigInteger coeff = BigInteger.ZERO;
            for (int d : digits) {
                coeff = coeff.multiply(BigInteger.TEN).add(BigInteger.valueOf(d));
            }
            if (negative) {
                coeff = coeff.negate();
            }
            // value = coeff · 10^exponent  ==  BigDecimal(unscaled=coeff, scale=-exponent)
            return new BigDecimal(coeff, (int) -exponent());
        }
    }

    // -----------------------------------------------------------------------
    // Packer (Writer) — builds an encoded tuple
    // -----------------------------------------------------------------------

    /** Builder for an encoded struple buffer. The bytes are memcmp-comparable. */
    public static final class Packer {
        private final ByteBuf out = new ByteBuf();

        public byte[] bytes() {
            return out.toArray();
        }

        public Packer appendNil() {
            out.add(NIL);
            return this;
        }

        public Packer appendUndefined() {
            out.add(UNDEF);
            return this;
        }

        public Packer appendBool(boolean v) {
            out.add(v ? BOOL_TRUE : BOOL_FALSE);
            return this;
        }

        public Packer appendInt(long v) {
            appendLong(out, v);
            return this;
        }

        /** Encode an arbitrary-precision integer. */
        public Packer appendBigInteger(BigInteger v) {
            appendInteger(out, v);
            return this;
        }

        /**
         * Encode an integer given its sign and big-endian magnitude bytes. Routes through the fixed
         * path when the value fits i128, else the big-int codes.
         */
        public Packer appendBigInt(boolean negative, byte[] magnitudeBe) {
            byte[] mag = trimLeadingZeros(magnitudeBe);
            if (mag.length == 0) {
                out.add(INT_ZERO);
                return this;
            }
            BigInteger v = new BigInteger(1, mag);
            appendInteger(out, negative ? v.negate() : v);
            return this;
        }

        public Packer appendFloat32(float v) {
            out.add(FLOAT32);
            writeU32Be(out, orderableF32Bits(v));
            return this;
        }

        public Packer appendFloat64(double v) {
            out.add(FLOAT64);
            writeU64Be(out, orderableF64Bits(v));
            return this;
        }

        /**
         * Append an arbitrary-precision decimal {@code (-1)^negative · C · 10^exp}, where
         * {@code digits} are C's decimal digits (each 0–9, most-significant first). Canonicalized on
         * the way in.
         */
        public Packer appendDecimal(boolean negative, int[] digits, int exp) {
            appendDecimalImpl(out, negative, digits, exp);
            return this;
        }

        /** Append a native {@link BigDecimal}. */
        public Packer appendDecimal(BigDecimal value) {
            // value = unscaledValue · 10^(-scale)
            BigInteger unscaled = value.unscaledValue();
            boolean negative = unscaled.signum() < 0;
            int[] digits = digitsOf(unscaled.abs());
            appendDecimalImpl(out, negative, digits, -value.scale());
            return this;
        }

        /** Append a decimal parsed from text: {@code [+/-] digits [. digits] [ (e|E) [+/-] digits ]}. */
        public Packer appendDecimalString(String s) {
            appendDecimalStringImpl(out, s);
            return this;
        }

        /** Microseconds since the Unix epoch, UTC. */
        public Packer appendTimestamp(long micros) {
            out.add(TIMESTAMP);
            // Flip the sign bit so two's-complement order matches unsigned byte order.
            writeU64Be(out, micros ^ 0x8000000000000000L);
            return this;
        }

        /** A 128-bit UUID, stored as its 16 raw bytes. */
        public Packer appendUuid(byte[] raw) {
            if (raw.length != 16) {
                throw new IllegalArgumentException("struple: uuid must be 16 bytes");
            }
            out.add(UUID);
            out.addAll(raw);
            return this;
        }

        public Packer appendUuid(java.util.UUID uuid) {
            byte[] b = new byte[16];
            long hi = uuid.getMostSignificantBits();
            long lo = uuid.getLeastSignificantBits();
            for (int i = 0; i < 8; i++) {
                b[i] = (byte) (hi >>> (56 - 8 * i));
                b[8 + i] = (byte) (lo >>> (56 - 8 * i));
            }
            return appendUuid(b);
        }

        public Packer appendString(String s) {
            writeFramed(out, STRING, s.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return this;
        }

        public Packer appendStringBytes(byte[] utf8) {
            writeFramed(out, STRING, utf8);
            return this;
        }

        public Packer appendBytes(byte[] content) {
            writeFramed(out, BYTES, content);
            return this;
        }

        /** Append a nested array. {@code child} is another tuple's encoded element stream. */
        public Packer appendArray(byte[] child) {
            writeFramed(out, ARRAY, child);
            return this;
        }

        /**
         * Frame an already-canonical container inner stream verbatim under {@code typeCode}
         * (ARRAY/MAP/SET) without re-sorting. Used by the decoder round-trip (transcode), where the
         * inner bytes are known canonical.
         */
        public Packer appendContainerBody(int typeCode, byte[] inner) {
            writeFramed(out, typeCode, inner);
            return this;
        }

        /**
         * Append a map. {@code entries} is a list of {@code [keyEncoding, valueEncoding]} pairs,
         * sorted by key into canonical order.
         */
        public Packer appendMap(List<byte[][]> entries) {
            List<byte[][]> sorted = new ArrayList<>(entries);
            sorted.sort((l, r) -> Arrays.compareUnsigned(l[0], r[0]));
            out.add(MAP);
            for (byte[][] e : sorted) {
                writeEscaped(out, e[0]);
                writeEscaped(out, e[1]);
            }
            out.add(TERMINATOR);
            return this;
        }

        /** Append a set. {@code elements} are sorted and de-duplicated into canonical order. */
        public Packer appendSet(List<byte[]> elements) {
            List<byte[]> sorted = new ArrayList<>(elements);
            sorted.sort(Arrays::compareUnsigned);
            out.add(SET);
            byte[] prev = null;
            for (byte[] e : sorted) {
                if (prev != null && Arrays.equals(prev, e)) {
                    continue; // skip duplicate
                }
                writeEscaped(out, e);
                prev = e;
            }
            out.add(TERMINATOR);
            return this;
        }
    }

    // -----------------------------------------------------------------------
    // Reader — streams elements back out
    // -----------------------------------------------------------------------

    public static final class Reader {
        private final byte[] buf;
        private int pos;

        public Reader(byte[] buf) {
            this.buf = buf;
            this.pos = 0;
        }

        public Reader(byte[] buf, int pos) {
            this.buf = buf;
            this.pos = pos;
        }

        public boolean done() {
            return pos >= buf.length;
        }

        public Element next() {
            if (pos >= buf.length) {
                return null;
            }
            int type = buf[pos++] & 0xFF;
            switch (type) {
                case NIL:
                    return Element.nil();
                case UNDEF:
                    return Element.undef();
                case BOOL_FALSE:
                    return Element.bool(false);
                case BOOL_TRUE:
                    return Element.bool(true);
                case INT_ZERO:
                    return Element.ofInt(BigInteger.ZERO);
                case INT_NEG_BIG:
                case INT_POS_BIG:
                    return readBigInt(type);
                case FLOAT32:
                    return Element.ofF32(readF32());
                case FLOAT64:
                    return Element.ofF64(readF64());
                case DECIMAL:
                    return Element.ofDecimal(readDecimal());
                case TIMESTAMP: {
                    long raw = readU64Be(take(8));
                    return Element.ofTimestamp(raw ^ 0x8000000000000000L);
                }
                case UUID:
                    return Element.ofUuid(take(16));
                case STRING:
                    return Element.ofString(takeFramedUnescaped());
                case BYTES:
                    return Element.ofBytes(takeFramedUnescaped());
                case ARRAY:
                    return Element.container(Kind.ARRAY, takeFramedUnescaped());
                case MAP:
                    return Element.container(Kind.MAP, takeFramedUnescaped());
                case SET:
                    return Element.container(Kind.SET, takeFramedUnescaped());
                default:
                    if ((type >= 0x10 && type <= 0x1F) || (type >= 0x21 && type <= 0x30)) {
                        return readFixedInt(type);
                    }
                    throw new StrupleException("invalid type code 0x" + Integer.toHexString(type));
            }
        }

        /** The type code of the next element without consuming it (-1 at end). */
        public int peekType() {
            return pos < buf.length ? (buf[pos] & 0xFF) : -1;
        }

        /** The remaining unread bytes (a valid struple stream). */
        public byte[] rest() {
            return Arrays.copyOfRange(buf, pos, buf.length);
        }

        /** The next element's raw bytes, advancing the cursor (null at end). */
        public byte[] nextView() {
            int start = pos;
            if (next() == null) {
                return null;
            }
            return Arrays.copyOfRange(buf, start, pos);
        }

        /** Advance past the next element; false at end of stream. */
        public boolean skip() {
            return nextView() != null;
        }

        private Element readFixedInt(int type) {
            boolean positive = type > INT_ZERO;
            int n = positive ? type - INT_ZERO : INT_ZERO - type;
            byte[] payload = take(n);
            // The widest (16-byte) slots can address values outside i128; reject non-canonical.
            if (n == 16 && ((positive && (payload[0] & 0xFF) >= 0x80)
                    || (!positive && (payload[0] & 0xFF) < 0x80))) {
                throw new StrupleException("non-canonical 16-byte integer");
            }
            BigInteger raw = new BigInteger(1, payload);
            if (positive) {
                return Element.ofInt(raw);
            }
            return Element.ofInt(raw.subtract(BigInteger.ONE.shiftLeft(8 * n)));
        }

        private Element readBigInt(int type) {
            boolean negative = type == INT_NEG_BIG;
            int m = decByte(take(1)[0], negative);
            byte[] mbytes = take(m);
            int n = 0;
            for (byte b : mbytes) {
                n = (n << 8) | decByte(b, negative);
            }
            byte[] stored = take(n);
            byte[] mag = new byte[n];
            for (int i = 0; i < n; i++) {
                mag[i] = (byte) decByte(stored[i], negative);
            }
            return Element.ofBigInt(new BigInt(negative, mag));
        }

        private Decimal readDecimal() {
            int sign = take(1)[0] & 0xFF;
            if (sign == DEC_SIGN_ZERO) {
                return new Decimal(false, 0, new byte[0]);
            }
            if (sign != DEC_SIGN_NEG && sign != DEC_SIGN_POS) {
                throw new StrupleException("invalid decimal sign");
            }
            boolean negative = sign == DEC_SIGN_NEG;
            long adjExp = readDecExponent(negative);
            // Digit bytes are 1–100 (positive) or their complement (negative), and never collide
            // with the terminator (0x00, or 0xFF when complemented).
            int term = negative ? 0xFF : 0x00;
            int start = pos;
            int i = pos;
            while (i < buf.length && (buf[i] & 0xFF) != term) {
                i++;
            }
            if (i >= buf.length) {
                throw new StrupleException("truncated decimal");
            }
            if (i == start) {
                throw new StrupleException("nonzero decimal must carry digits");
            }
            byte[] coeffStored = new byte[i - start];
            for (int k = 0; k < coeffStored.length; k++) {
                coeffStored[k] = (byte) decByte(buf[start + k], negative);
            }
            pos = i + 1; // consume the terminator
            return new Decimal(negative, adjExp, coeffStored);
        }

        private long readDecExponent(boolean complement) {
            int tb = decByte(take(1)[0], complement);
            if (tb == INT_ZERO) {
                return 0;
            }
            if ((tb >= INT_NEG_MIN && tb <= INT_NEG_MAX) || (tb >= INT_POS_MIN && tb <= INT_POS_MAX)) {
                boolean positive = tb > INT_ZERO;
                int n = positive ? tb - INT_ZERO : INT_ZERO - tb;
                byte[] raw = take(n);
                byte[] payload = new byte[n];
                for (int k = 0; k < n; k++) {
                    payload[k] = (byte) decByte(raw[k], complement);
                }
                if (n == 16 && ((positive && (payload[0] & 0xFF) >= 0x80)
                        || (!positive && (payload[0] & 0xFF) < 0x80))) {
                    throw new StrupleException("non-canonical 16-byte decimal exponent");
                }
                BigInteger v = new BigInteger(1, payload);
                BigInteger value = positive ? v : v.subtract(BigInteger.ONE.shiftLeft(8 * n));
                if (value.bitLength() > 63) {
                    throw new StrupleException("decimal exponent out of range");
                }
                return value.longValueExact();
            }
            throw new StrupleException("invalid decimal exponent");
        }

        private float readF32() {
            int bits = (int) readU32Be(take(4));
            bits = (bits & 0x80000000) != 0 ? bits ^ 0x80000000 : ~bits;
            return Float.intBitsToFloat(bits);
        }

        private double readF64() {
            long bits = readU64Be(take(8));
            bits = (bits & 0x8000000000000000L) != 0 ? bits ^ 0x8000000000000000L : ~bits;
            return Double.longBitsToDouble(bits);
        }

        private byte[] take(int n) {
            if (pos + n > buf.length) {
                throw new StrupleException("truncated");
            }
            byte[] slice = Arrays.copyOfRange(buf, pos, pos + n);
            pos += n;
            return slice;
        }

        private byte[] takeFramed() {
            int start = pos;
            int i = pos;
            while (i < buf.length) {
                if ((buf[i] & 0xFF) == 0x00) {
                    if (i + 1 < buf.length && (buf[i + 1] & 0xFF) == ESCAPE_BYTE) {
                        i += 2; // escaped literal 0x00
                        continue;
                    }
                    pos = i + 1; // consume terminator
                    return Arrays.copyOfRange(buf, start, i);
                }
                i++;
            }
            throw new StrupleException("truncated (unterminated framed value)");
        }

        private byte[] takeFramedUnescaped() {
            return unescape(takeFramed());
        }
    }

    public static Reader reader(byte[] buf) {
        return new Reader(buf);
    }

    private static int decByte(byte b, boolean complemented) {
        return complemented ? (~b & 0xFF) : (b & 0xFF);
    }

    // -----------------------------------------------------------------------
    // Ordering (ordering IS memcmp)
    // -----------------------------------------------------------------------

    /** Lexicographic unsigned byte comparison (-1/0/1). */
    public static int compare(byte[] a, byte[] b) {
        int c = Arrays.compareUnsigned(a, b);
        return Integer.compare(c, 0);
    }

    // -----------------------------------------------------------------------
    // Escaping helpers for variable-length payloads
    // -----------------------------------------------------------------------

    public static byte[] unescape(byte[] framed) {
        boolean hasNul = false;
        for (byte b : framed) {
            if (b == 0x00) {
                hasNul = true;
                break;
            }
        }
        if (!hasNul) {
            return framed;
        }
        ByteBuf out = new ByteBuf();
        int i = 0;
        while (i < framed.length) {
            out.add(framed[i] & 0xFF);
            if ((framed[i] & 0xFF) == 0x00) {
                i++; // skip the 0xFF companion
            }
            i++;
        }
        return out.toArray();
    }

    // -----------------------------------------------------------------------
    // Integer encode
    // -----------------------------------------------------------------------

    private static void appendInteger(ByteBuf out, BigInteger value) {
        int sign = value.signum();
        if (sign == 0) {
            out.add(INT_ZERO);
            return;
        }
        boolean negative = sign < 0;
        BigInteger mag = value.abs();
        // The fixed slots span the whole i128 range (1–16 byte magnitudes).
        if (value.compareTo(I128_MIN) >= 0 && value.compareTo(I128_MAX) <= 0) {
            if (negative) {
                BigInteger posVal = mag.subtract(BigInteger.ONE);
                int n = Math.max(1, byteLen(posVal));
                out.add(INT_ZERO - n);
                // Excess form: store 2^(8n) - magnitude.
                BigInteger excess = BigInteger.ONE.shiftLeft(8 * n).subtract(mag);
                writeBigEndian(out, excess, n);
            } else {
                int n = byteLen(mag);
                out.add(INT_ZERO + n);
                writeBigEndian(out, mag, n);
            }
            return;
        }
        // arbitrary precision beyond i128: [m][n][magnitude], complemented for negatives
        out.add(negative ? INT_NEG_BIG : INT_POS_BIG);
        byte[] magBytes = trimLeadingZeros(mag.toByteArray());
        int n = magBytes.length;
        int m = Math.max(1, byteLenInt(n));
        java.util.function.IntUnaryOperator comp =
                negative ? (b -> (~b) & 0xFF) : (b -> b & 0xFF);
        out.add(comp.applyAsInt(m));
        for (int i = m - 1; i >= 0; i--) {
            out.add(comp.applyAsInt((n >>> (8 * i)) & 0xFF));
        }
        for (byte b : magBytes) {
            out.add(comp.applyAsInt(b & 0xFF));
        }
    }

    /** Fixed-path integer encode straight from a long — no BigInteger allocation
     *  (a long always fits the i128 fixed slots). Byte-identical to appendInteger. */
    private static void appendLong(ByteBuf out, long v) {
        if (v == 0) {
            out.add(INT_ZERO);
            return;
        }
        boolean negative = v < 0;
        long mag = negative ? -v : v; // unsigned magnitude (wraps correctly for MIN_VALUE)
        if (negative) {
            int n = Math.max(1, byteLenLong(mag - 1)); // size for |value| - 1
            out.add(INT_ZERO - n);
            writeBigEndianLong(out, -mag, n); // low n bytes = 2^(8n) - magnitude (excess form)
        } else {
            int n = byteLenLong(mag);
            out.add(INT_ZERO + n);
            writeBigEndianLong(out, mag, n);
        }
    }

    private static int byteLenLong(long magUnsigned) {
        if (magUnsigned == 0) return 0;
        return (64 - Long.numberOfLeadingZeros(magUnsigned) + 7) / 8;
    }

    private static void writeBigEndianLong(ByteBuf out, long value, int n) {
        for (int i = n - 1; i >= 0; i--) out.add((int) ((value >>> (8 * i)) & 0xFF));
    }

    // -----------------------------------------------------------------------
    // Decimal encode
    // -----------------------------------------------------------------------

    private static void appendDecimalImpl(ByteBuf out, boolean negative, int[] digits, int exp) {
        int lead = 0;
        while (lead < digits.length && digits[lead] == 0) {
            lead++;
        }
        out.add(DECIMAL);
        if (lead >= digits.length) { // canonical zero — one form regardless of scale
            out.add(DEC_SIGN_ZERO);
            return;
        }
        int sigLen = digits.length - lead;
        // Adjusted exponent: place value of the most-significant digit (0.d…·10^E). Trailing zeros
        // change neither the value nor E, so drop them for storage.
        long adjExp = (long) sigLen + exp;
        int end = digits.length;
        while (end > lead && digits[end - 1] == 0) {
            end--;
        }

        // Order-bearing tail: [E as a struple int][base-100 digits][terminator].
        ByteBuf tail = new ByteBuf();
        appendInteger(tail, BigInteger.valueOf(adjExp));
        for (int i = lead; i < end; i += 2) {
            int hi = digits[i];
            int lo = (i + 1 < end) ? digits[i + 1] : 0; // pad odd tail with 0
            tail.add(hi * 10 + lo + 1); // pair 0–99 -> byte 1–100
        }
        tail.add(TERMINATOR);

        out.add(negative ? DEC_SIGN_NEG : DEC_SIGN_POS);
        byte[] tailBytes = tail.toArray();
        for (byte b : tailBytes) {
            out.add(negative ? (~b & 0xFF) : (b & 0xFF));
        }
    }

    private static void appendDecimalStringImpl(ByteBuf out, String s) {
        int i = 0;
        int n = s.length();
        boolean negative = false;
        if (i < n && (s.charAt(i) == '+' || s.charAt(i) == '-')) {
            negative = s.charAt(i) == '-';
            i++;
        }
        int[] digits = new int[n];
        int dlen = 0;
        int exp = 0;
        boolean seenPoint = false;
        boolean anyDigit = false;
        for (; i < n; i++) {
            char c = s.charAt(i);
            if (c == '.') {
                if (seenPoint) {
                    throw new StrupleException("invalid decimal");
                }
                seenPoint = true;
                continue;
            }
            if (c == 'e' || c == 'E') {
                break;
            }
            if (c < '0' || c > '9') {
                throw new StrupleException("invalid decimal");
            }
            digits[dlen++] = c - '0';
            if (seenPoint) {
                exp -= 1;
            }
            anyDigit = true;
        }
        if (!anyDigit) {
            throw new StrupleException("invalid decimal");
        }
        if (i < n && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
            i++;
            int esign = 1;
            if (i < n && (s.charAt(i) == '+' || s.charAt(i) == '-')) {
                if (s.charAt(i) == '-') {
                    esign = -1;
                }
                i++;
            }
            int ev = 0;
            boolean edig = false;
            for (; i < n; i++) {
                char c = s.charAt(i);
                if (c < '0' || c > '9') {
                    throw new StrupleException("invalid decimal");
                }
                ev = ev * 10 + (c - '0');
                edig = true;
            }
            if (!edig) {
                throw new StrupleException("invalid decimal");
            }
            exp += esign * ev;
        }
        appendDecimalImpl(out, negative, Arrays.copyOf(digits, dlen), exp);
    }

    /** Decimal digits (0–9, most-significant first) of a non-negative {@link BigInteger}. */
    private static int[] digitsOf(BigInteger nonNeg) {
        if (nonNeg.signum() == 0) {
            return new int[] {0};
        }
        String s = nonNeg.toString();
        int[] d = new int[s.length()];
        for (int i = 0; i < s.length(); i++) {
            d[i] = s.charAt(i) - '0';
        }
        return d;
    }

    // -----------------------------------------------------------------------
    // Float encode (IEEE-754 total ordering)
    // -----------------------------------------------------------------------

    static int orderableF32Bits(float value) {
        int bits;
        if (Float.isNaN(value)) {
            bits = 0x7fc00000;
        } else {
            float v = (value == 0.0f) ? 0.0f : value; // squash -0.0
            bits = Float.floatToRawIntBits(v);
        }
        return (bits & 0x80000000) != 0 ? ~bits : bits ^ 0x80000000;
    }

    static long orderableF64Bits(double value) {
        long bits;
        if (Double.isNaN(value)) {
            bits = 0x7ff8000000000000L;
        } else {
            double v = (value == 0.0) ? 0.0 : value;
            bits = Double.doubleToRawLongBits(v);
        }
        return (bits & 0x8000000000000000L) != 0 ? ~bits : bits ^ 0x8000000000000000L;
    }

    // -----------------------------------------------------------------------
    // Variable-length framing
    // -----------------------------------------------------------------------

    private static void writeEscaped(ByteBuf out, byte[] content) {
        // Run-length escaping: bulk-copy the runs between literal 0x00 bytes
        // (the common case is a single run with no 0x00). Output is identical to
        // the per-byte form — each 0x00 is still followed by the 0xFF companion.
        int n = content.length;
        int run = 0;
        for (int i = 0; i < n; i++) {
            if (content[i] == 0x00) {
                out.addBytes(content, run, i - run + 1); // run + the 0x00 itself
                out.add(ESCAPE_BYTE);
                run = i + 1;
            }
        }
        if (run < n) {
            out.addBytes(content, run, n - run);
        }
    }

    private static void writeFramed(ByteBuf out, int typeCode, byte[] content) {
        out.add(typeCode);
        writeEscaped(out, content);
        out.add(TERMINATOR);
    }

    // -----------------------------------------------------------------------
    // Byte / numeric helpers
    // -----------------------------------------------------------------------

    private static int byteLen(BigInteger x) {
        if (x.signum() == 0) {
            return 0;
        }
        return (x.bitLength() + 7) / 8;
    }

    private static int byteLenInt(int x) {
        if (x == 0) {
            return 0;
        }
        return (32 - Integer.numberOfLeadingZeros(x) + 7) / 8;
    }

    private static void writeBigEndian(ByteBuf out, BigInteger value, int n) {
        for (int i = n - 1; i >= 0; i--) {
            out.add(value.shiftRight(8 * i).and(BigInteger.valueOf(0xFF)).intValue());
        }
    }

    static byte[] trimLeadingZeros(byte[] b) {
        int s = 0;
        while (s < b.length && b[s] == 0) {
            s++;
        }
        return (s == 0) ? b : Arrays.copyOfRange(b, s, b.length);
    }

    private static void writeU32Be(ByteBuf out, int v) {
        out.add((v >>> 24) & 0xFF);
        out.add((v >>> 16) & 0xFF);
        out.add((v >>> 8) & 0xFF);
        out.add(v & 0xFF);
    }

    private static void writeU64Be(ByteBuf out, long v) {
        for (int i = 7; i >= 0; i--) {
            out.add((int) ((v >>> (8 * i)) & 0xFF));
        }
    }

    private static long readU32Be(byte[] b) {
        long v = 0;
        for (byte x : b) {
            v = (v << 8) | (x & 0xFF);
        }
        return v;
    }

    private static long readU64Be(byte[] b) {
        long v = 0;
        for (byte x : b) {
            v = (v << 8) | (x & 0xFF);
        }
        return v;
    }

    /** A growable byte buffer (avoids boxing). */
    static final class ByteBuf {
        private byte[] data = new byte[64];
        private int len;

        void add(int b) {
            if (len == data.length) {
                data = Arrays.copyOf(data, data.length * 2);
            }
            data[len++] = (byte) b;
        }

        void addAll(byte[] bs) {
            addBytes(bs, 0, bs.length);
        }

        /** Bulk-append {@code len} bytes from {@code src} starting at {@code off}. */
        void addBytes(byte[] src, int off, int len) {
            if (len <= 0) {
                return;
            }
            ensure(len);
            System.arraycopy(src, off, data, this.len, len);
            this.len += len;
        }

        private void ensure(int extra) {
            int need = len + extra;
            if (need > data.length) {
                int cap = data.length;
                while (cap < need) {
                    cap <<= 1;
                }
                data = Arrays.copyOf(data, cap);
            }
        }

        byte[] toArray() {
            return Arrays.copyOf(data, len);
        }
    }

    /** Unchecked exception for malformed / truncated struple input. */
    public static final class StrupleException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public StrupleException(String message) {
            super("struple: " + message);
        }
    }
}

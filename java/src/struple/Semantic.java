package struple;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import struple.Struple.Element;
import struple.Struple.Kind;
import struple.Struple.Reader;

/**
 * Semantic (value-based) ordering over encoded struple streams.
 *
 * <p>{@link Struple#compare} gives the raw {@code memcmp} order: the type byte dominates, so an
 * integer and a float never interleave by magnitude. {@link #semanticOrder} instead compares by
 * <em>value</em> — int, big-int, float32, float64 and decimal all compare by their exact
 * mathematical value, so {@code int 5 == float 5.0}, {@code int 2^53+1 > float 2^53}, and
 * {@code decimal 0.1 < float 0.1}, with no precision loss.
 *
 * <p>Cross-type order (when the two values aren't both numbers):
 *
 * <pre>
 *   nil &lt; undefined &lt; bool &lt; number &lt; timestamp &lt; uuid &lt; string &lt; bytes
 *       &lt; array &lt; map &lt; set
 * </pre>
 *
 * <p>NaN sorts as the greatest number (above +inf); {@code -0.0 == 0.0 == int 0}. Containers recurse
 * element-wise; a shorter value sorts before a longer one that extends it.
 */
public final class Semantic {

    private Semantic() {}

    /** Compare two encoded streams element-by-element by semantic value (-1/0/1). */
    public static int semanticOrder(byte[] a, byte[] b) {
        return semanticOrderDepth(a, b, 0);
    }

    private static int semanticOrderDepth(byte[] a, byte[] b, int depth) {
        // Bound recursion into nested containers so hostile deeply-nested input is rejected rather
        // than overflowing the stack (mirrors src/semantic.zig semanticOrderDepth: depth 0 at the
        // top-level element, +1 per container descent, reject when depth > max_depth).
        if (depth > Struple.MAX_DEPTH) {
            throw new Struple.StrupleException("nesting too deep");
        }
        Reader ra = new Reader(a);
        Reader rb = new Reader(b);
        while (true) {
            Element ea = ra.next();
            Element eb = rb.next();
            if (ea == null && eb == null) {
                return 0;
            }
            if (ea == null) {
                return -1; // a is a prefix of b
            }
            if (eb == null) {
                return 1;
            }
            int c = compareElements(ea, eb, depth);
            if (c != 0) {
                return c;
            }
        }
    }

    public static boolean semanticEqual(byte[] a, byte[] b) {
        return semanticOrder(a, b) == 0;
    }

    private static int classRank(Kind k) {
        switch (k) {
            case NIL:
                return 0;
            case UNDEF:
                return 1;
            case BOOLEAN:
                return 2;
            case INT:
            case BIG_INT:
            case FLOAT32:
            case FLOAT64:
            case DECIMAL:
                return 3; // unified "number" class
            case TIMESTAMP:
                return 4;
            case UUID:
                return 5;
            case STRING:
                return 6;
            case BYTES:
                return 7;
            case ARRAY:
                return 8;
            case MAP:
                return 9;
            case SET:
                return 10;
            default:
                throw new IllegalStateException();
        }
    }

    private static int compareElements(Element a, Element b, int depth) {
        int ra = classRank(a.kind);
        int rb = classRank(b.kind);
        if (ra != rb) {
            return Integer.compare(ra, rb);
        }
        switch (a.kind) {
            case NIL:
            case UNDEF:
                return 0;
            case BOOLEAN:
                return Boolean.compare(a.boolValue(), b.boolValue());
            case INT:
            case BIG_INT:
            case FLOAT32:
            case FLOAT64:
            case DECIMAL:
                return compareNumbers(a, b);
            case TIMESTAMP:
                return Long.compare(a.timestamp(), b.timestamp());
            case UUID:
                return Integer.signum(Arrays.compareUnsigned(a.uuid(), b.uuid()));
            case STRING:
                // string content order == UTF-8 byte order
                return Integer.signum(Arrays.compareUnsigned(
                        a.string().getBytes(StandardCharsets.UTF_8),
                        b.string().getBytes(StandardCharsets.UTF_8)));
            case BYTES:
                return Integer.signum(Arrays.compareUnsigned(a.bytesValue(), b.bytesValue()));
            case ARRAY:
            case MAP:
            case SET:
                // a.inner()/b.inner() are already the un-escaped inner streams
                return semanticOrderDepth(a.inner(), b.inner(), depth + 1);
            default:
                throw new IllegalStateException();
        }
    }

    // -----------------------------------------------------------------------
    // Numbers
    // -----------------------------------------------------------------------

    // Rank within the number class: -inf < finite < +inf < NaN. Ints and decimals are finite.
    private static int numClass(Element e) {
        double f;
        switch (e.kind) {
            case INT:
            case BIG_INT:
            case DECIMAL:
                return 1;
            case FLOAT32:
                f = e.float32();
                break;
            case FLOAT64:
                f = e.float64();
                break;
            default:
                throw new IllegalStateException();
        }
        if (Double.isNaN(f)) {
            return 3;
        }
        if (f == Double.POSITIVE_INFINITY) {
            return 2;
        }
        if (f == Double.NEGATIVE_INFINITY) {
            return 0;
        }
        return 1;
    }

    private static boolean isExact(Element e) {
        return e.kind == Kind.INT || e.kind == Kind.BIG_INT || e.kind == Kind.DECIMAL;
    }

    private static double floatVal(Element e) {
        return e.kind == Kind.FLOAT32 ? (double) e.float32() : e.float64();
    }

    private static int compareNumbers(Element a, Element b) {
        int ca = numClass(a);
        int cb = numClass(b);
        if (ca != cb) {
            return Integer.compare(ca, cb);
        }
        if (ca != 1) {
            return 0; // both -inf, both +inf, or both NaN
        }
        // At least one is finite; compare exact values.
        boolean ai = isExact(a);
        boolean bi = isExact(b);
        if (!ai && !bi) {
            return Double.compare(floatVal(a), floatVal(b)); // both finite floats
        }
        // Exact comparison via BigDecimal. A double's exact binary value is new BigDecimal(double);
        // an int/big-int/decimal maps exactly. compareTo ignores scale, so 5.0 == 5.
        BigDecimal va = toExact(a);
        BigDecimal vb = toExact(b);
        return Integer.signum(va.compareTo(vb));
    }

    /** The exact value of a finite number element as a {@link BigDecimal}. */
    private static BigDecimal toExact(Element e) {
        switch (e.kind) {
            case INT:
            case BIG_INT:
                return new BigDecimal(e.intValue());
            case DECIMAL:
                return e.decimal().toBigDecimal();
            case FLOAT32:
                return new BigDecimal((double) e.float32()); // exact binary value of the float
            case FLOAT64:
                return new BigDecimal(e.float64());
            default:
                throw new IllegalStateException();
        }
    }
}

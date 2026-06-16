package struple;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Iterator;
import java.util.List;
import struple.Struple.Reader;

/**
 * Navigation / query over an encoded struple buffer.
 *
 * <p>A buffer is a stream of elements; these helpers slice and inspect it without decoding values.
 * Every result is itself a valid struple buffer, so it composes and recurses.
 *
 * <p>Stream ops ({@code count}, {@code at}, {@code head}, {@code tail}, {@code nthRest},
 * {@code take}) operate on the top-level element stream. To descend into an array/map/set, use
 * {@code containedItems} to get its inner stream, then view that.
 */
public final class Navigate {

    private Navigate() {}

    public static View view(byte[] bytes) {
        return new View(bytes);
    }

    public static final class View {
        public final byte[] bytes;

        public View(byte[] bytes) {
            this.bytes = bytes;
        }

        public Reader reader() {
            return new Reader(bytes);
        }

        /** Number of top-level elements. */
        public int count() {
            Reader r = reader();
            int n = 0;
            while (r.skip()) {
                n++;
            }
            return n;
        }

        /** The element at {@code index}, as a zero-copy sub-view (null if out of range). */
        public byte[] at(int index) {
            Reader r = reader();
            int i = 0;
            byte[] v;
            while ((v = r.nextView()) != null) {
                if (i == index) {
                    return v;
                }
                i++;
            }
            return null;
        }

        /** The first element (null if empty). */
        public byte[] head() {
            return at(0);
        }

        /** Everything after the first element (empty if 0 or 1 elements). */
        public byte[] tail() {
            Reader r = reader();
            r.nextView();
            return r.rest();
        }

        /** Drop {@code n} elements; return the remaining stream. */
        public byte[] nthRest(int n) {
            Reader r = reader();
            for (int i = 0; i < n; i++) {
                if (!r.skip()) {
                    break;
                }
            }
            return r.rest();
        }

        /** The first {@code n} elements, as a contiguous sub-view. */
        public byte[] take(int n) {
            Reader r = reader();
            for (int i = 0; i < n; i++) {
                if (!r.skip()) {
                    break;
                }
            }
            int consumed = bytes.length - r.rest().length;
            return Arrays.copyOfRange(bytes, 0, consumed);
        }

        /** The type code of the first element (-1 if empty). */
        public int headType() {
            return bytes.length > 0 ? (bytes[0] & 0xFF) : -1;
        }

        public boolean isNil() {
            return headType() == Struple.NIL;
        }

        public boolean isUndefined() {
            return headType() == Struple.UNDEF;
        }

        public boolean isBool() {
            int t = headType();
            return t == Struple.BOOL_FALSE || t == Struple.BOOL_TRUE;
        }

        public boolean isInt() {
            int t = headType();
            if (t < 0) {
                return false;
            }
            return t == Struple.INT_ZERO || t == Struple.INT_NEG_BIG || t == Struple.INT_POS_BIG
                    || (t >= Struple.INT_NEG_MIN && t <= Struple.INT_NEG_MAX)
                    || (t >= Struple.INT_POS_MIN && t <= Struple.INT_POS_MAX);
        }

        public boolean isFloat() {
            int t = headType();
            return t == Struple.FLOAT32 || t == Struple.FLOAT64;
        }

        public boolean isDecimal() {
            return headType() == Struple.DECIMAL;
        }

        public boolean isNumber() {
            return isInt() || isFloat() || isDecimal();
        }

        public boolean isTimestamp() {
            return headType() == Struple.TIMESTAMP;
        }

        public boolean isUuid() {
            return headType() == Struple.UUID;
        }

        public boolean isString() {
            return headType() == Struple.STRING;
        }

        public boolean isBytes() {
            return headType() == Struple.BYTES;
        }

        public boolean isArray() {
            return headType() == Struple.ARRAY;
        }

        public boolean isMap() {
            return headType() == Struple.MAP;
        }

        public boolean isSet() {
            return headType() == Struple.SET;
        }

        public boolean isContainer() {
            int t = headType();
            return t == Struple.ARRAY || t == Struple.MAP || t == Struple.SET;
        }

        /**
         * The first element's framed body when it is a container (escapes intact). Null if the head
         * isn't a container.
         */
        public byte[] containerBody() {
            if (!isContainer()) {
                return null;
            }
            // Re-scan the framed body without un-escaping (mirror of zero-copy containerBody).
            int start = 1;
            int i = 1;
            while (i < bytes.length) {
                if ((bytes[i] & 0xFF) == 0x00) {
                    if (i + 1 < bytes.length && (bytes[i + 1] & 0xFF) == Struple.ESCAPE_BYTE) {
                        i += 2;
                        continue;
                    }
                    return Arrays.copyOfRange(bytes, start, i);
                }
                i++;
            }
            return null;
        }

        /** The container's inner element stream, un-escaped. View it with a child View/MapView. */
        public byte[] containedItems() {
            if (!isContainer()) {
                return null;
            }
            Struple.Element e = reader().next();
            if (e == null) {
                return null;
            }
            switch (e.kind) {
                case ARRAY:
                case MAP:
                case SET:
                    return e.inner();
                default:
                    return null;
            }
        }
    }

    /** A (key, value) entry of a map's inner stream (raw element byte slices). */
    public static final class Entry {
        public final byte[] key;
        public final byte[] value;

        public Entry(byte[] key, byte[] value) {
            this.key = key;
            this.value = value;
        }
    }

    /**
     * Reads key/value pairs from a map's inner stream (the un-escaped body from
     * {@link View#containedItems}). Keys are in canonical (sorted) order, so {@code get}
     * early-exits.
     */
    public static final class MapView {
        public final byte[] inner;

        public MapView(byte[] inner) {
            this.inner = inner;
        }

        public int count() {
            return new View(inner).count() / 2;
        }

        public List<Entry> entries() {
            List<Entry> list = new ArrayList<>();
            Reader r = new Reader(inner);
            byte[] k;
            while ((k = r.nextView()) != null) {
                byte[] v = r.nextView();
                if (v == null) {
                    throw new Struple.StrupleException("malformed map");
                }
                list.add(new Entry(k, v));
            }
            return list;
        }

        /** Look up the value bytes for an encoded key. Ordered scan with early exit. */
        public byte[] get(byte[] key) {
            Reader r = new Reader(inner);
            byte[] k;
            while ((k = r.nextView()) != null) {
                byte[] v = r.nextView();
                if (v == null) {
                    throw new Struple.StrupleException("malformed map");
                }
                int c = Arrays.compareUnsigned(k, key);
                if (c == 0) {
                    return v;
                }
                if (c > 0) {
                    return null;
                }
            }
            return null;
        }

        /** Materialize a random-access index for O(log n) {@code get} and O(1) {@code at}. */
        public IndexedMap indexed() {
            return new IndexedMap(inner);
        }
    }

    /**
     * A map's entries materialized into a random-access index. Building it is one O(n) pass over the
     * inner stream; thereafter {@code get} is an O(log n) binary search (canonical key order means a
     * key byte compare <em>is</em> the sort order) and {@code at} is O(1).
     */
    public static final class IndexedMap implements Iterable<Entry> {
        private final Entry[] entries;

        public IndexedMap(byte[] inner) {
            List<Entry> list = new ArrayList<>();
            Reader r = new Reader(inner);
            byte[] k;
            while ((k = r.nextView()) != null) {
                byte[] v = r.nextView();
                if (v == null) {
                    throw new Struple.StrupleException("malformed map");
                }
                list.add(new Entry(k, v));
            }
            entries = list.toArray(new Entry[0]);
        }

        /** Number of entries — O(1). */
        public int count() {
            return entries.length;
        }

        /** The entry at {@code index} in canonical (sorted) order — O(1); null if out of range. */
        public Entry at(int index) {
            return (index >= 0 && index < entries.length) ? entries[index] : null;
        }

        /** Look up the value bytes for an encoded key — O(log n) binary search. */
        public byte[] get(byte[] key) {
            Integer i = find(key);
            return i != null ? entries[i].value : null;
        }

        /** The index of {@code key} in canonical order, or null — O(log n). */
        public Integer find(byte[] key) {
            int lo = 0;
            int hi = entries.length;
            while (lo < hi) {
                int mid = lo + (hi - lo) / 2;
                int c = Arrays.compareUnsigned(entries[mid].key, key);
                if (c == 0) {
                    return mid;
                }
                if (c < 0) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return null;
        }

        @Override
        public Iterator<Entry> iterator() {
            return Arrays.asList(entries).iterator();
        }
    }
}

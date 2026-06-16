package struple;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import struple.Navigate.Entry;
import struple.Navigate.IndexedMap;
import struple.Navigate.MapView;
import struple.Navigate.View;
import struple.Struple.Element;
import struple.Struple.Packer;
import struple.Struple.Reader;

/**
 * Behavioral tests for the Java struple port: navigation (View / MapView / IndexedMap mirroring
 * {@code src/tests.zig}), plus golden + round-trip checks for decimal / uuid / int. Prints a
 * summary and exits nonzero on any failure.
 */
public final class TestStruple {

    private static int failures = 0;
    private static int checks = 0;

    public static void main(String[] args) {
        goldenScalars();
        goldenDecimals();
        roundTripDecimals();
        goldenUuid();
        roundTripIntegers();
        navStreamOps();
        navPredicatesAndDescent();
        navMapLookup();
        navIndexedMap();
        semanticSpot();

        System.out.printf("TestStruple: %d checks | %d failures%n", checks, failures);
        if (failures != 0) {
            System.exit(1);
        }
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    private static byte[] encStr(String s) {
        return new Packer().appendString(s).bytes();
    }

    private static byte[] encInt(long v) {
        return new Packer().appendInt(v).bytes();
    }

    private static BigInteger intOf(byte[] view) {
        Element e = new Reader(view).next();
        return e.intValue();
    }

    private static String strOf(byte[] view) {
        Element e = new Reader(view).next();
        return e.string();
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte x : b) {
            sb.append(Character.forDigit((x >> 4) & 0xF, 16));
            sb.append(Character.forDigit(x & 0xF, 16));
        }
        return sb.toString();
    }

    private static void check(boolean cond, String label) {
        checks++;
        if (!cond) {
            System.err.println("FAIL " + label);
            failures++;
        }
    }

    private static void checkHex(String label, byte[] got, String want) {
        check(hex(got).equals(want), label + " (got " + hex(got) + " want " + want + ")");
    }

    // -----------------------------------------------------------------------
    // golden + round-trip
    // -----------------------------------------------------------------------

    private static void goldenScalars() {
        checkHex("nil", new Packer().appendNil().bytes(), "01");
        checkHex("undef", new Packer().appendUndefined().bytes(), "02");
        checkHex("false", new Packer().appendBool(false).bytes(), "05");
        checkHex("true", new Packer().appendBool(true).bytes(), "06");
        checkHex("int 0", encInt(0), "20");
        checkHex("int 12345", encInt(12345), "223039");
        checkHex("int -1", encInt(-1), "1fff");
        checkHex("int 256", encInt(256), "220100");
        checkHex("string app", encStr("app"), "4861707000");
        checkHex("float64 1.5", new Packer().appendFloat64(1.5).bytes(), "35bff8000000000000");
        checkHex("float32 1.5", new Packer().appendFloat32(1.5f).bytes(), "34bfc00000");
        checkHex("timestamp 0", new Packer().appendTimestamp(0).bytes(), "408000000000000000");
    }

    private static void goldenDecimals() {
        checkHex("dec 0", new Packer().appendDecimalString("0").bytes(), "3802");
        checkHex("dec 12.345", new Packer().appendDecimalString("12.345").bytes(),
                "380321020d233300");
        checkHex("dec -12.345", new Packer().appendDecimalString("-12.345").bytes(),
                "3801defdf2dcccff");
        checkHex("dec 100", new Packer().appendDecimalString("100").bytes(), "380321030b00");
        checkHex("dec 0.001", new Packer().appendDecimalString("0.001").bytes(), "38031ffe0b00");
        // canonicalization: 12.300 == 12.3
        checkHex("dec 12.300", new Packer().appendDecimalString("12.300").bytes(),
                "380321020d1f00");
        // native BigDecimal dispatch agrees with the string form
        checkHex("dec BigDecimal 12.345", new Packer().appendDecimal(new BigDecimal("12.345")).bytes(),
                "380321020d233300");
        // explicit (negative, digits, exp) triple
        checkHex("dec triple 12.345", new Packer().appendDecimal(false, new int[] {1, 2, 3, 4, 5}, -3).bytes(),
                "380321020d233300");
        check(new Packer().appendDecimal(new BigDecimal("12.300")).bytes().length
                == new Packer().appendDecimal(new BigDecimal("12.3")).bytes().length,
                "dec 12.300 == 12.3 length");
        check(java.util.Arrays.equals(new Packer().appendDecimal(new BigDecimal("12.300")).bytes(),
                new Packer().appendDecimal(new BigDecimal("12.3")).bytes()),
                "dec 12.300 == 12.3 bytes");
    }

    private static void roundTripDecimals() {
        String[] samples = {"0", "5", "-5", "12.345", "-12.345", "0.001", "100", "9.99", "1e30",
                "1e-9", "-0.5", "123456789012345678901234567890.123456789"};
        for (String s : samples) {
            byte[] enc = new Packer().appendDecimalString(s).bytes();
            Element e = new Reader(enc).next();
            check(e.kind == Struple.Kind.DECIMAL, "decimal kind " + s);
            // re-pack from decoded (sign, digits, exponent) -> byte-identical
            Struple.Decimal d = e.decimal();
            byte[] re = new Packer()
                    .appendDecimal(d.negative, d.coefficientDigits(), (int) d.exponent()).bytes();
            check(java.util.Arrays.equals(enc, re), "decimal repack " + s);
            // BigDecimal value equality
            check(d.toBigDecimal().compareTo(new BigDecimal(s)) == 0, "decimal value " + s);
        }
        // fully-specified decode: 12.345 = +12345 x 10^-3
        Element e = new Reader(new Packer().appendDecimalString("12.345").bytes()).next();
        Struple.Decimal d = e.decimal();
        check(!d.negative && !d.isZero(), "12.345 sign");
        check(d.digitCount() == 5, "12.345 digitCount");
        check(d.exponent() == -3, "12.345 exponent");
        check(java.util.Arrays.equals(d.coefficientDigits(), new int[] {1, 2, 3, 4, 5}),
                "12.345 digits");
    }

    private static void goldenUuid() {
        byte[] u = new byte[] {0x55, 0x0e, (byte) 0x84, 0x00, (byte) 0xe2, (byte) 0x9b, 0x41,
                (byte) 0xd4, (byte) 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00};
        byte[] enc = new Packer().appendUuid(u).bytes();
        checkHex("uuid golden", enc, "44550e8400e29b41d4a716446655440000");
        Element e = new Reader(enc).next();
        check(e.kind == Struple.Kind.UUID && java.util.Arrays.equals(e.uuid(), u), "uuid round-trip");
        // java.util.UUID overload agrees
        java.util.UUID ju = java.util.UUID.fromString("550e8400-e29b-41d4-a716-446655440000");
        checkHex("uuid from java.util.UUID", new Packer().appendUuid(ju).bytes(),
                "44550e8400e29b41d4a716446655440000");
    }

    private static void roundTripIntegers() {
        long[] cases = {Long.MIN_VALUE, -1_000_000_000_000L, -65537, -65536, -257, -256, -255, -100,
                -2, -1, 0, 1, 2, 100, 255, 256, 257, 65535, 65536, 1_000_000_000_000L, Long.MAX_VALUE};
        for (long v : cases) {
            byte[] buf = encInt(v);
            Element e = new Reader(buf).next();
            check(e.intValue().equals(BigInteger.valueOf(v)), "int round-trip " + v);
        }
        // wide ints + big-int boundary
        BigInteger[] wide = {
                BigInteger.ONE.shiftLeft(64), BigInteger.ONE.shiftLeft(64).negate(),
                BigInteger.ONE.shiftLeft(100), BigInteger.ONE.shiftLeft(100).negate(),
                Struple.I128_MAX, Struple.I128_MIN,
                BigInteger.ONE.shiftLeft(127), // first big-int positive
                Struple.I128_MIN.subtract(BigInteger.ONE), // first big-int negative
                new BigInteger("100000000000000000000000000000"),
                new BigInteger("-99999999999999999999999999999999")};
        for (BigInteger v : wide) {
            byte[] buf = new Packer().appendBigInteger(v).bytes();
            Element e = new Reader(buf).next();
            check(e.intValue().equals(v), "bigint round-trip " + v);
        }
    }

    // -----------------------------------------------------------------------
    // navigation
    // -----------------------------------------------------------------------

    private static void navStreamOps() {
        Packer child = new Packer().appendInt(1).appendInt(2).appendInt(3);
        byte[] buf = new Packer().appendString("users").appendInt(12345).appendBool(true)
                .appendArray(child.bytes()).bytes();
        View v = Navigate.view(buf);
        check(v.count() == 4, "count == 4");
        check(v.headType() == Struple.STRING, "headType string");
        check(strOf(v.at(0)).equals("users"), "at(0) users");
        check(intOf(v.at(1)).equals(BigInteger.valueOf(12345)), "at(1) 12345");
        check(v.at(4) == null, "at(4) null");
        check(java.util.Arrays.equals(v.head(), v.at(0)), "head == at(0)");
        check(new View(v.tail()).count() == 3, "tail count 3");
        check(new View(v.nthRest(2)).count() == 2, "nthRest(2) count 2");
        byte[] tk = v.take(2);
        check(new View(tk).count() == 2, "take(2) count 2");
        check(java.util.Arrays.equals(tk, java.util.Arrays.copyOf(buf, tk.length)), "take prefix");
    }

    private static void navPredicatesAndDescent() {
        check(Navigate.view(encStr("x")).isString(), "isString");
        View i5 = Navigate.view(encInt(5));
        check(i5.isInt() && i5.isNumber() && !i5.isFloat(), "isInt/isNumber");
        View f = Navigate.view(new Packer().appendFloat64(1.5).bytes());
        check(f.isFloat() && f.isNumber() && !f.isInt(), "isFloat");
        check(Navigate.view(new Packer().appendNil().bytes()).isNil(), "isNil");
        check(Navigate.view(new Packer().appendBool(true).bytes()).isBool(), "isBool");
        check(Navigate.view(new Packer().appendDecimalString("1.5").bytes()).isDecimal(), "isDecimal");

        Packer child = new Packer().appendInt(10).appendInt(20);
        View v = Navigate.view(new Packer().appendArray(child.bytes()).bytes());
        check(v.isArray() && v.isContainer(), "isArray/isContainer");
        check(v.count() == 1, "array top count 1");
        View inner = new View(v.containedItems());
        check(inner.count() == 2, "inner count 2");
        check(intOf(inner.at(0)).equals(BigInteger.TEN), "inner at(0) 10");
        check(intOf(inner.at(1)).equals(BigInteger.valueOf(20)), "inner at(1) 20");
    }

    private static void navMapLookup() {
        // {"c":3,"a":1,"b":2} out of order -> canonical
        List<byte[][]> entries = new ArrayList<>();
        entries.add(new byte[][] {encStr("c"), encInt(3)});
        entries.add(new byte[][] {encStr("a"), encInt(1)});
        entries.add(new byte[][] {encStr("b"), encInt(2)});
        byte[] buf = new Packer().appendMap(entries).bytes();
        View v = Navigate.view(buf);
        check(v.isMap(), "isMap");
        MapView m = new MapView(v.containedItems());
        check(m.count() == 3, "map count 3");
        check(intOf(m.get(encStr("b"))).equals(BigInteger.valueOf(2)), "map get b == 2");
        check(m.get(encStr("z")) == null, "map get z == null (past end)");
        check(m.get(encStr("aa")) == null, "map get aa == null (middle)");
        List<String> keys = new ArrayList<>();
        for (Entry e : m.entries()) {
            keys.add(strOf(e.key));
        }
        check(keys.equals(List.of("a", "b", "c")), "map keys sorted");
    }

    private static void navIndexedMap() {
        // eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts them
        String[] keys = {"h", "c", "a", "g", "d", "f", "b", "e"};
        List<byte[][]> entries = new ArrayList<>();
        for (int i = 0; i < keys.length; i++) {
            entries.add(new byte[][] {encStr(keys[i]), encInt(i + 1)});
        }
        byte[] inner = Navigate.view(new Packer().appendMap(entries).bytes()).containedItems();
        IndexedMap im = new IndexedMap(inner);

        check(im.count() == 8, "indexed count 8");

        // at() walks canonical (sorted) order: a..h
        String abc = "abcdefgh";
        for (int i = 0; i < 8; i++) {
            check(strOf(im.at(i).key).equals(String.valueOf(abc.charAt(i))), "indexed at(" + i + ")");
        }
        check(im.at(8) == null, "indexed at(8) null");

        // get() binary-searches; agrees with linear MapView.get on every key
        MapView m = new MapView(inner);
        for (char ch : abc.toCharArray()) {
            byte[] key = encStr(String.valueOf(ch));
            check(java.util.Arrays.equals(im.get(key), m.get(key)), "indexed get matches linear " + ch);
        }

        // "e" inserted 8th (value 8) but sits at sorted position 4 — get still finds it
        check(im.find(encStr("e")) == 4, "find e == 4");
        check(intOf(im.get(encStr("e"))).equals(BigInteger.valueOf(8)), "get e == 8");

        // misses: before, between, after
        check(im.get(encStr("A")) == null, "get A == null (below)");
        check(im.get(encStr("cc")) == null, "get cc == null (between)");
        check(im.get(encStr("z")) == null, "get z == null (above)");
        check(im.find(encStr("cc")) == null, "find cc == null");
        check(im.find(encStr("a")) == 0, "find a == 0");
        check(im.find(encStr("h")) == 7, "find h == 7");

        // iteration yields the eight entries in canonical order
        List<String> listed = new ArrayList<>();
        for (Entry e : im) {
            listed.add(strOf(e.key));
        }
        check(listed.equals(List.of("a", "b", "c", "d", "e", "f", "g", "h")), "indexed iteration");

        // the MapView.indexed() shortcut builds an equivalent index
        IndexedMap im2 = new MapView(inner).indexed();
        check(im2.count() == 8, "indexed() shortcut count");
        check(java.util.Arrays.equals(im2.get(encStr("e")), im.get(encStr("e"))), "indexed() get e");
    }

    private static void semanticSpot() {
        // int 5 == float 5.0; decimal 0.1 < float 0.1; decimal 2.5 == float 2.5
        check(Semantic.semanticOrder(encInt(5), new Packer().appendFloat64(5.0).bytes()) == 0,
                "sem int 5 == float 5.0");
        check(Semantic.semanticOrder(new Packer().appendDecimalString("0.1").bytes(),
                new Packer().appendFloat64(0.1).bytes()) == -1, "sem decimal 0.1 < float 0.1");
        check(Semantic.semanticOrder(new Packer().appendDecimalString("2.5").bytes(),
                new Packer().appendFloat64(2.5).bytes()) == 0, "sem decimal 2.5 == float 2.5");
        // nil < bool, string < bytes
        check(Semantic.semanticOrder(new Packer().appendNil().bytes(),
                new Packer().appendBool(false).bytes()) == -1, "sem nil < bool");
    }

    private TestStruple() {}
}

import math
import unittest

from struple import Writer, compare, encode, pack, unpack


class Codec(unittest.TestCase):
    def test_golden(self):
        self.assertEqual(encode(None).hex(), "01")
        self.assertEqual(encode(True).hex(), "06")
        self.assertEqual(encode(0).hex(), "20")
        self.assertEqual(encode(255).hex(), "21ff")
        self.assertEqual(encode(256).hex(), "220100")
        self.assertEqual(encode(-1).hex(), "1fff")
        self.assertEqual(encode(-100).hex(), "1f9c")
        self.assertEqual(encode("app").hex(), "4861707000")
        self.assertEqual(encode(1 << 64).hex(), "310109010000000000000000")

    def test_int_roundtrip(self):
        cases = [0, 1, -1, 255, 256, -256, -257, 2**63 - 1, -(2**63), 1 << 64, -(1 << 64), 10**40, -(10**50)]
        for v in cases:
            self.assertEqual(unpack(encode(v))[0], v, f"round-trip {v}")

    def test_ordering(self):
        self.assertLess(encode("app"), encode("apple"))
        self.assertLess(encode(-256), encode(-100))
        self.assertLess(encode(-100), encode(-1))
        self.assertLess(encode(-(1 << 100)), encode(-(1 << 64)))  # big negatives

    def test_sorted_chain(self):
        values = [None, False, True, -(1 << 70), -1000, -1, 0, 1, 1000, 1 << 70, "", "app", "apple", "b"]
        enc = [encode(v) for v in values]
        for i in range(1, len(enc)):
            self.assertLess(enc[i - 1], enc[i], f"index {i}")
        # bytes already sort like the values
        self.assertEqual(sorted(enc), enc)
        self.assertEqual(compare(enc[0], enc[1]), -1)

    def test_containers(self):
        self.assertEqual(unpack(pack([1, 2, 3]))[0], [1, 2, 3])
        # map canonicalization: insertion order does not affect bytes
        self.assertEqual(encode({"b": 2, "a": 1}), encode({"a": 1, "b": 2}))
        # set dedup + sort
        self.assertEqual(unpack(encode({3, 1, 2, 1}))[0], {1, 2, 3})
        # array < map < set
        self.assertLess(pack([1]), encode({"a": 1}))
        self.assertLess(encode({"a": 1}), encode({1}))

    def test_float_ordering(self):
        fb = lambda f: Writer().append_float64(f).bytes()
        fs = [-math.inf, -1.5, -1.0, 0.0, 1.0, 1.5, math.inf]
        enc = [fb(f) for f in fs]
        for i in range(1, len(enc)):
            self.assertLess(enc[i - 1], enc[i], f"float order {fs[i - 1]} < {fs[i]}")
        for f in [-3.5, -1.0, 0.0, 0.1, 1.5, 1e300]:
            self.assertEqual(unpack(fb(f))[0], f)


if __name__ == "__main__":
    unittest.main()

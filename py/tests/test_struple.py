import math
import unittest
import uuid

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
        # wide integers now use the fixed slots (the i128 range)
        self.assertEqual(encode(1 << 64).hex(), "29010000000000000000")  # 9-byte fixed positive
        self.assertEqual(encode((1 << 127) - 1).hex(), "307fffffffffffffffffffffffffffffff")  # i128 max
        self.assertEqual(encode(-(1 << 127)).hex(), "1080000000000000000000000000000000")  # i128 min
        self.assertEqual(encode(1 << 127).hex(), "31011080000000000000000000000000000000")  # first big-int

    def test_uuid(self):
        u = uuid.UUID("550e8400-e29b-41d4-a716-446655440000")
        self.assertEqual(encode(u).hex(), "44550e8400e29b41d4a716446655440000")
        self.assertEqual(unpack(encode(u))[0], u)  # round-trips as a uuid.UUID

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


class DecodeHygiene(unittest.TestCase):
    """Item 6/8 — clean error types, hashable set/map-key decode, raw-µs timestamps."""

    def test_timestamp_raw_micros(self):
        import datetime as dt
        from struple import to_datetime

        micros = 1_700_000_000_123_456
        self.assertEqual(unpack(Writer().append_timestamp(micros).bytes())[0], micros)
        # native conversion is explicit opt-in, and lossless for the µs
        self.assertEqual(to_datetime(micros),
                         dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(microseconds=micros))
        # a timestamp far outside datetime's range still decodes losslessly as µs
        self.assertEqual(unpack(Writer().append_timestamp(-(1 << 62)).bytes())[0], -(1 << 62))
        # encoding a datetime is still accepted (convenience)
        self.assertEqual(unpack(encode(dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc)))[0],
                         1_577_836_800_000_000)

    def test_hashable_container_in_set(self):
        # pack({(1, 2)}) must round-trip through unpack, not raise unhashable-type
        s = {(1, 2), (3, 4)}
        self.assertEqual(unpack(pack(s))[0], s)
        # set of frozensets (nested container as a set element)
        nested = {frozenset({1, 2})}
        self.assertEqual(unpack(pack(nested))[0], nested)

    def test_hashable_container_map_key(self):
        # a container (array) map key decodes to a hashable tuple key
        self.assertEqual(unpack(pack({(1, 2): "v"}))[0], {(1, 2): "v"})

    def test_odd_entry_map_rejected(self):
        # a map framed body with an odd element count is a clean ValueError, not a TypeError
        body = Writer().append_int(1).bytes()  # one element = a key with no value
        odd_map = bytes([0x52]) + body + bytes([0x00])
        with self.assertRaises(ValueError):
            unpack(odd_map)


if __name__ == "__main__":
    unittest.main()

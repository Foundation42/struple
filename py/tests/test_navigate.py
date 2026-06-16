import unittest

from struple import IndexedMap, MapView, Reader, View, Writer, encode, pack, view


def int_of(b):
    kind, val = Reader(b).next()
    assert kind == "int"
    return val


def str_of(b):
    kind, val = Reader(b).next()
    assert kind == "string"
    return val


class Navigate(unittest.TestCase):
    def test_stream_ops(self):
        buf = pack("users", 12345, True, [1, 2, 3])
        v = view(buf)
        self.assertEqual(v.count(), 4)
        self.assertEqual(str_of(v.at(0)), "users")
        self.assertEqual(int_of(v.at(1)), 12345)
        self.assertIsNone(v.at(4))
        self.assertEqual(v.head(), v.at(0))
        self.assertEqual(View(v.tail()).count(), 3)
        self.assertEqual(View(v.nth_rest(2)).count(), 2)
        tk = v.take(2)
        self.assertEqual(View(tk).count(), 2)
        self.assertEqual(tk, buf[: len(tk)])

    def test_predicates_and_descent(self):
        self.assertTrue(view(encode("x")).is_string())
        self.assertTrue(view(encode(5)).is_int() and view(encode(5)).is_number())
        self.assertTrue(view(encode(1.5)).is_float() and not view(encode(1.5)).is_int())
        self.assertTrue(view(encode(None)).is_nil())
        self.assertTrue(view(encode(True)).is_bool())

        v = view(pack([10, 20]))
        self.assertTrue(v.is_array() and v.is_container())
        self.assertEqual(v.count(), 1)
        inner = view(v.contained_items())
        self.assertEqual(inner.count(), 2)
        self.assertEqual(int_of(inner.at(0)), 10)
        self.assertEqual(int_of(inner.at(1)), 20)

    def test_map_lookup(self):
        v = view(encode({"c": 3, "a": 1, "b": 2}))
        self.assertTrue(v.is_map())
        m = MapView(v.contained_items())
        self.assertEqual(m.count(), 3)
        self.assertEqual(int_of(m.get(encode("b"))), 2)
        self.assertIsNone(m.get(encode("z")))
        self.assertIsNone(m.get(encode("aa")))
        self.assertEqual([str_of(k) for k, _ in m.entries()], ["a", "b", "c"])

    def test_indexed_map(self):
        # eight entries "a".."h" -> 1..8, fed out of order so canonicalization sorts them
        keys = ["h", "c", "a", "g", "d", "f", "b", "e"]
        w = Writer()
        w.append_map((encode(k), encode(i + 1)) for i, k in enumerate(keys))
        inner = view(w.bytes()).contained_items()
        im = IndexedMap(inner)

        # count / len are O(1) and agree
        self.assertEqual(im.count(), 8)
        self.assertEqual(len(im), 8)

        # at() walks canonical (sorted) order: a,b,c,...,h
        for i, ch in enumerate("abcdefgh"):
            k, _ = im.at(i)
            self.assertEqual(str_of(k), ch)
        self.assertIsNone(im.at(8))

        # get() binary-searches; agrees with the linear MapView.get on every key
        m = MapView(inner)
        for ch in "abcdefgh":
            key = encode(ch)
            self.assertEqual(im.get(key), m.get(key))

        # "e" was inserted 8th (value 8) but sits at sorted position 4 — get still finds it
        self.assertEqual(im.find(encode("e")), 4)
        self.assertEqual(int_of(im.get(encode("e"))), 8)

        # misses: before, between, and after the key range
        self.assertIsNone(im.get(encode("A")))   # below "a"
        self.assertIsNone(im.get(encode("cc")))  # between "c" and "d"
        self.assertIsNone(im.get(encode("z")))   # above "h"
        self.assertIsNone(im.find(encode("cc")))
        self.assertEqual(im.find(encode("a")), 0)
        self.assertEqual(im.find(encode("h")), 7)

        # iteration yields the eight entries in canonical order
        listed = list(im)
        self.assertEqual(len(listed), 8)
        self.assertEqual([str_of(k) for k, _ in listed], list("abcdefgh"))

        # the MapView.indexed() shortcut builds an equivalent index
        im2 = MapView(inner).indexed()
        self.assertEqual(im2.count(), 8)
        self.assertEqual(im2.get(encode("e")), im.get(encode("e")))


if __name__ == "__main__":
    unittest.main()

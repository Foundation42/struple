"""Recursion-depth caps (HARDENING.md Item 5) — mirrors the Zig reference
``src/tests.zig`` "depth cap" test.

Hostile deeply-nested input must be rejected with the port's own ``ValueError``,
never a native ``RecursionError`` / stack overflow. The cap (``_MAX_DEPTH = 256``)
bounds the three recursive walks: JSON parse, JSON render, semantic compare.
"""

import unittest

from struple import Writer, encode, from_json, semantic_order, to_json


class DepthCap(unittest.TestCase):
    def test_from_json_rejects_deep_input(self):
        # fromJson: 1000-deep JSON array (> max_depth) rejects on the pre-parse
        # scan, as the port's ValueError — NOT a native RecursionError.
        text = "[" * 1000 + "]" * 1000
        with self.assertRaises(ValueError):
            from_json(text)

    def test_deep_encoding_rejected_by_renderer_and_comparator(self):
        # Build a 300-deep nested array encoding via the port's OWN encoder (loop
        # wrapping the previous element's bytes 300x), then to_json / semantic_order
        # must reject it at the cap rather than recursing to a stack overflow.
        buf = encode(0)
        for _ in range(300):
            buf = Writer().append_array(buf).bytes()
        with self.assertRaises(ValueError):
            to_json(buf)
        with self.assertRaises(ValueError):
            semantic_order(buf, buf)


if __name__ == "__main__":
    unittest.main()

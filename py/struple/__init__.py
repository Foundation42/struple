"""struple — streaming, lexicographically-ordered tuple packing.

Encoded bytes are directly comparable: ``compare(pack(a), pack(b))`` (and plain
``bytes`` comparison / ``sorted``) matches the semantic order of the values.
"""

from ._core import (
    IndexedMap, MapView, Reader, View, Writer, compare, encode, pack,
    semantic_eq, semantic_order, transcode, unpack, view,
)
from ._json import from_json, to_json

__all__ = [
    "pack",
    "unpack",
    "encode",
    "transcode",
    "compare",
    "semantic_order",
    "semantic_eq",
    "Reader",
    "Writer",
    "View",
    "MapView",
    "IndexedMap",
    "view",
    "from_json",
    "to_json",
]

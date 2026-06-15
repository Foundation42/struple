"""struple — streaming, lexicographically-ordered tuple packing.

Encoded bytes are directly comparable: ``compare(pack(a), pack(b))`` (and plain
``bytes`` comparison / ``sorted``) matches the semantic order of the values.
"""

from ._core import Reader, Writer, compare, encode, pack, unpack
from ._json import from_json, to_json

__all__ = [
    "pack",
    "unpack",
    "encode",
    "compare",
    "Reader",
    "Writer",
    "from_json",
    "to_json",
]

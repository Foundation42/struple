#!/usr/bin/env python3
"""struple reference benchmark (Python / stdlib only).

Mirrors bench/zig/bench.zig and bench/js/bench.ts: encode (build a framed stream
from prepared in-memory records) and decode (walk the whole stream, descending
and un-escaping every container body and touching every scalar) throughput for
the seven shared workloads — four realistic streaming shapes (stock quotes,
geospatial points, tweets, blockchain transactions) plus three structural
micro-benchmarks (an integer stream, a string stream, a nested document).

The native records are parsed from bench/data/<name>.json once (setup, untimed);
the encoder then rebuilds the bytes with the same appendX sequence the Zig
reference uses. Byte-identity is verified against bench/payloads.json (sha256)
before any throughput figure is reported.

Methodology (per (payload, op)): 5 warm-up runs, auto-calibrate the iteration
count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is reported. A global
checksum sink consumes every result so nothing can be elided. Steady-state
buffers retain capacity. Single-threaded.

Python ints are arbitrary-precision, so the >2^53 / >2^64 gotcha is moot here:
u64 tweet ids and big-int wei values are parsed exactly by int()/int(hex, 16).

Zero dependencies beyond the stdlib (json, hashlib, struct, time.perf_counter_ns,
/proc/cpuinfo).

Run:  cd /home/chrisbe/dev/struple && python3 bench/py/bench.py
   (paths are resolved relative to this file, so it works from anywhere).
"""

from __future__ import annotations

import hashlib
import json
import os
import struct
import sys
from time import perf_counter_ns

# Resolve the struple package (py/) and the bench dirs relative to this file, so
# the script runs from anywhere without an install.
_HERE = os.path.dirname(os.path.abspath(__file__))
_BENCH_DIR = os.path.dirname(_HERE)
_REPO_ROOT = os.path.dirname(_BENCH_DIR)
_DATA_DIR = os.path.join(_BENCH_DIR, "data")
_RESULTS_DIR = os.path.join(_BENCH_DIR, "results")
sys.path.insert(0, os.path.join(_REPO_ROOT, "py"))

from struple import Reader, Writer  # noqa: E402

# ---------------------------------------------------------------------------
# DCE sink — every measured op folds something into this. Python doesn't elide
# dead code, but we mirror the reference exactly and keep the work observable.
# A u64-wrapped accumulator mirrors the Zig `g_sink: u64`.
# ---------------------------------------------------------------------------
_MASK64 = (1 << 64) - 1
g_sink = 0


def sink(v: int) -> None:
    global g_sink
    g_sink = (g_sink + v) & _MASK64


# ---------------------------------------------------------------------------
# Payload manifest.
# ---------------------------------------------------------------------------
PAYLOADS = [
    ("quotes", "stock_quotes", "streaming"),
    ("geo", "geo_points", "streaming"),
    ("tweets", "tweets", "streaming"),
    ("txs", "blockchain_txs", "streaming"),
    ("ints", "int_stream", "structural"),
    ("strings", "string_stream", "structural"),
    ("nested", "nested_doc", "structural"),
]


# ---------------------------------------------------------------------------
# Parsing helpers — the shared data fields are all typed strings (so any JSON
# library reads them identically across languages). See bench/README.md.
# ---------------------------------------------------------------------------

def f64_from_hex(hexstr: str) -> float:
    """16 hex digits of the IEEE-754 bits (big-endian) -> Python float."""
    return struct.unpack(">d", int(hexstr, 16).to_bytes(8, "big"))[0]


def digits_from_str(s: str) -> list[int]:
    """digit string "12345" -> [1, 2, 3, 4, 5]."""
    return [ord(c) - 48 for c in s]


def bytes_from_hex(hexstr: str) -> bytes:
    return bytes.fromhex(hexstr)


def big_from_hex(hexstr: str) -> int:
    """big-endian hex magnitude -> int (both the `big` and `fix` blockchain paths
    reduce to this: append_int routes magnitudes within i128 through the fixed
    slots and magnitudes beyond i128 through the big-int codes, byte-for-byte
    identical to the Zig appendI128 / appendBigInt split)."""
    return 0 if hexstr == "" else int(hexstr, 16)


def _load(name: str):
    with open(os.path.join(_DATA_DIR, name + ".json"), "r", encoding="utf-8") as f:
        return json.load(f)


def read_data() -> dict:
    quotes_raw = _load("stock_quotes")
    quotes = [
        {
            "symbol": r[0],
            "bid_digits": digits_from_str(r[1]),
            "bid_exp": int(r[2]),
            "ask_digits": digits_from_str(r[3]),
            "ask_exp": int(r[4]),
            "last": f64_from_hex(r[5]),
            "volume": int(r[6]),
            "ts": int(r[7]),
        }
        for r in quotes_raw
    ]

    geo_raw = _load("geo_points")
    geo = [
        {
            "lat": f64_from_hex(r[0]),
            "lon": f64_from_hex(r[1]),
            "elevation": f64_from_hex(r[2]),
            "name": r[3],
            "ts": int(r[4]),
        }
        for r in geo_raw
    ]

    tweets_raw = _load("tweets")
    tweets = [
        {
            "id": int(r[0]),  # u64; arbitrary-precision int in Python
            "user": r[1],
            "text": r[2],
            "created_at": int(r[3]),
            "likes": int(r[4]),
            "retweets": int(r[5]),
        }
        for r in tweets_raw
    ]

    txs_raw = _load("blockchain_txs")
    txs = [
        {
            "height": int(r[0]),
            "tx_hash": bytes_from_hex(r[1]),
            "from": bytes_from_hex(r[2]),
            "to": bytes_from_hex(r[3]),
            # r[4] is "big"|"fix"; r[5] is the big-endian hex magnitude. Both
            # collapse to a Python int for append_int (auto-routes by magnitude).
            "value": big_from_hex(r[5]),
            "gas": int(r[6]),
            "nonce": int(r[7]),
            "ts": int(r[8]),
        }
        for r in txs_raw
    ]

    ints = [int(s) for s in _load("int_stream")]

    strings = _load("string_stream")

    nested_raw = _load("nested_doc")
    nested = [
        {
            "active": r[0] == "1",
            "uid": int(r[1]),
            "name": r[2],
            "scores": (int(r[3]), int(r[4]), int(r[5])),
        }
        for r in nested_raw
    ]

    return {
        "quotes": quotes,
        "geo": geo,
        "tweets": tweets,
        "txs": txs,
        "ints": ints,
        "strings": strings,
        "nested": nested,
    }


# ---------------------------------------------------------------------------
# Encoders — one per payload kind. `out` is reset by the caller each iteration;
# a single reused `scratch` Writer frames one record at a time (its backing
# bytearray is truncated, not reallocated, so it retains capacity at steady
# state). Mirrors encodeOnce in bench/zig/bench.zig and bench/js/bench.ts.
# ---------------------------------------------------------------------------

# Pre-encoded constant keys for the nested-doc map (the keys never change; the
# Zig harness re-encodes them per record from an arena, but the keys are
# invariant, so caching them is byte-identical and avoids needless work — same
# as the JS port).
def _enc_string(s: str) -> bytes:
    return Writer().append_string(s).bytes()


def _enc_int(v: int) -> bytes:
    return Writer().append_int(v).bytes()


def _enc_bool(v: bool) -> bytes:
    return Writer().append_bool(v).bytes()


KEY_ACTIVE = _enc_string("active")
KEY_SCORES = _enc_string("scores")
KEY_USER = _enc_string("user")
KEY_ID = _enc_string("id")
KEY_NAME = _enc_string("name")


def _reset(w: Writer) -> None:
    """Reuse a Writer by truncating its backing bytearray (retains capacity)."""
    del w.buf[:]


def encode_once(kind: str, d: dict, out: Writer, scratch: Writer) -> None:
    if kind == "quotes":
        for q in d["quotes"]:
            _reset(scratch)
            scratch.append_string(q["symbol"])
            scratch.append_decimal(False, q["bid_digits"], q["bid_exp"])
            scratch.append_decimal(False, q["ask_digits"], q["ask_exp"])
            scratch.append_float64(q["last"])
            scratch.append_int(q["volume"])
            scratch.append_timestamp(q["ts"])
            out.append_array(scratch.bytes())
    elif kind == "geo":
        for g in d["geo"]:
            _reset(scratch)
            scratch.append_float64(g["lat"])
            scratch.append_float64(g["lon"])
            scratch.append_float64(g["elevation"])
            scratch.append_string(g["name"])
            scratch.append_timestamp(g["ts"])
            out.append_array(scratch.bytes())
    elif kind == "tweets":
        for t in d["tweets"]:
            _reset(scratch)
            scratch.append_int(t["id"])  # u64 id; append_int == append_uint here (positive)
            scratch.append_string(t["user"])
            scratch.append_string(t["text"])
            scratch.append_timestamp(t["created_at"])
            scratch.append_int(t["likes"])
            scratch.append_int(t["retweets"])
            out.append_array(scratch.bytes())
    elif kind == "txs":
        for x in d["txs"]:
            _reset(scratch)
            scratch.append_int(x["height"])
            scratch.append_bytes(x["tx_hash"])
            scratch.append_bytes(x["from"])
            scratch.append_bytes(x["to"])
            scratch.append_int(x["value"])  # big-int or i128 fixed path, chosen by magnitude
            scratch.append_int(x["gas"])
            scratch.append_int(x["nonce"])
            scratch.append_timestamp(x["ts"])
            out.append_array(scratch.bytes())
    elif kind == "ints":
        for v in d["ints"]:
            out.append_int(v)
    elif kind == "strings":
        for s in d["strings"]:
            out.append_string(s)
    elif kind == "nested":
        for n in d["nested"]:
            # user sub-map { id, name }
            user = (
                Writer()
                .append_map([(KEY_ID, _enc_int(n["uid"])), (KEY_NAME, _enc_string(n["name"]))])
                .bytes()
            )
            # scores array [s0, s1, s2]
            scores_inner = Writer()
            scores_inner.append_int(n["scores"][0])
            scores_inner.append_int(n["scores"][1])
            scores_inner.append_int(n["scores"][2])
            scores_arr = Writer().append_array(scores_inner.bytes()).bytes()
            # top-level map (append_map sorts by encoded key, so order here is free)
            out.append_map(
                [
                    (KEY_ACTIVE, _enc_bool(n["active"])),
                    (KEY_SCORES, scores_arr),
                    (KEY_USER, user),
                ]
            )
    else:
        raise ValueError(f"unknown kind {kind!r}")


def record_count(kind: str, d: dict) -> int:
    return {
        "quotes": len(d["quotes"]),
        "geo": len(d["geo"]),
        "tweets": len(d["tweets"]),
        "txs": len(d["txs"]),
        "ints": len(d["ints"]),
        "strings": len(d["strings"]),
        "nested": len(d["nested"]),
    }[kind]


# ---------------------------------------------------------------------------
# Decode — recursive walk that touches every value, descending into every
# container body. The Reader already unescapes each container body in a single
# pass when it yields an array/map/set element (next() ->
# _take_framed_unescaped()), so descending recursively into the body view does
# the realistic work without a redundant pre-scan. Mirrors walk() in the
# reference harnesses.
# ---------------------------------------------------------------------------

def walk(buf: bytes) -> None:
    r = Reader(buf)
    while (el := r.next()) is not None:
        kind, val = el
        if kind == "nil" or kind == "undef":
            pass
        elif kind == "bool":
            sink(1 if val else 0)
        elif kind == "int":
            sink(val & _MASK64)
        elif kind == "float32":
            sink(struct.unpack(">I", struct.pack(">f", val))[0])
        elif kind == "float64":
            sink(struct.unpack(">Q", struct.pack(">d", val))[0])
        elif kind == "decimal":
            sign, digits, exp = val.as_tuple()
            sink((len(digits) + (exp + len(digits))) & _MASK64)
        elif kind == "timestamp":
            sink(val & _MASK64)
        elif kind == "uuid":
            sink(val[0])
        elif kind == "string":
            sink(len(val))
            if len(val) > 0:
                sink(ord(val[0]))
        elif kind == "bytes":
            sink(len(val))
            if len(val) > 0:
                sink(val[0])
        elif kind == "array" or kind == "map" or kind == "set":
            walk(val)  # val is the already-unescaped inner stream
        else:
            raise ValueError(f"unknown element kind {kind!r}")


# ---------------------------------------------------------------------------
# Timing.
# ---------------------------------------------------------------------------

TARGET_TRIAL_NS = 100_000_000  # ~100 ms
N_TRIALS = 9
N_WARMUP = 5


def median(values: list[float]) -> float:
    s = sorted(values)
    return s[len(s) // 2]


def mb_per_sec(ns_per_op: float, nbytes: int) -> float:
    return (nbytes / ns_per_op) * 1000.0  # bytes/ns -> MB/s


def mrec_per_sec(ns_per_op: float, records: int) -> float:
    return (records / ns_per_op) * 1000.0  # rec/ns -> Mrec/s


def build_canonical(kind: str, d: dict) -> bytes:
    out = Writer()
    scratch = Writer()
    encode_once(kind, d, out, scratch)
    return out.bytes()


def bench_encode(kind: str, d: dict, canonical_len: int) -> tuple[float, int, int]:
    out = Writer()
    scratch = Writer()

    def run_once() -> None:
        _reset(out)
        encode_once(kind, d, out, scratch)
        sink(len(out.buf))

    for _ in range(N_WARMUP):
        run_once()

    t0 = perf_counter_ns()
    run_once()
    one = perf_counter_ns() - t0
    iters = max(1, TARGET_TRIAL_NS // one if one > 0 else TARGET_TRIAL_NS)

    trials = []
    for _ in range(N_TRIALS):
        t0 = perf_counter_ns()
        for _ in range(iters):
            run_once()
        dt = perf_counter_ns() - t0
        trials.append(dt / iters)
    return median(trials), canonical_len, record_count(kind, d)


def bench_decode(kind: str, d: dict, buf: bytes) -> tuple[float, int, int]:
    def run_once() -> None:
        walk(buf)

    for _ in range(N_WARMUP):
        run_once()

    t0 = perf_counter_ns()
    run_once()
    one = perf_counter_ns() - t0
    iters = max(1, TARGET_TRIAL_NS // one if one > 0 else TARGET_TRIAL_NS)

    trials = []
    for _ in range(N_TRIALS):
        t0 = perf_counter_ns()
        for _ in range(iters):
            run_once()
        dt = perf_counter_ns() - t0
        trials.append(dt / iters)
    return median(trials), len(buf), record_count(kind, d)


# ---------------------------------------------------------------------------
# Host label.
# ---------------------------------------------------------------------------

def host_label() -> str:
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("model name"):
                    c = line.find(":")
                    if c != -1:
                        return line[c + 1:].strip()
    except OSError:
        pass
    return "unknown"


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

def sha256_hex(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def round2(x: float) -> float:
    return round(x * 100) / 100


def main() -> None:
    with open(os.path.join(_BENCH_DIR, "payloads.json"), "r", encoding="utf-8") as f:
        manifest = json.load(f)
    expected = {p["name"]: p for p in manifest["payloads"]}

    data = read_data()

    print(f"struple benchmark (Python {sys.version.split()[0]}, single-threaded)\n")

    out_results: dict = {}
    all_ok = True
    total_bytes = 0

    for kind, name, _category in PAYLOADS:
        buf = build_canonical(kind, data)
        total_bytes += len(buf)

        # Verify byte-identity against the manifest BEFORE measuring.
        exp = expected.get(name)
        sha = sha256_hex(buf)
        sha_ok = exp is not None and sha == exp["sha256"] and len(buf) == exp["byte_len"]
        if not sha_ok:
            all_ok = False
            print(
                f"\nBYTE MISMATCH for {name}:\n"
                f"  produced byte_len={len(buf)} sha256={sha}\n"
                f"  expected byte_len={exp['byte_len'] if exp else None} "
                f"sha256={exp['sha256'] if exp else None}\n"
                f"This is a contract bug — STOPPING (no throughput reported for this payload).",
                file=sys.stderr,
            )
            out_results[name] = {
                "enc_mrec_s": 0.0,
                "enc_mb_s": 0.0,
                "dec_mrec_s": 0.0,
                "dec_mb_s": 0.0,
                "sha256_ok": False,
            }
            continue

        enc_ns, enc_bytes, enc_recs = bench_encode(kind, data, len(buf))
        dec_ns, dec_bytes, dec_recs = bench_decode(kind, data, buf)

        out_results[name] = {
            "enc_mrec_s": round2(mrec_per_sec(enc_ns, enc_recs)),
            "enc_mb_s": round2(mb_per_sec(enc_ns, enc_bytes)),
            "dec_mrec_s": round2(mrec_per_sec(dec_ns, dec_recs)),
            "dec_mb_s": round2(mb_per_sec(dec_ns, dec_bytes)),
            "sha256_ok": True,
        }

        print(
            f"  {name:<16} {enc_recs:>6} rec   "
            f"enc {mrec_per_sec(enc_ns, enc_recs):>7.2f} Mrec/s {mb_per_sec(enc_ns, enc_bytes):>6.0f} MB/s   "
            f"dec {mrec_per_sec(dec_ns, dec_recs):>7.2f} Mrec/s {mb_per_sec(dec_ns, dec_bytes):>6.0f} MB/s"
            f"   sha {'ok' if out_results[name]['sha256_ok'] else 'FAIL'}"
        )

    host = host_label()
    result = {"lang": "Python", "host": host, "payloads": out_results}

    os.makedirs(_RESULTS_DIR, exist_ok=True)
    with open(os.path.join(_RESULTS_DIR, "py.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
        f.write("\n")

    print(
        f"\nHost: {host} · Total corpus: {total_bytes / 1024:.1f} KB · "
        f"Wrote bench/results/py.json"
    )
    print(f"(sink {g_sink:x})")

    if not all_ok:
        print("\nOne or more payloads failed byte-identity — see above.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

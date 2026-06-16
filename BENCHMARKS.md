# struple benchmarks

Encode (build a stream from in-memory records) and decode (walk a stream, touching every value) throughput across all twelve byte-identical implementations, on the **same shared workloads** (see [`bench/README.md`](bench/README.md)).

**Mrec/s** (millions of records per second) is the headline figure — how many quotes, points, tweets, transactions, or items move through the codec each second. MB/s is shown alongside.

All figures are **single-threaded (per core)**. struple encodes/decodes each record and stream independently, so the work is embarrassingly parallel — aggregate throughput scales ~linearly with cores.

> ✅ Every implementation reproduced every workload **byte-for-byte** (sha256-verified against the shared manifest) before timing.

**Host:** AMD Ryzen 9 9950X3D 16-Core Processor · single-threaded · 12/12 ports reporting.

> Numbers are machine- and runtime-specific — treat them as relative. Compiled ports (Zig/Rust/C/C++) and managed/JIT ports (Go/Java/Kotlin/C#) occupy different bands; the interpreted port (Python) and the JS runtime are slower in absolute terms but exercise identical bytes.


## Streaming workloads


### `stock_quotes` — Level-1 equity quotes: symbol, exact decimal bid/ask, f64 last, volume, timestamp

_4,000 records · 192 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| Zig | 21.38 | 1,048 | 13.81 | 677 |
| C | 16.28 | 798 | 8.31 | 407 |
| Go | 14.11 | 692 | 5.23 | 256 |
| Rust | 11.39 | 558 | 8.13 | 399 |
| C++ | 10.22 | 501 | 7.32 | 359 |
| Java | 8.84 | 433 | 7.21 | 354 |
| Swift | 5.05 | 248 | 3.48 | 171 |
| C# | 4.36 | 214 | 4.56 | 223 |
| Kotlin | 1.27 | 62.51 | 5.14 | 252 |
| TypeScript | 0.53 | 26.00 | 0.58 | 28.48 |
| Dart | 0.45 | 22.04 | 1.13 | 55.53 |
| Python | 0.41 | 19.88 | 0.13 | 6.31 |


### `geo_points` — Geospatial fixes: f64 lat/lon/elevation, place name, timestamp

_4,000 records · 185 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| Go | 39.79 | 1,889 | 10.13 | 481 |
| Zig | 34.98 | 1,661 | 15.04 | 714 |
| Rust | 31.47 | 1,494 | 9.56 | 454 |
| C++ | 25.77 | 1,224 | 8.33 | 395 |
| C | 23.54 | 1,118 | 8.88 | 422 |
| Java | 12.18 | 578 | 9.42 | 447 |
| Swift | 10.00 | 475 | 5.68 | 270 |
| C# | 7.15 | 339 | 6.04 | 287 |
| Kotlin | 1.33 | 63.14 | 8.37 | 397 |
| Python | 0.67 | 31.89 | 0.21 | 10.06 |
| Dart | 0.55 | 26.03 | 0.94 | 44.54 |
| TypeScript | 0.36 | 16.99 | 0.43 | 20.56 |


### `tweets` — Social posts: u64 id, handle, variable-length text, timestamp, like/retweet counts

_3,000 records · 389 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| C | 12.94 | 1,719 | 1.54 | 204 |
| Go | 12.39 | 1,646 | 3.27 | 434 |
| Zig | 11.72 | 1,557 | 4.67 | 621 |
| C++ | 10.84 | 1,439 | 2.16 | 287 |
| Rust | 7.33 | 973 | 3.56 | 473 |
| Swift | 5.14 | 683 | 2.93 | 389 |
| Java | 3.67 | 488 | 4.27 | 567 |
| C# | 1.74 | 231 | 2.38 | 316 |
| Python | 0.95 | 126 | 0.14 | 18.35 |
| Dart | 0.57 | 75.74 | 0.99 | 132 |
| Kotlin | 0.51 | 67.35 | 4.07 | 540 |
| TypeScript | 0.33 | 43.70 | 0.56 | 74.83 |


### `blockchain_txs` — Ledger transactions: 32-byte hash, 20-byte addresses, arbitrary-precision wei value, gas/nonce, timestamp

_3,000 records · 360 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| Zig | 9.82 | 1,207 | 4.67 | 574 |
| C | 9.38 | 1,152 | 2.27 | 278 |
| C++ | 8.42 | 1,034 | 2.65 | 326 |
| Go | 8.30 | 1,020 | 2.74 | 336 |
| Rust | 7.36 | 904 | 3.55 | 436 |
| Swift | 4.83 | 594 | 2.73 | 335 |
| Java | 4.11 | 505 | 3.67 | 450 |
| C# | 2.10 | 258 | 2.33 | 286 |
| Python | 0.63 | 76.94 | 0.12 | 14.33 |
| Kotlin | 0.52 | 63.40 | 3.80 | 467 |
| TypeScript | 0.45 | 55.30 | 0.48 | 59.32 |
| Dart | 0.35 | 43.00 | 0.73 | 89.80 |


## Structural micro-benchmarks


### `int_stream` — Flat stream of i64 — integer codec in isolation (no container framing)

_50,000 records · 439 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| C | 111 | 995 | 153 | 1,372 |
| C++ | 103 | 922 | 139 | 1,249 |
| Zig | 102 | 917 | 269 | 2,420 |
| Java | 96.09 | 864 | 45.88 | 413 |
| C# | 94.23 | 847 | 19.60 | 176 |
| Rust | 65.85 | 592 | 124 | 1,117 |
| Swift | 51.45 | 463 | 87.14 | 784 |
| Kotlin | 26.13 | 235 | 40.45 | 364 |
| Go | 21.07 | 189 | 18.57 | 167 |
| Python | 5.96 | 53.63 | 2.07 | 18.59 |
| TypeScript | 3.44 | 30.95 | 4.64 | 41.76 |
| Dart | 1.13 | 10.18 | 4.05 | 36.38 |


### `string_stream` — Flat stream of short strings — framing/escaping in isolation

_20,000 records · 334 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| Go | 93.63 | 1,603 | 64.78 | 1,109 |
| C++ | 89.02 | 1,524 | 29.25 | 501 |
| Rust | 85.63 | 1,466 | 38.01 | 651 |
| Zig | 84.99 | 1,455 | 112 | 1,914 |
| C | 80.30 | 1,375 | 49.03 | 840 |
| Java | 47.64 | 816 | 60.67 | 1,039 |
| Swift | 26.49 | 454 | 44.97 | 770 |
| C# | 23.62 | 404 | 35.31 | 605 |
| Python | 10.02 | 172 | 1.99 | 34.16 |
| Dart | 7.66 | 131 | 26.78 | 459 |
| Kotlin | 7.43 | 127 | 48.66 | 833 |
| TypeScript | 2.21 | 37.91 | 7.91 | 135 |


### `nested_doc` — Nested map/array documents — recursion + canonical map ordering

_2,500 records · 162 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| C | 8.66 | 575 | 4.58 | 304 |
| Zig | 5.95 | 396 | 7.44 | 495 |
| Java | 5.88 | 391 | 4.71 | 313 |
| Rust | 4.83 | 321 | 3.79 | 252 |
| C++ | 2.95 | 196 | 3.57 | 237 |
| Go | 2.78 | 185 | 3.14 | 209 |
| C# | 2.65 | 176 | 2.52 | 167 |
| Swift | 1.50 | 99.48 | 2.25 | 150 |
| Kotlin | 0.94 | 62.23 | 4.05 | 269 |
| TypeScript | 0.68 | 45.38 | 0.44 | 29.12 |
| Dart | 0.36 | 23.68 | 1.60 | 106 |
| Python | 0.34 | 22.90 | 0.10 | 6.89 |


## Method

Optimized build per language, deterministic shared data, single-threaded. Per `(workload, op)`: warm-up, auto-calibrate iterations to a ~100 ms trial, then several trials reporting the **median** ns/op, with a checksum sink so the optimizer can't elide the work. **Encode** builds the framed stream from prepared in-memory records; **decode** walks the whole stream, descending/unescaping every container and touching every scalar. Regenerate the Zig reference with `zig build bench`, each port via its `bench/<lang>/` runner, then `python3 bench/merge.py`.


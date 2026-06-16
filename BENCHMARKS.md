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
| Go | 11.59 | 568 | 5.36 | 263 |
| Rust | 11.39 | 558 | 8.13 | 399 |
| C++ | 10.22 | 501 | 7.32 | 359 |
| Java | 6.09 | 299 | 7.13 | 349 |
| Swift | 5.05 | 248 | 3.48 | 171 |
| C# | 3.70 | 182 | 4.83 | 237 |
| Kotlin | 1.28 | 62.65 | 5.17 | 254 |
| TypeScript | 0.53 | 26.00 | 0.58 | 28.48 |
| Dart | 0.48 | 23.77 | 1.12 | 54.91 |
| Python | 0.41 | 19.88 | 0.13 | 6.31 |


### `geo_points` — Geospatial fixes: f64 lat/lon/elevation, place name, timestamp

_4,000 records · 185 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| Go | 38.95 | 1,849 | 10.48 | 498 |
| Zig | 34.98 | 1,661 | 15.04 | 714 |
| Rust | 31.47 | 1,494 | 9.56 | 454 |
| C++ | 25.77 | 1,224 | 8.33 | 395 |
| C | 23.54 | 1,118 | 8.88 | 422 |
| Java | 12.11 | 575 | 8.83 | 419 |
| Swift | 10.00 | 475 | 5.68 | 270 |
| C# | 7.10 | 337 | 6.59 | 313 |
| Kotlin | 1.37 | 64.96 | 8.46 | 401 |
| Python | 0.67 | 31.89 | 0.21 | 10.06 |
| Dart | 0.56 | 26.48 | 0.91 | 43.23 |
| TypeScript | 0.36 | 16.99 | 0.43 | 20.56 |


### `tweets` — Social posts: u64 id, handle, variable-length text, timestamp, like/retweet counts

_3,000 records · 389 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| C | 12.94 | 1,719 | 1.54 | 204 |
| Zig | 11.72 | 1,557 | 4.67 | 621 |
| C++ | 10.84 | 1,439 | 2.16 | 287 |
| Go | 8.14 | 1,082 | 3.62 | 481 |
| Rust | 7.33 | 973 | 3.56 | 473 |
| Swift | 5.14 | 683 | 2.93 | 389 |
| Java | 2.86 | 380 | 4.67 | 620 |
| C# | 1.49 | 198 | 2.51 | 334 |
| Python | 0.95 | 126 | 0.14 | 18.35 |
| Dart | 0.53 | 69.86 | 0.96 | 127 |
| Kotlin | 0.51 | 67.34 | 4.05 | 539 |
| TypeScript | 0.33 | 43.70 | 0.56 | 74.83 |


### `blockchain_txs` — Ledger transactions: 32-byte hash, 20-byte addresses, arbitrary-precision wei value, gas/nonce, timestamp

_3,000 records · 360 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| Zig | 9.82 | 1,207 | 4.67 | 574 |
| C | 9.38 | 1,152 | 2.27 | 278 |
| C++ | 8.42 | 1,034 | 2.65 | 326 |
| Rust | 7.36 | 904 | 3.55 | 436 |
| Go | 6.16 | 757 | 2.95 | 363 |
| Swift | 4.83 | 594 | 2.73 | 335 |
| Java | 2.70 | 332 | 3.76 | 462 |
| C# | 1.70 | 208 | 2.42 | 297 |
| Python | 0.63 | 76.94 | 0.12 | 14.33 |
| Kotlin | 0.54 | 66.28 | 3.73 | 459 |
| TypeScript | 0.45 | 55.30 | 0.48 | 59.32 |
| Dart | 0.32 | 39.77 | 0.72 | 88.39 |


## Structural micro-benchmarks


### `int_stream` — Flat stream of i64 — integer codec in isolation (no container framing)

_50,000 records · 439 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| C | 111 | 995 | 153 | 1,372 |
| C++ | 103 | 922 | 139 | 1,249 |
| Zig | 102 | 917 | 269 | 2,420 |
| Rust | 65.85 | 592 | 124 | 1,117 |
| Swift | 51.45 | 463 | 87.14 | 784 |
| Kotlin | 23.34 | 210 | 40.90 | 368 |
| Go | 16.90 | 152 | 18.39 | 165 |
| Java | 6.65 | 59.75 | 46.22 | 416 |
| Python | 5.96 | 53.63 | 2.07 | 18.59 |
| C# | 4.86 | 43.73 | 18.76 | 169 |
| TypeScript | 3.44 | 30.95 | 4.64 | 41.76 |
| Dart | 1.25 | 11.25 | 4.02 | 36.13 |


### `string_stream` — Flat stream of short strings — framing/escaping in isolation

_20,000 records · 334 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| Go | 102 | 1,750 | 66.43 | 1,138 |
| C++ | 89.02 | 1,524 | 29.25 | 501 |
| Rust | 85.63 | 1,466 | 38.01 | 651 |
| Zig | 84.99 | 1,455 | 112 | 1,914 |
| C | 80.30 | 1,375 | 49.03 | 840 |
| Java | 47.24 | 809 | 60.24 | 1,032 |
| Swift | 26.49 | 454 | 44.97 | 770 |
| C# | 25.16 | 431 | 36.29 | 621 |
| Python | 10.02 | 172 | 1.99 | 34.16 |
| Dart | 7.44 | 127 | 27.47 | 470 |
| Kotlin | 7.40 | 127 | 48.08 | 823 |
| TypeScript | 2.21 | 37.91 | 7.91 | 135 |


### `nested_doc` — Nested map/array documents — recursion + canonical map ordering

_2,500 records · 162 KB_


| language | encode Mrec/s | encode MB/s | decode Mrec/s | decode MB/s |
|---|--:|--:|--:|--:|
| C | 8.66 | 575 | 4.58 | 304 |
| Zig | 5.95 | 396 | 7.44 | 495 |
| Rust | 4.83 | 321 | 3.79 | 252 |
| Java | 4.41 | 293 | 4.66 | 310 |
| C++ | 2.95 | 196 | 3.57 | 237 |
| Go | 2.44 | 162 | 3.19 | 212 |
| C# | 2.09 | 139 | 2.63 | 175 |
| Swift | 1.50 | 99.48 | 2.25 | 150 |
| Kotlin | 0.94 | 62.36 | 4.13 | 275 |
| TypeScript | 0.68 | 45.38 | 0.44 | 29.12 |
| Dart | 0.37 | 24.40 | 1.60 | 106 |
| Python | 0.34 | 22.90 | 0.10 | 6.89 |


## Method

Optimized build per language, deterministic shared data, single-threaded. Per `(workload, op)`: warm-up, auto-calibrate iterations to a ~100 ms trial, then several trials reporting the **median** ns/op, with a checksum sink so the optimizer can't elide the work. **Encode** builds the framed stream from prepared in-memory records; **decode** walks the whole stream, descending/unescaping every container and touching every scalar. Regenerate the Zig reference with `zig build bench`, each port via its `bench/<lang>/` runner, then `python3 bench/merge.py`.


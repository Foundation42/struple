# struple benchmarks

Encode/decode throughput for representative workloads, measured per language. The
results table lives in [`../BENCHMARKS.md`](../BENCHMARKS.md); this file documents
*what* is measured and *how*, so every port measures the same thing.

## Workloads

Four realistic streaming shapes (struple is a streaming tuple format, so a stream
of records is its native use case) plus three structural micro-benchmarks that
isolate a single codec path:

| workload | category | exercises |
|---|---|---|
| `stock_quotes` | streaming | exact `decimal` bid/ask, `f64` last, `string` symbol, `int` volume, `timestamp` |
| `geo_points` | streaming | `f64` lat/lon/elevation, `string` place name, `timestamp` |
| `tweets` | streaming | `u64` id, handle, **variable-length** `string` text, `timestamp`, counts |
| `blockchain_txs` | streaming | 32-byte `bytes` hash, 20-byte addresses, **arbitrary-precision** wei (big-int), `int`, `timestamp` |
| `int_stream` | structural | the integer codec with no container framing (the codec ceiling) |
| `string_stream` | structural | string framing / `0x00` escaping in isolation |
| `nested_doc` | structural | nested map/array recursion + canonical map ordering |

Each record in a streaming workload is a top-level array (tuple) element, so the
stream is indexable record-by-record — and decoding it pays the realistic cost of
descending and un-escaping each container body.

## Method

- **Release/optimized build** (Zig: `ReleaseFast`), **deterministic data** (fixed
  PRNG seed), and a **fast general allocator** (not a debugging allocator — that
  mis-attributes its own overhead to the codec's transient allocations).
- Per `(workload, op)`: warm-up runs, then auto-calibrate the iteration count to a
  ~100 ms trial, then several trials; the **median** ns/op is reported.
- A global checksum **sink** consumes every result so the optimizer can't elide
  the work. Steady-state buffers retain capacity, so figures reflect codec compute,
  not allocator warm-up.
- **Encode** = build the framed stream from prepared in-memory records.
  **Decode** = walk the whole stream, descending/un-escaping every container body
  and touching every scalar value.

> Numbers are machine-specific — treat them as relative, not absolute. What
> travels across machines is the *shape*: which workloads are cheap, which are
> framing/escaping bound, and how the ports line up on identical bytes.

## Layout

```
bench/
  payloads.json     # shared workload manifest (name, schema, byte_len, sha256) — the cross-language contract
  zig/bench.zig     # Zig reference harness (run with `zig build bench`)
  <lang>/...         # one runner per port (added as they land)
```

`payloads.json` is the contract: every port reproduces the same logical records
and must match each workload's `byte_len` and `sha256` (the same byte-identity
guarantee the conformance corpus enforces) before its throughput is meaningful — a
port can't look fast by encoding different bytes.

## Cross-language contract

Each port reads `bench/data/<name>.json`, rebuilds the records with its own
`appendX` calls, and **must reproduce the payload's `sha256`** from
`payloads.json` (byte-identity — the same guarantee the conformance corpus
enforces). Then it benchmarks encode and decode and writes
`bench/results/<lang>.json`.

All data fields are **typed strings** so any JSON library reads them identically:

| field form | meaning | how to build |
|---|---|---|
| `"<dec>"` int/u64/timestamp | decimal integer | `appendInt` / `appendUint` / `appendTimestamp` |
| `"<16 hex>"` | f64 IEEE-754 bits, big-endian | parse u64, bit-reinterpret → `appendF64` |
| digits `"12345"` + exp `"-2"` | decimal = digits·10^exp | digit array `[1,2,3,4,5]` → `appendDecimal(false, digits, exp)` |
| `"big"`/`"fix"` + `"<hex>"` | wei value | `big` → `appendBigInt(false, magBytes)`; `fix` → big-endian bytes → integer → `appendI128` |
| `"<hex>"` (hash/addr) | bytes | hex-decode → `appendBytes` |

**Build sequence per record** (mirror `bench/zig/bench.zig` `encodeOnce`):

- `stock_quotes` → array `[string(sym), decimal(bid), decimal(ask), f64(last), int(vol), timestamp(ts)]`
- `geo_points` → array `[f64(lat), f64(lon), f64(elev), string(name), timestamp(ts)]`
- `tweets` → array `[uint(id), string(user), string(text), timestamp(created), int(likes), int(rt)]`
- `blockchain_txs` → array `[int(height), bytes(hash), bytes(from), bytes(to), value, int(gas), int(nonce), timestamp(ts)]`
- `int_stream` → top-level stream of `int(v)` (no array wrapper)
- `string_stream` → top-level stream of `string(s)`
- `nested_doc` → map `{ "active": bool, "scores": array[int,int,int], "user": map{"id": int, "name": string} }` (the encoder sorts map keys)

**Data row column order** (each row is an array of typed strings):

| payload | columns |
|---|---|
| `stock_quotes` | `[sym, bidDigits, bidExp, askDigits, askExp, lastF64hex, volume, ts]` |
| `geo_points` | `[latF64hex, lonF64hex, elevF64hex, name, ts]` |
| `tweets` | `[id_u64, user, text, created_ts, likes, retweets]` |
| `blockchain_txs` | `[height, hashHex, fromHex, toHex, valueKind("big"\|"fix"), valueHex, gas, nonce, ts]` |
| `nested_doc` | `[active("0"\|"1"), uid, name, score0, score1, score2]` |
| `int_stream` | flat array of `int` strings |
| `string_stream` | flat array of `string` values |

**Two cross-language gotchas (learned from the JS port):**

- **Append method names above are illustrative.** Map them to your port's actual
  codec API. If your encoder has a single integer entry point that auto-selects
  the fixed-width vs big-int code by magnitude (like JS `appendInt(bigint)`), use
  it for *both* the `fix` and `big` blockchain values and for `uint` ids — no need
  for separate calls.
- **`u64` tweet ids and `big` wei values exceed 2^53 / 2^64.** Parse those string
  fields with your language's exact big-integer (or ≥64-bit-exact) type — never via
  a double or a JSON parser that yields floats — or the bytes won't match.

**Decode** = walk the whole stream, descending into every container (unescaping
its body) and touching every scalar. Prefer a single-pass unescape into a reused
buffer (skip a separate `hasEscapes`/length pre-scan) where the language allows.

### Results file

`bench/results/<lang>.json`:

```json
{ "lang": "TypeScript", "host": "<cpu>",
  "payloads": { "stock_quotes": { "enc_mrec_s": 0.0, "enc_mb_s": 0.0,
                                  "dec_mrec_s": 0.0, "dec_mb_s": 0.0, "sha256_ok": true }, … } }
```

### Optimizations to carry over (per language, keep bytes identical)

The reference picked up three behavior-preserving wins; apply the ones that
measurably help in each language and re-run that port's conformance suite to
confirm bytes are unchanged:

1. **Run-length escaping** — bulk-copy the runs between `0x00` bytes instead of a
   per-byte loop (helps compiled ports most).
2. **Reused encode scratch** — avoid a per-call allocation in `appendDecimal` /
   `appendMap` / `appendSet` (matters where the language allocates a temp buffer
   per call; a no-op for GC'd ports that already amortize).
3. **Single-pass decode unescape** — see Decode above.

## Running

```sh
zig build bench        # Zig reference; regenerates ../BENCHMARKS.md, payloads.json, data/*.json
```

Other ports: `bench/<lang>/` (added as the fan-out lands); each writes
`bench/results/<lang>.json`, merged into `../BENCHMARKS.md`.

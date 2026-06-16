# RFC 0001 — struple as a language & browser intrinsic

- **Status:** Draft / Request for Comments
- **Author:** Christian Beaumont (Foundation42)
- **Date:** 2026-06-16
- **Discussion:** https://github.com/Foundation42/struple

## Abstract

Serialization is the most-run code on Earth that nobody optimizes. Every API
call, log line, cache write, database key, and inter-service message is encoded,
moved, decoded, and often re-sorted — billions of times a second, across billions
of devices. The de-facto defaults — **JSON, Protobuf, MessagePack** — are
*unsympathetic* to how data is actually communicated, computed on, and stored.
The result is a large, invisible, compounding energy tax.

This RFC proposes **struple** — a schema-free, self-describing, canonical,
**memcmp-orderable** binary tuple format — as a **first-class intrinsic** in
language runtimes and browsers, the way `JSON.parse` is intrinsic today, with the
existing twelve byte-identical implementations serving as the polyfill in the
meantime. We argue the case on three physical axes (communication, compute,
storage), back it with *measured* energy data, and estimate the reclaimable
global energy with a parameterized, citeable model.

## 1. The problem: an unsympathetic protocol is a physical tax

Data does three things, and each has a real-world cost:

1. **Communication** — bytes on the wire × messages × hops. JSON is ~3× larger
   than struple for the same record (measured here), so ~3× the bandwidth and
   network energy on *every transfer*, across fixed and mobile networks.
2. **Compute** — encode + decode + **ordering**. The forgotten axis: to be
   queryable, data must be sorted/indexed. **Only struple's bytes sort
   themselves** (`memcmp` == value order). Every other format needs a separate
   order-preserving key layer — which is struple, or a hand-rolled, bug-prone
   reimplementation of it — plus a comparator decode on top. That is CPU burned
   in every database, every range scan, everywhere.
3. **Storage** — footprint × replication × retention. Smaller bytes mean less
   disk, less RAM, less cache pressure, less I/O — and because struple *is* the
   ordered key, there is no separate index to store.

A "fastest encode" microbenchmark sees one slice of one axis. The real cost is
`(encode + N transfers + M decodes + storage + every re-sort) × global volume`,
and it is **super-linear in participants** — a classic network effect. With ~8
billion people behind billions of microservices, all defaulting to the least
sympathetic format, the aggregate waste is climate-relevant and self-reinforcing:
it is a concrete driver of the slow, hot, expensive degradation we now call
*enshittification*. Efficiency at the protocol layer is not a micro-optimization;
at this scale it is infrastructure.

## 2. Evidence

This is not a thought experiment. The repository ships, today:

- **Twelve byte-identical implementations** (Zig, Rust, C, C++, Go, Java, Kotlin,
  C#, Swift, TypeScript, Python, Dart) driven by a single language-neutral
  **conformance corpus** — every implementation reproduces the same bytes for
  every vector, in both directions. (See `README.md`, `conformance/`.)
- **Cross-language throughput benchmarks** (`BENCHMARKS.md`): on a single core,
  struple encodes/decodes tens to hundreds of millions of records per second in
  the compiled tier, and the work is embarrassingly parallel.
- **An end-to-end, real-energy benchmark** over an ordered KV store (the
  `vectordb` radix map), measured with **RAPL package energy (actual joules)**.
  For the same records, getting them in as range-queryable keys and back out:

  | format | sorts itself? | stored | CPU energy to be *ordered-storable* (rel.) |
  |---|---|--:|--:|
  | **struple** | **yes** | **1.0×** | **1.0×** — one codec (key = value = order) |
  | MessagePack | no — needs a struple key | ~1.6× | struple key **+** msgpack value (> 1.0×) |
  | JSON | no — needs a struple key | ~2.9× | **~10×** |

  On the *value codec alone*, struple **ties** the best binary formats (within
  noise — and before any SIMD work, which an intrinsic implementation would
  unlock). The incumbents do not beat that; they add it *on top of* a mandatory
  struple key, so their real cost to be ordered-storable is strictly higher. We
  have not yet claimed the SIMD headroom struple is sitting on.

- **An ordering-correctness proof**: insert integers keyed by each format's own
  bytes, scan in byte order, count value-order inversions. struple: **0**.
  MessagePack and JSON: **non-zero** — their bytes do not sort. The honest
  consequence: an incumbent in an ordered store is not "MessagePack", it is
  **"MessagePack + struple"**. struple is a strict floor no format switch escapes.

The headline is therefore not "struple is the fastest codec" (on raw CPU it ties
the best binary formats). It is: **struple matches the fastest binary codec while
being smaller, sorting itself, and eliminating an entire mandatory layer** — and
it is **~10× more energy-efficient than JSON**, the format most systems actually
serialize.

### The scale estimate

`rfc/scale_model.py` turns the measured per-operation deltas into a global figure.
It is explicitly a **model, not a measurement**: the per-op inputs are real
(RAPL), the macro inputs are cited estimates with wide uncertainty, so the result
is a **range**, and even the conservative low end is climate-relevant.

> Reclaiming **~0.7–31 TWh/yr** of data-centre electricity (mid ≈ 6 TWh/yr), i.e.
> **~0.35–15 MtCO₂e/yr** (mid ≈ 3) — roughly the electricity of millions of
> homes. **And that is the server side only**: it excludes the ~3× wire-size
> reduction's network energy across billions of client devices, and the
> super-linear network effect across the fabric.

Sources and assumptions (IEA data-centre electricity; Kanev et al., *Profiling a
Warehouse-Scale Computer*, ISCA 2015, on the "data-centre tax"; grid carbon
intensity) are inline in the model. Dial them to your own numbers.

## 3. Proposal: make struple an intrinsic

Efficiency never wins on merit alone — it wins when it is the **path of least
resistance**. JSON won because `JSON.parse`/`JSON.stringify` are *intrinsic*: free,
everywhere, no dependency, no decision. We propose the same status for struple.

**Normative spec (already exists):**
- The wire format and type tower (`README.md`, the "wire format" section) and the
  cross-language **conformance corpus** (`conformance/`) are the normative
  definition. Conformance = byte-for-byte reproduction of the corpus, both ways.

**Minimal intrinsic API surface** (names illustrative, per host idiom):
- `struple.pack(...values) -> bytes` / `struple.unpack(bytes) -> values`
- ordering: **`memcmp` is the comparator** — no API needed; that is the point.
- streaming read + zero-copy navigation (`view` / `MapView` / `IndexedMap`).
- `fromJson` / `toJson` for migration.

**Why intrinsic, not just a library:**
- Removes the adoption decision entirely (it is *there*, like `JSON`).
- Lets the runtime/browser use SIMD and zero-copy paths a library can't.
- Makes the *efficient* choice the *easy* choice — the only way the energy win
  actually lands at scale.

## 4. Adoption ladder

A moonshot needs a credible path, not a flag day:

1. **Polyfill (today)** — the twelve byte-identical ports already work in every
   listed ecosystem. Nothing blocks use now.
2. **Libraries** — publish to npm / PyPI / crates.io / Maven / NuGet / pub.dev /
   SwiftPM / Go modules. Make it one import.
3. **Runtime intrinsics** — land it in Node/Deno/Bun, CPython, the JVM, .NET, Go,
   etc., as a built-in module (the `JSON` precedent).
4. **Browser** — propose `struple` to TC39 / WHATWG alongside structured-clone
   and `JSON`, targeting `fetch`/storage/`postMessage` paths.
5. **Standardization** — an IETF/Ecma track once there is running-code consensus.

**Network-effect strategy:** seed where ordered storage already hurts —
databases, CRDTs, edge/KV stores, log/event pipelines — where struple removes a
real, expensive layer *today*. Let the measured energy-and-cost argument pull
adoption outward through the fabric.

## 5. Non-goals & honest caveats

We will lose the room the moment we overclaim, so, plainly:

- struple deliberately **decouples the wire format from the schema**. Protobuf/gRPC
  fuse the two — the format *is* the contract, bundled with a compiler — which we
  consider *doing too much*: a schema is orthogonal to a message. struple aims to
  replace their **serialization core** as well, with schema, validation, and
  codegen as a **separable, optional layer on top** for teams that want an
  enforced contract. You should not have to adopt a schema compiler just to move
  bytes. (Honest caveat: that optional schema layer is future work — teams who
  need enforced contracts *today* still reach for Protobuf. The thesis is
  decoupling, not yet feature-parity.)
- On raw CPU, struple **ties** the best binary codecs (MessagePack/Cap'n Proto);
  its advantages are **ordering, unification (key = value = order), and size**,
  not "fastest bytes".
- The global scale figure is a **parameterized estimate**, deliberately
  conservative, presented as a range with sources — not a measurement.
- Cap'n Proto's zero-copy *encode* can beat struple on that one axis; it still
  cannot sort itself, so it pays the same mandatory key layer in an ordered store.

## 6. Prior art & alignment

struple does **not** claim to invent order-preserving encoding — the idea predates
this project. The contribution here is **recognition and generalization**: noticing
an under-exploited technique, seeing its potential *at scale*, and turning it into
something canonical and self-describing across twelve byte-identical
implementations with a shared conformance corpus — and then making the **energy
and scale** argument and proposing it as an intrinsic. The novelty is the
synthesis and the framing, not the kernel.

- **FoundationDB tuple layer** — order-preserving tuple keys over an ordered KV.
  struple generalizes this: cross-language, canonical, a full type tower, and
  self-describing values, not just keys.
- **Order-preserving / memcmp-comparable key encodings** (e.g. "Orderly", various
  DB key codecs) — usually language-specific and partial. struple is the
  twelve-language, conformance-tested union.
- **CBOR / MessagePack** — compact and self-describing, but **not** memcmp-ordered
  and not canonical. struple adds exactly the properties an ordered store needs.

## 7. Call to action

If the protocol layer is a tax, struple is a rebate — measurable today, and
compounding with every node that adopts it. We are asking for: review of this
RFC and the evidence, replication of the energy numbers, and partners to push the
adoption ladder from polyfill toward intrinsic.

Make the efficient thing the easy thing. The planet is downstream of the defaults.

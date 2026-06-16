# Contributing to struple

Thanks for your interest in struple! This is a small, precise project: **one wire
format, twelve byte-identical implementations** driven by a single language-neutral
conformance corpus. That precision is the whole point, so the contribution rules are
mostly about protecting it.

Please read the two short rules in [The golden rule](#the-golden-rule) and
[Signing the CLA](#signing-the-cla) before you open a pull request — they'll save us
both a round-trip.

## The golden rule

**`conformance/vectors.json` and `conformance/semantic_vectors.json` are generated
artifacts — never edit them by hand.**

They are the contract every implementation must reproduce, and they are produced from
the Zig reference:

```sh
zig build vectors      # regenerates both corpus files from the Zig generator
```

CI enforces this — the Zig job runs `zig build vectors` and then
`git diff --exit-code` on both files. If your change alters the corpus, it must do so
*through the Zig reference*, with a clear rationale, never by editing the JSON
directly. A PR that hand-edits the corpus to make a port "pass" is exactly the kind of
thing we're guarding against — the corpus is the oracle, not the variable.

See [`conformance/README.md`](conformance/README.md) for how the corpus is structured
(JSON entries, the build-op language, and what each check verifies).

## What "byte-identical" means here

Every implementation must reproduce `vectors.json` **in both directions** (encode →
bytes, and bytes → value/JSON) and agree with `semantic_vectors.json` on value-order.
A port isn't "done" when it round-trips its own output — it's done when it produces
the *same bytes* as the Zig reference for every vector, and decodes every vector the
reference emits. The corpus is what makes "twelve implementations" honest.

## Repository layout

| path | what |
|---|---|
| `src/`, `build.zig` | the **Zig reference** implementation + corpus generator |
| `conformance/` | the generated corpus (`vectors.json`, `semantic_vectors.json`) + its spec |
| `js/ py/ rust/ c/ cpp/ go/ java/ kotlin/ csharp/ dart/ swift/` | the eleven ports |
| `docs/` | the GitHub Pages demo site |
| `.github/workflows/` | CI (per-language jobs) + Pages deploy + CLA |

## Running the tests

Each language has its own toolchain; the commands below mirror what CI runs (see
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) for the canonical, pinned
versions).

| port | from dir | command |
|---|---|---|
| Zig (reference) | `.` | `zig build test` &nbsp;·&nbsp; `zig build vectors` |
| TypeScript | `js/` | `npm test` |
| Python | `py/` | `python -m unittest discover -s tests -t .` |
| Rust | `rust/` | `cargo test` |
| C | `c/` | `make test` |
| C++ | `cpp/` | `make test` |
| Go | `go/` | `go test ./...` (and `gofmt -l .` must be empty) |
| Java | `java/` | `./run-tests.sh` |
| Kotlin | `kotlin/` | `KOTLINC=… ./run-tests.sh` |
| C# | `csharp/` | `DOTNET=dotnet ./run-tests.sh` |
| Dart | `dart/` | `DART=dart ./run-tests.sh` |
| Swift | `swift/` | `./run-tests.sh` |

The C and C++ jobs also run under `-fsanitize=address,undefined`; if you touch those
ports, please run the sanitizer build locally too.

## Making a change to an existing port

1. If the change is **behavioural** (touches the wire format or semantics), it starts
   in the **Zig reference**. Make it there, run `zig build vectors`, and let the
   regenerated corpus drive the other ports.
2. Mirror the change in every affected port until each one passes against the new
   corpus. A wire-format change that lands in one language but not the others is not
   mergeable — they move together or not at all.
3. Keep each port **idiomatic**: match the surrounding code's naming and style
   (`is_string` vs `isString`, `gofmt` for Go, etc.). New code should read like the
   code already around it.

## Adding a new language port

We'd love more ports. A complete one:

- [ ] Implements pack/encode, streaming read, JSON (`fromJson`/`toJson`), navigation
      (`view`/`MapView`/`IndexedMap`), and `semanticOrder` — with idiomatic names.
- [ ] Has a conformance test that loads **both** `conformance/vectors.json` and
      `conformance/semantic_vectors.json` and verifies every vector in both
      directions. (Read a sibling port's conformance test first — the structure is the
      same everywhere.)
- [ ] Is **zero-dependency** where the language allows it (stdlib big-integer/decimal
      is fine; that's how the existing ports do it).
- [ ] Ships a `README.md` in the new directory, including an `## Unpacking` section in
      the same six-form style as the others.
- [ ] Adds a CI job to `.github/workflows/ci.yml`.
- [ ] Adds itself to the **Implementations** list in the root `README.md`.

If you're considering a port, open an issue first so we can cheer you on (and so two
people don't port Elixir the same week).

## Pull requests

- Open PRs against `main`. CI runs every language job on every PR.
- Write a clear PR description: what changed and why. If it touches the wire format,
  say so prominently.
- We don't require a particular commit-message format, but keep messages descriptive.
- Be excellent to each other. 🤝

## Signing the CLA

struple uses a lightweight **Contributor License Agreement** (see
[`CLA.md`](CLA.md)). The first time you open a PR, a bot will comment with a link and
a one-line instruction; you reply once, in the PR, with:

> I have read the CLA Document and I hereby sign the CLA

and you're set for all future PRs. **You keep the copyright to your contribution** —
the CLA is a broad license grant (plus a patent grant and a confirmation that the work
is actually yours to give), not a copyright transfer. It exists so the project can
stay healthy long-term: license the code, defend it, and relicense if the community
ever needs to, without having to track down every past contributor.

By signing, you also confirm your contribution is your own original work (or that you
have the right to submit it) — which keeps the codebase clean of "cuckoo's eggs" that
nobody actually had the rights to contribute.

## License

struple is licensed under the [Apache License 2.0](LICENSE). Contributions are
accepted under the terms of that license and the [CLA](CLA.md).

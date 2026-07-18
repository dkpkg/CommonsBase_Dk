# CommonsBase_Dk.Dk0 — OpamCache design

Status: draft for review. No implementation yet. This records the plan for
building `dk0` (MlFront) as a reproducible, multi-slot dk package by resolving
and installing its opam dependency closure through a per-package binary cache.

## Problem

`dk0` is MlFront's `DkZero_Exec` executable. MlFront is a multi-package OCaml
project whose `dune-project` is generated from a `.template`, and whose build
needs a large opam dependency closure (`ppxlib`, `ptime`, `digestif`, `crunch`,
`tsort`, `topkg`, `odoc`, `merlin-lib`, the `MlFront_*` / `DkZero_*` /
`UnifiedScript_*` locals, and `moonpool`/`cpp408` vendored under `src/*/ext`).
Only two deps are vendored; the rest are external. A bare `dune build` cannot
work, and MlFront's own CI builds it the canonical way: pinned opam-repository +
`opam pin add … MlFront.tar.gz` + `opam install`.

The packaging problem is therefore: provide that dependency closure to a dk
build **hermetically and reproducibly**, and do it in a way that survives CI
time limits.

## Rejected alternative: monolithic Dune cache

Storing MlFront + deps as one Dune cache
(https://dune.readthedocs.io/en/latest/reference/caches.html) fails on two
counts:

1. Dune's cache has no per-entry read hook, so the **entire** cache must be
   downloaded on every build — potentially large and slow.
2. It is one indivisible blob. There is no partial-progress unit, so a CI job
   that exceeds its time limit while building the cache throws everything away.
   There is no incremental/resumable path. That is a hard failure mode.

## Approach: per-package content-addressed opam binary cache (OpamCache)

Make **each opam package a separate dk asset** — its built binary files plus
metadata as a directory/zip asset, keyed by a content hash. Because every
package is its own content-addressed unit, the build is:

- **Incremental / resumable** — a timed-out CI run leaves every already-built
  package asset persisted in the value store; the next run resolves those as
  cache hits and only builds the remainder. This is the property that the
  monolithic cache lacks and the reason for this whole design.
- **Shareable** — packages with identical resolved sub-closures reuse the same
  asset across builds and across slots where the binary is identical.

## Reproducibility invariant

dk's core guarantee is reproducibility, so the values layer must **never branch
on whether an asset is present**. Presence is nondeterministic; branching on it
inside a `values.json` would poison reproducibility.

Instead, the operation is a single pure resolution:

> `resolve asset[KEY]`, running the populate-command on a miss.

That is logically a function of `KEY` alone. Whether the asset was already
present or had to be built is an engine-internal optimization the values layer
never observes. This is dk0's existing content-addressed object cache, extended
to a **key computed at runtime** (from the opam solve) rather than one derived
statically from the values graph. "Dynamic identity, populate-on-miss" is the
one genuinely new capability required.

## Cache key

`key(P)` must be a Merkle hash over the full resolved dependency closure, not
just `name@version`:

```
key(P) = H( P@version,
            ocaml-id,               // DkML 4.14.3 + variant
            target-slot,            // Windows_x86_64, Linux_x86_64, ...
            opam-config-digest,     // build env / flags / wrappers
            sorted[ key(D) for D in deps(P) ] )
```

Keying only by `name@version` would silently reuse a stale binary when a
transitive dependency changes. The Merkle key gives correct invalidation, and
it is what lets sub-closures be shared safely.

## Engine primitive (lives in dksdk-coder/ext/MlFront)

The new dk0/VSL primitive is a **parameterized cache subshell keyed by the
cache key**:

```
$(opam-cache KEY -- <populate-command producing the package artifact>)
```

Semantics:

- If the value store holds `asset[KEY]` → return it. Hit. No side effects, no
  build.
- Otherwise → run the populate-command, store its output as `asset[KEY]`,
  return it. Miss.

`KEY` is a runtime value (computed from the solve + dep keys). The populate
command is deterministic given its inputs, and every input that affects the
output is folded into `KEY`, so the asset stays content-addressed and the
values layer stays deterministic. This is an **engine feature**, not merely a
CommonsBase_Dk change; it should be treated and reviewed as such even under
worktree isolation.

## Build flow (three phases)

1. **Solve (opam call 1).** Run the opam solver against a **pinned**
   opam-repository commit (a dk asset) plus MlFront's constraints and the
   `PIN_*` overrides. Deterministic given the pin → an ordered `(pkg, version)`
   list and the dependency DAG. Emitted from a subshell.
2. **Instantiate.** Topologically, one `opam-cache KEY(P) -- build(P)` subshell
   per package. Hit = asset exists. Miss = build `P` in a scratch switch whose
   dependencies are the already-resolved assets, and capture `P`'s files +
   metadata as `asset[key(P)]`.
3. **Install (opam call 2).** A wrapped `opam install` whose
   `wrap-build`/`wrap-install` hooks extract the cached asset for each package
   instead of compiling. With phase 2 complete, every package is a hit, so this
   is pure extraction into the switch prefix.

## MlFront as just another opam package (decided)

MlFront's own packages (`DkZero_Exec`, `MlFront_*`, `UnifiedScript_*`,
`DkZero_Base`, `DkZero_RuntimeC`, …) are additional nodes in the same solve
(`opam pin add … MlFront.tar.gz`). Consequences:

- No special-cased `dune build` or `dune-project.template` step. Template
  generation happens inside `DkZero_Exec`'s normal package build.
- `dk0.exe` is simply the `DkZero_Exec` package's `bin/` output.
- `CommonsBase_Dk.Dk0@2.4.2` reduces to: wrapped `opam install DkZero_Exec`
  (through OpamCache), then extract `bin/dk0.exe`.

## Per-slot (MSVC) considerations

- The cache is per-slot: each target slot has different binaries → different
  keys → different assets (`target-slot` is in the key).
- On Windows, DkML's OCaml is MSVC, so every **miss** must build its package
  under an active vcvars environment. The populate-command carries the same
  vswhere → vcvarsall activation used by the (now-superseded) `Dk0.Win32` bat,
  per package. Confirm a switch-per-package build is viable under MSVC.
- Scope: build the DkML-supported slots (Windows_x86_64, Windows_x86,
  Linux_x86_64, Linux_x86, Linux_arm64, Darwin_x86_64, Darwin_arm64).
  Windows_arm64 stays cache-only (no DkML arm64-Windows slice). The CI matrix
  currently disables Linux_arm64.

## Proposed module layout (CommonsBase_Dk)

- `CommonsBase_Dk.Dk0.OpamSolve@2.4.2` — pinned solve → the `(pkg, version)`
  list + DAG (from the pinned opam-repository asset + MlFront constraints).
- `CommonsBase_Dk.Dk0.OpamCache@2.4.2` — the per-package binary assets;
  populate-on-miss via the engine primitive; keyed per the Merkle key.
- `CommonsBase_Dk.Dk0@2.4.2` — wrapped `opam install DkZero_Exec` reading from
  OpamCache, extract `bin/dk0.exe`, per slot.

`Dk0.Bundle` (MlFront source tarball) stays. `Dk0.DuneCache` is retired in
favor of OpamCache. The current `Dk0.values.jsonc` in this worktree is a naive
`dune build` placeholder and will be replaced.

## Open questions / risks (resolve before coding)

1. **opam wrapper semantics for binary extraction (highest risk).** opam builds
   from source natively. Making install a pure "extract prebuilt + skip build"
   via `wrap-build-commands` needs validation against opam 2.5. Reference:
   https://github.com/Khady/khady.info/blob/main/opam-compilation-cache.org.
   Confirm it composes with a value-store fetch and with our wrappers.
2. **Per-slot MSVC per-package builds.** Every Windows miss builds one package
   under vcvars in a scratch switch. Confirm viability and cost.
3. **Ownership of the engine primitive.** The parameterized cache subshell is an
   MlFront/dk0 engine change. Coordinate as an engine capability, not a package
   tweak.
4. **Pinning the solve.** Encode the opam-repository commit + `PIN_*` overrides
   as assets so the solved package set is stable run-to-run; otherwise keys
   drift and the cache never converges.
5. **Switch lifecycle.** Whether phase 2 uses one switch incrementally
   populated, or a scratch switch per package seeded from dep assets. Affects
   parallelism and correctness of captured metadata.

## Incremental delivery

1. Land the engine primitive (`opam-cache KEY -- cmd`) in MlFront with tests.
2. Prototype `OpamSolve` on one slot (Linux_x86_64): pinned repo → package list.
3. Prototype `OpamCache` populate + a single wrapped `opam install` on that
   slot; validate hits/misses and resumability by interrupting.
4. Add the remaining Unix slots, then the MSVC Windows slots.
5. Wire `Dk0@2.4.2` + the dist scripts + CI; validate incrementally.

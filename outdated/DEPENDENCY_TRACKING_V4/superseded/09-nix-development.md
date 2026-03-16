# 09: Recent Nix Development — Implications for kixpkgs

Research conducted March 2026 covering Nix 2.24 through 2.33, open PRs,
RFCs, and nixpkgs module system changes.

## Release Timeline (Nix 2.24–2.33)

| Version | Date | Key Changes |
|---------|------|-------------|
| 2.24 | 2024-07 | **Pipe operators** (`\|>`, `<\|`) as experimental feature |
| 2.25 | 2024-11 | Integer overflow errors, Value struct 24→16 bytes |
| 2.26 | 2025-01 | Relative path flake inputs (`path:./foo`), eval caching with dirty git |
| 2.27 | 2025-03 | Git submodule flake inputs, Git LFS, BLAKE3 experimental |
| 2.28 | 2025-04 | C++ API restructuring (component-based headers) |
| 2.29 | 2025-05 | Prettified JSON output, `nix formatter build/run`, S3 STS/SSO auth |
| 2.30 | 2025-07 | **Value struct reduced to 16 bytes (20% heap reduction)**, stack sampling eval profiler, PeekSort for `builtins.sort` |
| 2.31 | 2025-08 | **Parallel GC marking (18-20% eval speedup)**, SQLite WAL mode |
| 2.32 | 2025-10 | **Attrset merge optimization (20% less memory in nixpkgs eval)**, C API lazy accessors, AST bump allocator |
| 2.33 | 2025-12+ | Pascal-style strings (constant-time length), JSON output format v2, multithreaded `revCount`, tarball content-addressed caching |

### Performance trajectory

The evaluator has gotten dramatically faster and leaner over 12 months:
~30-40% reduction in eval memory footprint. Value struct shrunk, attrset
merges use tombstone-based layering, parallel GC, AST bump allocation,
Pascal strings. **This trajectory favors keeping attrsets in config.manifests**
— the eval-time cost of structured data keeps going down.

## Directly Relevant Features

### Pipe operators (experimental, available since 2.24)

```nix
# Enable: experimental-features = pipe-operators
resources |> withAutoscaler { min = 2; max = 10; } |> withPDB { minAvailable = 1; }
```

Left-associative, lower precedence than everything else. `a |> f |> g` = `g (f a)`.
Merged via [PR #11131](https://github.com/NixOS/nix/pull/11131). Still marked
experimental but stable and widely used. Directly enables the resource group
combinator syntax from `04-with-autoscaler.md`.

**kixpkgs already uses `|>` in some places** (e.g., `coreDnsConfigMap |>
kixlibCoredns.configMap.withEntry ...`). The combinator pattern is a natural
extension.

### RFC 189: Contracts — validates capability interfaces

[RFC 189](https://github.com/NixOS/rfcs/pull/189) proposes provider/consumer
interfaces for decoupling NixOS modules through structured typing:

- Modules declare what they **provide** and what they **consume**
- Dual-linking via lazy evaluation prevents infinite recursion
- Two draft implementations in nixpkgs:
  [#432529](https://github.com/NixOS/nixpkgs/pull/432529) and
  [#485453](https://github.com/NixOS/nixpkgs/pull/485453)

**This is exactly the capability interface pattern from `03-inversion-of-control.md`.**
The NixOS community is independently converging on the same idea: abstract
interfaces where providers and consumers don't know about each other.

If RFC 189 lands, kixpkgs capability interfaces could potentially be built
on top of the Contracts infrastructure rather than hand-rolled submodules.
Worth tracking, but our design is compatible regardless.

### Modular Services (nixpkgs PR #372170, merged Feb 2026)

Adds `system.services` tree to NixOS where arbitrary services can be added
via `imports`. Key properties:

- Inherently multi-instance (unlike current NixOS `services.*`)
- Uses modules as importable units, not just option trees
- Provides basis for portability and connections (ties into RFC 189)

**Validates the nested evalModules / submodule approach from `05-nested-eval.md`.**
The NixOS module system is moving toward per-service isolation with structured
interfaces between services — exactly what kixpkgs needs for per-chart
isolation.

## Relevant Open PRs

### `builtins.wasm` ([PR #15380](https://github.com/NixOS/nix/pull/15380))

Announced March 2026 by Determinate Systems. Allows calling WebAssembly
functions from Nix expressions.

- 240x speedup demonstrated for Fibonacci
- Complete YAML parser implemented as proof of concept
- Could replace `pkgs.formats.yaml` (remarshal) for eval-time YAML serialization

**Implication**: If this lands, `mkManifest` could serialize attrsets to YAML
at eval time without needing a derivation (no `pkgs.runCommand`, no store
roundtrip). This would make attrsets-in-manifests even more practical —
serialization becomes a pure function call, not a build step.

Status: Experimental, Determinate Systems fork only for now.

### `builtins.filterAttrs` ([PR #15100](https://github.com/NixOS/nix/pull/15100))

Native builtin with tombstone-based memory optimization:

- 42% faster than `lib.filterAttrs` for large attrsets
- 28% less memory usage
- ~3% slower for general eval (tradeoff)

**Implication**: Useful for filtering manifests, stripping `_`-prefixed
metadata fields at the serialization boundary, and filtering capability
targets. Currently kixpkgs uses `lib.filterAttrs` in several places
(monitoring targets, chart variants).

### `builtins.derivationOf` ([PR #14956](https://github.com/NixOS/nix/pull/14956))

Returns the derivation path for any output, supporting RFC 92 multi-derivation
packages.

**Implication**: If we ever move to derivation-based manifests, this could
help with dependency graph inspection. Not relevant for the attrset path.

### BGL dependency graph ([PR #14392](https://github.com/NixOS/nix/pull/14392))

Adds a reusable directed graph template (Boost Graph Library) to libstore
for store path dependency analysis. Will power `nix why-depends` and cycle
detection.

**Implication**: Store-level, not eval-level. Not directly useful for
eval-time dependency tracking in kixpkgs, but shows Nix is investing in
graph infrastructure.

### Deterministic attrset comparison ([PR #15327](https://github.com/NixOS/nix/pull/15327))

Makes attrset comparison use lexicographic order instead of global state.
Explicitly noted as "a requirement for adding any sort of parallel/async eval."

**Implication**: Preparatory work for parallel evaluation. Our eval-time
validation and manifest processing will benefit from eventual parallel eval
without code changes.

### `builtins.trampoline` ([PR #14553](https://github.com/NixOS/nix/pull/14553))

Tail-call optimization via trampolining. Converts recursive functions to
O(n) iteration.

**Implication**: Could be useful for graph traversal in dependency tracking
or deep manifest tree walking. Currently a POC.

## Dependency Retrieval Primitives (Pre-RFC, Stalled)

A [Discourse pre-RFC](https://discourse.nixos.org/t/pre-rfc-implement-dependency-retrieval-primitive/43418)
proposed three new primops:

- `getRunDeps` — runtime dependencies from string interpolation
- `getBuildDeps` — build-time dependencies for derivation construction
- `getInstantiationDeps` — eval-time dependencies (IFD, builtin fetchers)

Got significant pushback from maintainers (roberth, RaitoBezarius) about
performance implications of modifying the Value struct and API commitment.
May narrow to just `getInstantiationDeps`. **Not likely to land soon.**

**Implication**: Even if these land, they operate at the store/derivation
level, not the eval-time attrset level. They wouldn't help with kixpkgs's
eval-time dependency tracking between manifest attrsets.

## Structured Attrs Evolution (2025)

Major cleanup of `exportReferencesGraph` internals:

- `StructuredAttrs` stored directly in `Derivation` (PR #13263, July 2025)
- Deprecated `__json` hack (PR #13273, Aug 2025)
- Top-level `structuredAttrs` field in JSON derivation format (PR #13349)
- Factored out of `DerivationBuilder` (PR #13769, Aug 2025)

Known bugs with `exportReferencesGraph`:
- [#11791] Slow performance
- [#10279] Behavior undocumented under `structuredAttrs`
- [#13302] Doesn't work in `nix-shell`
- [#7330] `__unsafeDiscardOutputDependency` incompatibility

**Implication**: `exportReferencesGraph` is being maintained but not enhanced.
It works for derivation-level DAG extraction but has known issues. Not a
reason to switch to derivation-based manifests.

## Experimental Features Summary

Currently available as experimental in Nix 2.33:

| Feature | Status | Relevant? |
|---------|--------|-----------|
| `pipe-operators` | Stable, widely used | **Yes** — combinator syntax |
| `dynamic-derivations` (RFC 92) | In progress | No — build-time, not eval-time |
| `ca-derivations` | Long-standing | No — prevents rebuilds, not relevant |
| `recursive-nix` | Available | No — builder-level recursion |
| `fetch-tree` | Available | No — input fetching |
| `blake3-hashes` | Since 2.27 | No |
| `no-url-literals` | Available | No |

## What This Means for kixpkgs Architecture

### Attrsets vs derivations: attrsets win

Nothing in the Nix pipeline makes derivations-in-manifests more attractive.
The evaluator keeps getting faster at attrset operations. `builtins.wasm`
could make attrset→YAML serialization eval-time (no derivation needed).
`builtins.filterAttrs` would speed up metadata stripping.

### Capability interfaces: validated by RFC 189

The NixOS community is building the same pattern. Our design is compatible
with RFC 189 Contracts if/when it lands. We can build capability interfaces
now using plain submodules, and potentially migrate to Contracts later.

### Pipe operators: ready to use

`|>` enables clean resource group combinator syntax. We already use it.
The experimental flag is the only caveat, but it's been stable for 2 years.

### No upcoming features change the architecture

There's nothing in the Nix pipeline that would make us want to wait or
choose differently. The capability interface + resource group combinator
design is sound given both current and upcoming Nix capabilities.

## Sources

- [Nix 2.33 Release Notes](https://nix.dev/manual/nix/2.33/release-notes/)
- [Nix Experimental Features](https://nix.dev/manual/nix/2.33/development/experimental-features.html)
- [RFC 189 — Contracts](https://github.com/NixOS/rfcs/pull/189)
- [RFC 148 — Pipe operator](https://github.com/NixOS/rfcs/pull/148)
- [Modular Services PR](https://github.com/NixOS/nixpkgs/pull/372170)
- [builtins.wasm PR](https://github.com/NixOS/nix/pull/15380)
- [builtins.filterAttrs PR](https://github.com/NixOS/nix/pull/15100)
- [builtins.derivationOf PR](https://github.com/NixOS/nix/pull/14956)
- [BGL dependency graph PR](https://github.com/NixOS/nix/pull/14392)
- [Deterministic attrset comparison PR](https://github.com/NixOS/nix/pull/15327)
- [builtins.trampoline PR](https://github.com/NixOS/nix/pull/14553)
- [Pre-RFC: Dependency retrieval primitives](https://discourse.nixos.org/t/pre-rfc-implement-dependency-retrieval-primitive/43418)
- [Parallel Nix evaluation blog](https://determinate.systems/blog/parallel-nix-eval/)
- [builtins.wasm announcement](https://determinate.systems/blog/builtins-wasm/)

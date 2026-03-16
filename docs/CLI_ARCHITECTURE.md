# Kix CLI Architecture

Decision: Kix will ship as a Rust binary. Users interact with `kix` commands,
not raw Nix. Agreed by Adam and Luca (2026-03-16).

## Table of contents

- [Requirements](#requirements)
- [Options evaluated](#options-evaluated)
  - [Option A: Shell out to nix eval](#option-a-shell-out-to-nix-eval)
  - [Option B: FFI via nix-bindings-rust](#option-b-ffi-via-nix-bindings-rust)
  - [Option C: Pure Rust Nix (Tvix/Snix)](#option-c-pure-rust-nix-tvixsnix)
- [Recommendation](#recommendation)
- [Key finding: eval-only works without daemon or /nix/store](#key-finding-eval-only-works-without-daemon-or-nixstore)
- [Risk: Nix error message leakage](#risk-nix-error-message-leakage)
- [Pre-flight check integration](#pre-flight-check-integration)
- [References](#references)

---

## Requirements

- Users should not need to install Nix separately
- No daemon, no root, no `/nix/store` requirement
- Must support `builtins.toFile` (Merkle DAG), `builtins.getContext` (dependency
  extraction), flake evaluation
- Must work on Linux and macOS
- Pre-flight checks (`kix check`) orchestrate external tools (kubeconform,
  pluto, kyverno, etc.) pulled in via Nix store paths

## Options evaluated

### Option A: Shell out to `nix eval`

The Rust binary downloads and caches the `nix` binary, then shells out to it.

**How it works:**
```
nix eval \
  --eval-store ~/.cache/kix/eval-store \
  --store 'local?root=~/.cache/kix/store' \
  --json .#packages.aarch64-darwin.cluster-example
```

**Tested and confirmed working** against the kixpkgs repo (2026-03-16). The full
v2 pipeline works with this approach:
- `builtins.toFile` for content-addressed resources
- `builtins.getContext` for dependency extraction
- `builtins.replaceStrings` + `builtins.unsafeDiscardStringContext` for
  post-processing (replacing store paths with K8s names)
- Flake evaluation with input fetching

No daemon, no `/nix/store`, no root. Just two cache directories (~22MB total for
a kixpkgs eval).

| Pros | Cons |
|---|---|
| Simplest to implement | Process spawn overhead on every eval |
| Works today, no dependencies beyond the nix binary | ~30-50MB binary to download/bundle |
| Battle-tested (the nix CLI is the most stable interface) | Cannot cache partial eval results |
| | Nix version management (must pin a compatible version) |
| | macOS cannot produce a static nix binary |

### Option B: FFI via nix-bindings-rust

Link against Nix's C libraries directly from Rust. This is what devenv 2.0
ships in production.

**Key projects:**
- [nix-bindings-rust](https://github.com/nixops4/nix-bindings-rust) — LGPL-2.1
  crate providing safe Rust wrappers around Nix's C API
  (`nix_api_expr.h`, `nix_api_store.h`, etc.) via bindgen
- [devenv-nix-backend](https://github.com/cachix/devenv/tree/main/devenv-nix-backend) —
  production proof that this approach works

**How it works:**
- The Rust binary links against `libnixexprc`, `libnixstorec`, `libnixflakec`
  at build time via `pkg-config`
- At runtime, calls `eval_state.eval_from_string(expr)` directly — no subprocess
- Flake locking, resolution, and fetching all work through the FFI
- The Nix C libraries are bundled with the binary (the Nix flake build handles
  this), so the user doesn't install Nix separately
- Boehm GC requires thread registration (`gc_register_my_thread()`)
- `EvalState` is not thread-safe — must be wrapped in `Arc<Mutex<>>`

**What devenv 2.0 proved:**
- Zero `Command::new("nix")` calls — entire codebase is FFI
- Incremental eval caching per attribute in SQLite (subsequent runs in
  milliseconds)
- Carries patches against Nix's C API that are "fully upstreamable"

| Pros | Cons |
|---|---|
| No subprocess overhead | Must bundle Nix C libraries (~size TBD) |
| Evaluator stays warm across operations | Boehm GC threading constraints |
| Can cache per-attribute results (SQLite, like devenv) | EvalState not thread-safe |
| Flake support works | Carries patches against Nix C API (for now) |
| Production-proven (devenv 2.0) | More complex build setup (pkg-config, nix-cargo-integration) |
| User installs one package, gets everything | LGPL-2.1 (fine for dynamic linking) |
| Error messages can potentially be intercepted and improved | nix-bindings-rust is v0.2.1 — API still evolving |

### Option C: Pure Rust Nix (Tvix/Snix)

Embed a Rust Nix evaluator as a library. No C dependencies at all.

- [Tvix](https://tvix.dev/) — TVL's Rust reimplementation. Compiles Nix to
  bytecode and runs on a VM. GPL-3.0.
- [Snix](https://snix.dev/) — Fork of Tvix (early 2025) with independent
  governance. GPL-3.0.

**Current state (2026-03):**
- Core language evaluation works
- Most builtins implemented
- **No flake support** — explicitly a non-goal for Tvix. Snix roadmap unclear.
- `builtins.toFile` blocked on eval-store API integration
- Cannot evaluate kixpkgs today
- devenv has announced intent to switch to Tvix but the backend isn't functional
  yet

| Pros | Cons |
|---|---|
| True single binary, zero external deps | No flake support (blocks kixpkgs) |
| Pure Rust, no C/C++ build complexity | `builtins.toFile` not working |
| No Boehm GC threading issues | Not production-ready |
| | GPL-3.0 license (requires careful consideration) |
| | Probably 1-2 years from being viable for Kix |

## Recommendation

**Start with Option A, plan for Option B.**

Option A (shell out) gets a working `kix` CLI with minimal effort. The UX is
identical — users run `kix check`, the binary handles the rest. The subprocess
overhead is acceptable for the initial version since `nix eval` is typically the
fast part (generating YAML is cheap; the pre-flight tools take longer).

Option B (FFI) is the long-term target. devenv has proven the architecture and
solved the hard problems (C library bundling, GC threading, caching). When
performance or UX demands it (caching, better error messages, incremental eval),
migrate to `nix-bindings-rust`. This is a backend swap — the `kix` CLI interface
stays the same.

Option C is worth monitoring but not worth waiting for.

## Key finding: eval-only works without daemon or /nix/store

Tested 2026-03-16 against the kixpkgs repo. The following works with no daemon
running, no `/nix/store`, and no root access:

```bash
# Eval a full kixpkgs flake — returns cluster package names
nix eval \
  --eval-store /private/tmp/kix-eval-test \
  --store 'local?root=/private/tmp/kix-nodaemon-store' \
  --json /Users/adam/Projects/kixpkgs#packages.aarch64-darwin \
  --apply 'builtins.attrNames'
# → ["cluster-example","cluster-full","cluster-nw1","cluster-minimal"]
```

```bash
# Full v2 Merkle DAG pipeline: builtins.toFile + getContext + post-processor
nix eval \
  --eval-store /private/tmp/kix-eval-test \
  --store dummy:// \
  --expr '
let
  configmap = builtins.toFile "k8s-ConfigMap-myapp"
    (builtins.toJSON { apiVersion = "v1"; kind = "ConfigMap"; });
  deployJson = builtins.toJSON { ref = "${configmap}"; };
  storePaths = builtins.attrNames (builtins.getContext deployJson);
  replaced = builtins.replaceStrings storePaths [ "myapp-configmap" ] deployJson;
in builtins.fromJSON (builtins.unsafeDiscardStringContext replaced)'
# → { configMapRef = "myapp-configmap"; kind = "Deployment"; }
```

Store sizes after eval: eval-store ~14MB, local store ~8MB.

**macOS caveat:** Store paths must not traverse symlinks (`/tmp` →
`/private/tmp` on macOS causes errors). The Rust binary should resolve symlinks
before passing paths to Nix.

## Risk: Nix error message leakage

The biggest UX risk for non-Nix users. When a user makes a typo in their package
config, they'll get a Nix stack trace instead of a clear error. Example:

```
error: attribute 'replcias' missing
  at /nix/store/abc...-source/packages/coredns/default.nix:42:5
```

Mitigation strategies:
- Option A: Parse nix stderr and rewrite common error patterns into Kix-specific
  messages
- Option B: Intercept errors at the FFI level before they become text. The
  `nix-bindings-rust` API provides structured error values, not just strings.
- Long-term: Kix-specific validation layer that catches common mistakes before
  they reach the Nix evaluator

## Pre-flight check integration

The `kix check` command chains eval-time and YAML-based checks. See
[PREFLIGHT_CHECKS.md](PREFLIGHT_CHECKS.md) for the full tool comparison.

```
kix check
  │
  ├─ 1. Nix eval (kix-specific: cross-resource validation, cycles, duplicates)
  │
  ├─ 2. kubeconform (schema correctness including CRDs)
  │
  ├─ 3. pluto (deprecated API detection)
  │
  ├─ 4. kyverno (graph-derived policies + org-specific rules)
  │
  ├─ 5. trivy/kubescape (security/compliance)
  │
  └─ 6. polaris/kube-score (best-practice lint)
```

Tools 2-6 are pulled in as Nix store paths and executed by the Rust binary. The
user doesn't install them — `kix` manages them.

## References

- [nix-bindings-rust](https://github.com/nixops4/nix-bindings-rust) — Rust FFI
  bindings to Nix C API (LGPL-2.1)
- [devenv-nix-backend](https://github.com/cachix/devenv/tree/main/devenv-nix-backend) —
  Production FFI backend for devenv 2.0
- [devenv 2.0 announcement](https://devenv.sh/blog/2026/03/05/devenv-20-a-fresh-interface-to-nix/) —
  Blog post on the architecture change
- [Tvix](https://tvix.dev/) — Rust Nix reimplementation (TVL)
- [Snix](https://snix.dev/) — Tvix fork with independent governance
- [nix-portable](https://github.com/DavHau/nix-portable) — Self-contained Nix
  binary (Linux-only)
- [PREFLIGHT_CHECKS.md](PREFLIGHT_CHECKS.md) — Pre-flight tool comparison

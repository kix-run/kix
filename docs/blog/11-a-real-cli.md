---
title: "A Real CLI: Rust + Nix FFI"
date: 2026-03-23
date_end: 2026-03-24
series: 11
commits:
  - fe4e399  # feat: kix Rust CLI with mock backend
  - 38f8f52  # feat: wire real Nix FFI backend via nix-bindings-rust
  - 811635c  # feat: wire tracing subscriber and instrument all crates
---

# A Real CLI: Rust + Nix FFI

*2026-03-23 to 2026-03-24 -- Post 11*

---

This is what using kix looks like today:

```
$ kix build prod
Building cluster prod... done (357 manifests)

$ kix diff prod
Comparing against live cluster...
  cert-manager:  12 resources, 2 diffs
  coredns:       8 resources, 0 diffs
  harbor:        45 resources, 3 diffs

$ kix graph prod
coredns
cert-manager → cluster-issuers
ingress-nginx → cert-manager
harbor → valkey, cert-manager, storage-classes
```

Three commands. Build, diff, graph. That is the entire daily workflow.

Before this, you ran `nix build .#cluster-prod --extra-experimental-features pipe-operators` and got a `result/` symlink full of YAML files. Diffing meant running a separate Python script to dump the live cluster, then another Python script to compare directories. There was no unified workflow. You held the pipeline together in your head.

The CLI changes that. One tool, three verbs, structured output.

## Why Rust

Nix evaluation is slow for large clusters. The production cluster produces 357 manifests across 26 packages, and a full `nix build` takes several seconds even when everything is cached. A Rust CLI can cache evaluation results, run builds in parallel, and provide structured output -- progress bars, colored diffs, exit codes that scripts can rely on.

The Python diff scripts were fine for prototyping. They proved the concept. But they were slow, they could not share state with the build step, and they printed unstructured text. For daily use you need something that feels instant and gives you confidence in its output.

Rust was the obvious choice. Fast startup. No runtime. Strong types that map cleanly onto Kubernetes resource structures. And -- critically -- the ability to call Nix's C API directly.

## The architecture

The CLI is a **4-crate Cargo workspace**:

- **kix-cli**: command parsing via `clap`, output formatting, tracing setup. This is the only crate that prints to stdout.
- **kix-eval**: Nix FFI. Evaluates Nix expressions and extracts attribute sets into Rust types. The hardest crate.
- **kix-manifest**: YAML serialization, manifest grouping, resource identity (apiVersion + kind + namespace + name).
- **kix-cluster**: cluster operations -- build, diff, graph. Orchestrates the other three crates.

Each crate has a clear boundary. `kix-eval` never touches YAML. `kix-manifest` never calls Nix. `kix-cli` never evaluates expressions. This separation was not aspirational -- it fell out of the types.

## The Nix FFI story

This was the gnarly part.

**kix-eval** calls Nix's C API directly. No subprocess. No JSON piping. No `nix eval --json` with shell escaping. Rust calls `nix_expr_eval_from_string`, `nix_value_force`, `nix_get_attr_byname`, and friends through C bindings.

This was made possible by **nix-bindings-rust** from the **nixops4** project. These are thin Rust wrappers around the Nix C API (`libnixstore`, `libnixexpr`). Getting it to work required figuring out three things that are barely documented:

1. **Store initialization.** You need a valid Nix store before you can evaluate anything. The embedded API requires explicit init/shutdown.
2. **Garbage collection roots.** Nix's GC will collect values out from under you if you do not root them. In a long-running CLI process this means careful lifetime management.
3. **Flake evaluation.** Evaluating a flake is not the same as evaluating a file. The embedded context needs the flake registry, the lock file, and the right evaluation flags.

Each of these took a day of reading Nix source code and trial-and-error. The C API has no real documentation beyond the header files. But once it worked, the payoff was immediate: evaluation results flow directly into Rust structs with no serialization boundary.

## The numbers

~10,000 lines of Rust across the four crates. **274 tests.** CI splits into three tiers: unit tests (pure logic, no Nix), integration tests (actually evaluate Nix expressions), and build verification (full cluster builds that check manifest output).

The integration tests are the most valuable. They catch regressions in the FFI layer that unit tests cannot see. If Nix changes how it evaluates a builtins call, the integration tests break before anyone notices in production.

## Where we are

Three weeks. That is how long it took to go from "what if Kubernetes manifests were Nix packages" to a working CLI that builds, diffs, and graphs a production cluster. The Nix DSL handles 357 manifests across 26 packages. The Rust CLI makes it usable. The diff tooling makes it safe.

kixpkgs is not done. There are rough edges everywhere -- error messages need work, the graph output is basic, and the diff algorithm still trips on certain CRD structures. But the core loop works: write a package, build, diff. The next posts cover what happened when that loop needed to go further -- leaner packages, auto-generated network policies, and a full deploy lifecycle.

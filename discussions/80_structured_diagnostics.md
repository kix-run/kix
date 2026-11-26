# 80 — Structured Diagnostics

**Status:** Draft
**Related:** `25_package_meta_warnings.md` (RFC — package-declared assertions/warnings), `60_scorecard_rules_design.md` (scorecard sidecar pattern), `36_rust_oracle_at_fixpoint.md` (Nix↔CLI integration), `29_compiler-design.md` (conceptual anchor)

---

## Context

kix is a compiler: Nix evaluates the cluster definition, the Rust CLI consumes the result and drives deploys. Diagnostics — warnings, errors, traces — are produced during Nix evaluation but the CLI is the thing a user actually looks at. Today that chain is broken.

Doc 25 established the *what*: packages declare `assertions` (fatal) and `warnings` (non-fatal), the evaluator collects them, failed assertions stop the build. It's implemented in `kix/lib/meta.nix` and wired into `kix/lib/eval/instance.nix` and `kix/lib/eval/cluster.nix`.

This doc is the *how*: the record shape, call-site ergonomics, transport to the CLI, and a principled way to author diagnostics at every site that currently uses `throw` or `builtins.trace`. It extends 25 rather than replacing it.

---

## Problem

Four concrete gaps, each with a file citation:

### 1. The structured pipeline exists but is unstructured inside

`meta.nix:43-46` defines an assertion as `{ assertion = bool; message = string; }`. Warnings are bare strings. Attribution is a string hack: `meta.nix:296` literally does `message = "[${instanceName}] ${a.message}"`. There is no severity, no stable code, no package attribution, no field/fragment context — all information the CLI would want is either missing or encoded as a fragile string prefix.

### 2. 54 throws and 4 traces bypass the pipeline entirely

Raw `throw` sites across 11 files (counts from `grep -c '^\s*throw '`):

- `eval/scope.nix:18` throws — workload validation, capability checks, cross-namespace refs, selector mismatches, container/port/env duplicates
- `compose.nix:11` throws — `kix.expose`, service routing, path validation
- `eval/resolve.nix:4` — ambiguous DI resolution, missing deps, locked field conflicts
- `eval/instance.nix:2`, `eval/import.nix:3`, `eval/view.nix:1`, `eval/helpers.nix:1`, `fragments.nix:2`, `helm.nix:3`, `k8s.nix:3`

Plus explicit `builtins.trace` calls at `k8s.nix:78` (non-string leaf in `.manifest` access), `k8s.nix:550` (missing package version), `view.nix:90` (unexpected `_type` in known folder), `auto.nix:347` (auto-instantiation summary). Plus `meta.nix:68` (`emitTraces` — the sink that dumps every collected warning to stderr).

Most of these are semantically sensible as "errors" or "warnings" — they just aren't wired into the pipeline. The 24 scope throws even carry `[${instanceName}]` prefixes, so they already *have* attribution; they just don't have a channel to carry it structured.

### 3. The CLI never reads `cluster.diagnostics`

`cli/kix-cli/src/evaluator.rs:17-25` defines `ClusterOutput` with three fields: `name`, `raw_manifests`, `scorecard_report`. No `diagnostics`. `cluster.nix:533-535` emits a `diagnostics` attribute with `warnings`, `assertions`, `failedAssertions` — it evaporates.

`build.rs:67-107` parses nix build stderr for progress markers and a narrow "does not provide attribute" heuristic. That is the full extent of Nix→CLI diagnostic plumbing.

### 4. Scorecard is the only structured channel that works

`scorecard.nix` produces `findings` with `rule`/`severity`/`message`/`namespace`/`instance`. Written to `kix-scorecard.json` by cluster.nix, read by `cli_backend.rs` and `check.rs`, converted to SARIF 2.1.0. This is the only diagnostic channel that reaches the CLI and it does so via a sidecar JSON file. **This is the pattern to copy for the rest of the diagnostic system.**

---

## Requirements (from the user)

1. **Structured records, not strings.** Everything that today is a `builtins.trace` or a `throw` should be a typed value the CLI can reason about.
2. **Source attribution, carried via curried constructors.** A call site inside `scope.mkDeployment.checkNamespacedRefs` should not have to restate `package`/`instance`/`namespace` every time — they should be pre-bound by the scope that owns the constructor. Leaf call sites add only their local `src` (which fragment / field / resource triggered the diagnostic).
3. **Opt-in hard-throw mode.** The default is "collect, aggregate, throw at cluster assembly". An author can opt individual diagnostics into fatal-now semantics when deferred collection would produce a cascade of confusing downstream failures.
4. **Extensible shape.** Adding a field later should not be a breaking change to existing emission sites.
5. **CLI-consumable.** Structured via sidecar JSON (the scorecard pattern) for the happy path, plus a stderr marker protocol for the unhappy path when a fatal throw fires before the cluster output is produced.

---

## Design

### 1. The diagnostic record

```nix
# A single diagnostic. All fields except severity/code/message are optional.
{
  # --- Required ---
  severity  = "error" | "warning" | "info";   # machine-readable level
  code      = "kix/untracked-secret-ref";     # stable, dotted, machine-readable
  message   = "...";                           # human body; NO [instance] prefix

  # --- Attribution (all optional, populated by the curried builder) ---
  package   = "immich";            # package name if known
  instance  = "immich";            # instance name in the cluster
  namespace = "media";             # namespace name in the cluster
  src       = "mkDeployment.checkNamespacedRefs.volumes[0].configMap.name";
                                   # dotted path inside the library call tree
                                   # that emitted the diagnostic

  # --- Optional structured context ---
  detail    = {                    # free-form attrset, serde-passthrough
    kind = "Secret";
    name = "immich-env";
    field = "envFrom[].secretRef.name";
    container = "init";
    declaredIn = "media";
  };

  # --- Optional position (Nix AST attribution) ---
  position  = {                    # from builtins.unsafeGetAttrPos
    file = "/path/to/cluster.nix";
    line = 42;
    column = 8;
  };

  # --- Optional cross-references ---
  hint      = "Use resource.out.name or kix.untrackedRef to opt out.";
  docs      = "https://kix.dev/docs/errors/untracked-secret-ref";
  related   = [ "kix/cross-namespace-ref" ];   # other diagnostic codes
}
```

**Severity**: tri-state. `error` blocks the build at cluster assembly (or fires fatally now if the author opted in). `warning` is reported but never blocks. `info` is audit-only — surfaced in `kix check` verbose mode, not in default output.

**Code**: stable dotted identifier, `<namespace>/<name>`. The kix library owns the `kix/*` namespace. Packages can own their own (`immich/storage-undersized`). Codes are what the CLI uses for filtering, the scorecard rules engine uses for rule attribution, SARIF uses for rule IDs, and docs pages are keyed on.

**Message**: the human body. Crucially, it does **not** include `[${instanceName}]` or any other attribution prefix — that lives in structured fields. Formatting for terminal output is the CLI's job, not the library's.

**Attribution fields** (`package`, `instance`, `namespace`, `src`): populated by the curried builder, not by the call site. See §2.

**Detail**: free-form attrset. Reserved for structured context that's specific to the code. Examples:
- `kix/untracked-secret-ref` detail: `{ kind, name, field, container }`
- `kix/cross-namespace-ref` detail: `{ kind, name, declaredIn, consumedIn }`
- `kix/capability-missing` detail: `{ capability, required_by }`

Because detail is free-form, adding new structured context to an existing code is not a breaking change — existing consumers ignore unknown keys.

**Position**: populated lazily via `builtins.unsafeGetAttrPos` when the diagnostic is emitted against a user-facing attrset (package config, instance config). The library only has meaningful positions at a handful of sites — mostly early validation of instance config. Where not available, the field is omitted entirely.

**Hint / docs / related**: tooling hooks. The CLI can surface hints in the default renderer, docs URLs in a `--learn-more` mode, and `related` lets us link diagnostics (e.g., "this cross-ns error also implies untracked-ref").

### 2. Curried constructors with src attribution

This is the ergonomic core. Today, every throw site in `scope.nix` prefixes `[${instanceName}]` by hand. Every site that wants to say anything more (which field? which fragment?) has to assemble the whole string. That's the reason we don't have that information.

The fix: **the scope pre-binds attribution, call sites only add `src`**.

```nix
# In eval/scope.nix — mkScope constructs the per-instance context.
# `kix.diag` is the raw library; `scope.diag` is the pre-bound builder.
scope.diag = kix.diag.bind {
  inherit package instance namespace;  # from mkScope args
  src = "scope";                        # root of the call path
};
```

Then every call site inside scope adds only its local src segment:

```nix
# scope.mkDeployment → checkNamespacedRefs → volume refs
scope.diag.error {
  src = "mkDeployment.checkNamespacedRefs.volumes.configMap.name";
  code = "kix/untracked-secret-ref";
  message = ''
    Untracked configMap reference "${plainName}".
    Use resource.out.name, or kix.untrackedRef to opt out explicitly.
  '';
  detail = { kind = "configMap"; name = plainName; field = "volumes[].configMap.name"; };
}
```

Or — since scopes nest — builders can re-bind to extend the src path:

```nix
# Inside mkDeployment, create a sub-builder for this function's diagnostics
mkDeployment = args:
  let
    diag = scope.diag.in "mkDeployment";
    # ...
  in
  builtins.seq (diag.checkLoadBalancer args) (
    # diag is now pre-bound with src = "scope.mkDeployment"
    # inside checkNamespacedRefs we'd do: diag.in "checkNamespacedRefs".in "volumes"
  );
```

`diag.in "label"` returns a new diag builder with the src path extended. The call tree mirrors the source structure, and every diagnostic emitted carries the full call path. No hand-assembled strings, no forgotten attribution.

**Fallback at the edges.** Code that doesn't have a scope in hand (the top of `mkImportScope`, phase-1 evaluation, `normalizePackage`) uses the raw `kix.diag` with explicit attribution fields. The lint is: if you have a scope, use `scope.diag`; if not, supply attribution manually.

### 3. Two exit modes

A diagnostic is a **value** (an attrset). What happens to it is orthogonal to how it was constructed.

#### 3a. Deferred mode (default)

`scope.diag.error {...}` returns a diagnostic value; the caller pushes it onto `_diagnostics.assertions` or `_diagnostics.warnings`. Aggregation happens in `meta.collectClusterDiagnostics` (the existing path in `meta.nix:309-333`). The cluster throws once at assembly if any `severity = "error"` diagnostic was collected — with a structured aggregate error containing all of them.

This is the current pipeline, just shaped correctly. The key difference from 25: **failure messages are rendered by the CLI, not by the Nix throw**. The Nix throw carries a `KIX-DIAG` marker plus a compact JSON payload; the CLI catches it, deserializes, and renders in terminal-native form.

The advantages of deferred are the ones 25 already identified: you get *all* errors at once, not just the first, and non-fatal warnings flow through the same channel without needing a separate path.

#### 3b. Fatal-now mode (opt-in)

When deferred semantics would cascade into nonsense downstream errors (e.g., a malformed helm chart producing 30 derived diagnostics, each dependent on the first), the author opts into fatal-now:

```nix
scope.diag.throw {
  src = "helm.wrapHelmResource";
  code = "kix/helm-missing-kind";
  message = "Helm chart resource is missing required 'kind' field";
  detail = { chart = chartName; index = i; };
}
```

`diag.throw` is the raw escape hatch: it formats the diagnostic, wraps it in the `KIX-DIAG` stderr marker protocol (§5), and calls `throw`. No collection, no deferral. The CLI catches the marker and renders normally.

The rule of thumb in the library: **prefer deferred unless the error invalidates downstream collection.** The current 54 throws are split roughly:

- Scope validation (24 throws): deferred. These describe problems with user fragments (unknown secret refs, cross-ns mounts, selector mismatches) — collecting them lets the user fix everything in one pass.
- Resource construction (helm.nix, k8s.nix): fatal-now. These fire when the input is too malformed to produce *any* downstream value.
- DI resolution (resolve.nix): fatal-now. An unresolvable dep is a blocker for everything downstream in that instance.
- Module system (fragments.nix, eval/instance.nix): case-by-case, but mostly fatal-now.

### 4. Extensibility

Three dimensions of extensibility baked in:

1. **New fields** — adding a new optional field to the record is not a breaking change. Existing emission sites keep working, the CLI ignores fields it doesn't understand until the Rust side adds deserialization.
2. **New codes** — codes are strings. The library owns `kix/*`, packages can own `<package>/*`. No central registry, no enum.
3. **New severities** — tri-state today (`error`/`warning`/`info`). If we need more (e.g., `note`, `deprecation`) we add them. The CLI and scorecard both do string matching, so expansion is additive.

The record shape is deliberately a superset of SARIF's result object — we can render straight to SARIF without lossy translation, unlike today's scorecard path which loses information.

### 5. Transport to the CLI

Two channels, picking up the scorecard precedent:

#### 5a. Sidecar JSON file (happy path)

`cluster.nix` already emits `packageIndex` as a `builtins.toFile` of a JSON blob. Add a sibling:

```nix
diagnosticsFile = builtins.toFile "kix-diagnostics.json" (
  builtins.toJSON {
    cluster = name;
    schemaVersion = 1;
    diagnostics = clusterDiagnostics.all;  # [ diagnostic, diagnostic, ... ]
  }
);
```

Wired into `allResources` so it's copied into `$out` by `mkManifests`. The Rust side adds a `DiagnosticsReport` serde struct next to the existing `ScorecardReport`, reads `$out/kix-diagnostics.json` in `cli_backend.rs`, and exposes it in `ClusterOutput`. This covers every successfully-built cluster.

#### 5b. Stderr marker protocol (unhappy path)

When a fatal-now throw fires, the cluster output does not exist, so the sidecar is never written. We need the diagnostic's structured form anyway. The protocol:

```
KIX-DIAG {"severity":"error","code":"kix/helm-missing-kind",...}
---
Helm chart resource is missing required 'kind' field.

  in package: immich
  in src: helm.wrapHelmResource
  detail: { chart = "immich-server", index = 3 }
```

A single-line prefix `KIX-DIAG ` followed by a one-line JSON payload, followed by `---` and a human-rendered body for fallback. The prefix+JSON line is machine-parseable; the rest is for humans if the CLI isn't present (e.g., a nix-build outside of kix).

The throw itself is `throw (formatDiagForThrow diag)`. The CLI's build.rs parses stderr for `KIX-DIAG ` lines on failure and, if found, prefers the structured form over the stack trace.

This is not beautiful but it's the same thing every other structured-error Nix consumer does, and it degrades gracefully to a readable human message if the CLI isn't involved.

### 6. Authoring ergonomics: the full call-site picture

Before:

```nix
# eval/scope.nix, inside checkNamespacedRefs
throw "[${instanceName}] Untracked ${kind} reference in ${fieldDesc}: "
  + "\"${plainName}\". "
  + "Use resource.out.name / resource.out.* helpers, "
  + "or kix.untrackedRef to opt out explicitly."
```

After:

```nix
# diag is scope.diag.in "mkDeployment" .in "checkNamespacedRefs"
diag.error {
  src = "volumes.${kind}.name";    # only the local bit
  code = "kix/untracked-ref";
  message = ''Untracked ${kind} reference "${plainName}".'';
  detail = { inherit kind field container; name = plainName; };
  hint = ''
    Use resource.out.name / resource.out.* helpers,
    or kix.untrackedRef to opt out explicitly.
  '';
}
```

What the CLI renders for the user:

```
error[kix/untracked-ref]: Untracked configMap reference "app-config".
  --> media/immich @ scope.mkDeployment.checkNamespacedRefs.volumes.configMap.name
  detail: kind=configMap field=volumes[].configMap.name container=init name=app-config
  hint:
    Use resource.out.name / resource.out.* helpers,
    or kix.untrackedRef to opt out explicitly.
```

Same information, but structured, filterable, SARIF-exportable, docs-linkable, and — most importantly — the library code at the call site is no longer assembling strings by hand.

---

## Existing code to change

### `kix/lib/meta.nix`

- `combineDiagnostics` (lines 281-304): take diagnostic records (new shape) instead of `{ assertion; message }` + bare strings. The `assertions` field stays (backwards-compat at the package-RFC-25 level), but the aggregation now produces `allDiagnostics : [diagnostic]` alongside the existing `allWarnings`/`allAssertions`.
- `collectClusterDiagnostics` (lines 309-333): return `all : [diagnostic]` in addition to the current split fields. The throw at line 321 uses `formatDiagAggregate` to produce a structured aggregate error.
- `emitTraces` helper (line 68): **delete**. Replaced by the CLI rendering pipeline. The library no longer dumps to stderr directly — the sidecar JSON is the only non-fatal channel.

### `kix/lib/diag.nix` (new)

New file, ~80 lines:

```nix
{ lib }:
rec {
  # Raw constructor. Validates record shape.
  mk = { severity, code, message, ... }@record: record;

  # Pre-bind attribution fields. Returns a diag builder.
  bind = base: {
    error    = args: mk (base // args // { severity = "error"; });
    warning  = args: mk (base // args // { severity = "warning"; });
    info     = args: mk (base // args // { severity = "info"; });
    throw    = args: builtins.throw (formatDiagForThrow (
      mk (base // args // { severity = "error"; })
    ));
    # Extend the src path for nested call sites
    "in" = label: bind (base // {
      src = if base ? src then "${base.src}.${label}" else label;
    });
  };

  # Top-level builder with no attribution bound.
  error    = mk // { severity = "error"; };  # etc.
  warning  = ...;
  info     = ...;

  # Format a diagnostic for fatal-now stderr output (§5b).
  formatDiagForThrow = diag: ''
    KIX-DIAG ${builtins.toJSON diag}
    ---
    ${renderHuman diag}
  '';

  renderHuman = diag: ...;           # simple renderer for fallback

  formatDiagAggregate = diagnostics: ...;  # used by collectClusterDiagnostics
}
```

Imported in `kix/lib/default.nix` and passed to `eval.nix` via the constructor chain.

### `kix/lib/eval/scope.nix`

`mkScope` (line 47) gains a `diag` field in its returned scope:

```nix
scope.diag = diag.bind {
  inherit package instance namespace;
  src = "scope";
};
```

Every `throw "[${instanceName}] ..."` in scope.nix becomes either `diag.error { ... }` (deferred, pushed into `_diagnostics`) or `diag.throw { ... }` (fatal-now). The 24 scope.nix throws mostly go deferred.

### `kix/lib/eval/cluster.nix`

Wire `cluster.diagnosticsFile` into the `allResources` list (near the existing `packageIndex` at line 436) so it's copied into `$out`.

### `cli/kix-cli/src/evaluator.rs`

`ClusterOutput` gains a `diagnostics: Option<DiagnosticsReport>` field. Serde struct defined parallel to `ScorecardReport`:

```rust
#[derive(Deserialize, Serialize)]
pub struct DiagnosticsReport {
    pub schema_version: u32,
    pub cluster: String,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Deserialize, Serialize)]
pub struct Diagnostic {
    pub severity: Severity,
    pub code: String,
    pub message: String,
    pub package: Option<String>,
    pub instance: Option<String>,
    pub namespace: Option<String>,
    pub src: Option<String>,
    pub detail: Option<serde_json::Value>,
    pub position: Option<Position>,
    pub hint: Option<String>,
    pub docs: Option<String>,
    pub related: Vec<String>,
}
```

Loaded in `cli_backend.rs` from `$out/kix-diagnostics.json` alongside the scorecard.

### `cli/kix-cli/src/commands/build.rs`

Stderr parsing gains a `KIX-DIAG ` marker recognizer. On nix build failure, if any marker lines were captured, they become the structured error instead of the raw stack trace. On success, the sidecar is the authoritative source and stderr markers (which shouldn't fire on a successful build) are ignored.

---

## The `src` path: what goes in it

The src path is the dotted sequence of library functions / pattern guards that led to the diagnostic. It is **not** a user source location — that's the `position` field, populated from `builtins.unsafeGetAttrPos` where available.

Convention for src segments:

- `scope` — root, set by `mkScope`
- `mkDeployment`, `mkStatefulSet`, `mkResource`, `mkCRD` — direct function name
- `checkNamespacedRefs`, `checkSelectorMatches` — validator name
- `volumes`, `envFrom`, `env`, `imagePullSecrets` — spec field the check operates on
- `${kind}.name` where kind is `secret`/`configMap`/`pvc` — leaf fragment type

Result: `scope.mkDeployment.checkNamespacedRefs.volumes.configMap.name`. It's not code-gen'd, it's hand-written at each `diag.in "label"` call. The convention is enforced by code review, not by types.

This is deliberately a string rather than a structured path attrset. Strings are:
- Trivial to serialize and grep for
- Stable across library refactors (you change the segment, not a schema)
- Easy to filter in the CLI (`kix build --filter-src 'scope.mkDeployment.*'`)

---

## Alternatives considered

### A. Keep the string-based pipeline, add a `code` prefix

`throw "kix/untracked-ref: [${instanceName}] ..."`. Minimum change. Rejected because it pushes parsing into the CLI (regex over stderr is brittle) and keeps attribution as a string-prefix hack that every call site has to remember to add.

### B. Full exception-object library in Nix

A library that mimics exceptions (a dedicated type, `catch`/`finally`, etc.). Rejected because Nix's only catchable primitive is `builtins.tryEval`, which loses context on the caught side and can only distinguish "evaluated" from "threw". Anything more elaborate requires building a sum-type ADT on top of attrsets, which we don't need for diagnostics — the collection pattern from RFC 25 already solves the "gather many, report once" problem.

### C. Encode everything as module assertions (NixOS-style)

NixOS has `config.assertions = [ { assertion; message; } ];` at the module level. We considered routing all diagnostics through the same mechanism. Rejected because:
- NixOS assertions fire at `evalModules` time, but many of our diagnostics fire during resource construction (post-modules, inside the fixpoint).
- The NixOS shape doesn't carry codes, severity, or structured detail — we'd end up wrapping them anyway.
- Mixing channels confuses the story: "is this a cluster-module assertion or a scope diagnostic?"

We use RFC-25 assertions on packages (module-level) and scope.diag inside library code. Both feed into the same `_diagnostics` aggregation.

### D. Sidecar only, no stderr marker

Avoid the `KIX-DIAG ` marker protocol by only writing diagnostics to the sidecar. Rejected because the sidecar doesn't exist when a fatal throw fires before the cluster output is produced — which is exactly when the user most needs structured errors.

### E. Per-call-site `src` as explicit attrset instead of curried builder

`diag.error { src = { function = "mkDeployment"; check = "checkNamespacedRefs"; field = "volumes.secret.name"; }; ... }`. Rejected because the whole point of the curried builder is that the caller doesn't restate the parent context. Explicit attrsets at leaves would rebuild what `diag.in` gives us for free, with more ceremony.

---

## Migration / compatibility

RFC 25's package-declared `assertions = { config, self, deps }: [ ... ]` and `warnings = { ... }: [ ... ]` continue to work. The library converts the returned values to diagnostic records at the boundary (in `meta.evaluatePackageDiagnostics`), injecting `severity = "error"` for assertions and `severity = "warning"` for warnings, with `package`/`instance`/`namespace` populated from the evaluation context. Package authors do not need to change anything.

Inside the kix library itself, the 54 throws and 4 traces migrate incrementally. Order of operations:

1. Land the `diag` library (`diag.nix`) and the record shape. Land `cluster.diagnosticsFile` as an empty list producer. Ship. Nothing breaks, nothing changes for users.
2. Wire `scope.diag` into `mkScope`. Update `meta.combineDiagnostics` and `collectClusterDiagnostics` to consume records. Both the old (string) and new (record) shapes work during the migration window.
3. Convert the 4 `builtins.trace` calls first (easiest, highest-value). These become deferred warnings.
4. Convert the 24 `scope.nix` throws to deferred `diag.error`. This is the big one — validate that `_diagnostics.assertions` properly accumulates on the instance view and the cluster-level aggregate throw fires only once.
5. Convert `resolve.nix`, `compose.nix`, `helm.nix` throws to `diag.throw` (fatal-now). These are cases where deferral would cascade.
6. Land the Rust-side `DiagnosticsReport` serde struct, the sidecar reader, the stderr marker parser, and the terminal renderer. Wire into `kix check`, `kix build`, `kix diff`.
7. Delete `meta.emitTraces` and all remaining `builtins.trace "warning: ..."` calls. The library no longer emits to stderr for diagnostics.

Each step is independently shippable. Steps 1–2 are no-ops for users. Steps 3–5 improve the library internals without requiring CLI changes (the existing stderr path keeps working, just better structured). Step 6 unlocks the CLI features. Step 7 is cleanup.

---

## Open questions

1. **Where do scorecard findings fit?** Scorecard findings are already structured (`60_scorecard_rules_design.md`) and have their own sidecar. Should they be merged into the unified diagnostics sidecar, or kept separate? Leaning: keep separate. Scorecard is a *policy evaluation* output; diagnostics are *library-level errors and warnings*. They belong in different channels for the same reason `clippy` warnings aren't in `cargo check` output.

2. **Position tracking — how much is worth it?** `builtins.unsafeGetAttrPos` gives file/line/column for attrset keys, which would work for user-supplied cluster config fields (namespaces, instances, config overrides). It does not work for values produced by lib functions (our own src). The effort is maybe half a day for the cluster-config surface; worth it for the first emission sites, defer the rest.

3. **Should `diag.in` return a builder or just a diag with an extended src?** Builder (current proposal) matches the currying story. But it adds a second shape (builders vs records) to remember. Alternative: flatten to just records with `src` extended via an explicit helper. Leaning: keep the builder — the ergonomics are worth the mental model cost.

4. **Versioning the sidecar schema.** `schemaVersion: 1` today. When we break it, do we bump and require kix CLI + kix Nix lockstep, or can we version-negotiate? Leaning: bump and require lockstep — this is an internal format between the Nix lib and the Rust CLI, users don't pin schemas.

5. **How does `kix diff` use diagnostics?** If a diff reveals a new diagnostic code that wasn't present in the previous activation, should `kix diff` highlight it as "this deploy introduces a new class of warning"? Interesting and out of scope for this doc; revisit after the pipeline lands.

6. **Error aggregation UX.** When 30 diagnostics fire across 12 packages, the CLI needs a compact renderer. Grouped by severity? By package? By code? This is a CLI rendering problem and deserves its own session once we have real data to render.

---

## Roadmap items addressed

- [ ] Structured diagnostics with attribution (not currently on roadmap)
- [ ] CLI consumption of warnings/errors (not currently on roadmap)
- [ ] Builds on RFC 25 (line 18 — general validation framework, line 86 — compatibility checks, line 89 — compatibility matrix)
- [ ] Unblocks `kix diff` diagnostic-awareness (future)

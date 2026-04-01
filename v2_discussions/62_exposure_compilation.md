# 62 — Exposure Compilation: From Boilerplate to Derived Resources

**Status:** Design exploration
**Related:** `29_compiler-design.md` (§4.4 Exposure/Ingress Compilation), `39_di_driven_defaults_design.md` (archived, DI-driven ingress pattern), `31_port_fanout_dsl.md` (named ports), `32_volume_mount_dsl.md` (mount helpers)

---

## 1. Problem

Eight packages repeat nearly identical code for a single concern: "expose this service over HTTP(S)."

The pattern — established in immich and propagated via the DI-driven defaults design (doc 39) — has three parts:

1. **Host resolution** (~8 lines): explicit config > cluster.domain fallback > null
2. **Gate variables** (~2 lines): `hasIngress = ingressNginx != null && host != null`, `hasTls = hasIngress && clusterIssuer != null`
3. **Ingress resource** (~15 lines): `fromService |> withCert |> mkResource` inside an `if hasIngress`

Across 8 packages, that's ~200 lines of structurally identical code. More importantly, the *intent* — "expose this service at this host" — is buried inside wiring mechanics.

### What varies between packages

From analyzing all 8 implementations:

| Package | Host derivation | Annotations | Builder | Port | Multi-path |
|---------|----------------|-------------|---------|------|------------|
| immich | cluster.domain ✓ | `proxy-body-size: "0"` | `fromService` | auto | no |
| n8n | cluster.domain ✓ | user-only | `fromService` | auto | no |
| vaultwarden | cluster.domain ✓ | user-only | `fromService` | auto | no |
| metabase | cluster.domain ✓ | user-only | `fromService` | auto | no |
| filebrowser | cluster.domain ✓ | user-only | `fromService` | auto | no |
| firezone | explicit only | user-only | `fromService` | explicit (13000) | no |
| harbor | cluster.domain ✓ | `proxy-body-size`, `ssl-redirect` | raw manifest | explicit | **yes** (5 paths, 2 backends) |
| python-app | explicit hosts list | user-only | raw manifest | per-path | **yes** (multi-host, multi-backend) |

**Two distinct populations:**
- **Simple** (6 packages): single host, single backend, auto port. *Identical* code modulo annotations.
- **Complex** (2 packages): multiple paths/hosts, multiple backends. Cannot use `fromService` — they need full control over `spec.rules`.

---

## 2. Design Constraint

From CLAUDE.md:

> **Don't invent new fields.** The DSL should work with standard K8s manifest fields.
> **Automation over brevity.** DSL features exist to prevent mistakes, not to save lines.
> **Resources are rich objects.** Resources expose derived properties through `out`.

The goal is not a shorter way to write an Ingress. It's eliminating the *wiring* between Service, Ingress, TLS, and certificate manager — the same wiring that the compiler design doc (§4.4) identifies as "manually synchronized intent."

---

## 3. Approaches Considered

### Approach A: `kix.expose` — Opinionated Builder

A single function that takes a service resource and DI deps, returns the derived resources.

```nix
# In package build:
exposed = kix.expose {
  service = self.service;
  host = config.ingress.host;              # null = auto-derive from cluster.domain
  ingressNginx = ingressNginx;             # null = no ingress
  clusterIssuer = clusterIssuer;           # null = no TLS
  annotations = config.ingress.annotations;
};

# Use:
ingress = exposed.ingress;     # null if no ingressNginx
root = exposed.root;           # service or ingress, whichever is the "entry point"
```

**Pros:**
- Maximum boilerplate reduction — one call replaces ~25 lines
- Intent is clear: "expose this service"
- `exposed.root` auto-selects the outermost resource (ingress if exists, else service)

**Cons:**
- **Opaque.** What resources get created? The user must read `kix.expose` docs, not the package code.
- **Scope leak.** Needs `scope.mkResource`, `name`, `clusterConfig` — either passed in explicitly (verbose) or captured from context (implicit, breaks the "no scope dependency" rule of compose.nix).
- **Rigid.** Harbor and python-app can't use it. Any package with non-standard ingress (extra paths, custom backends) falls outside the abstraction.
- **Two APIs.** Simple packages use `kix.expose`, complex packages use raw manifests. This is the split that doc 29 warns against: "the compiler handles the 90% case; the escape hatch handles the 10%."

### Approach B: `kix.ingress.forService` — Smarter Pipe (Extends Existing API)

Extend `kix.ingress.fromService` to accept DI deps directly and handle gating internally. The ingress builder becomes DI-aware.

```nix
# In package build:
ingress = self.service
  |> kix.ingress.forService {
    inherit name;
    host = config.ingress.host;
    ingressNginx = ingressNginx;          # null → returns null (no ingress created)
    clusterIssuer = clusterIssuer;        # null → no TLS
    annotations = config.ingress.annotations;
    clusterDomain = clusterConfig.cluster.domain or null;
  }
  |> scope.mkResource;  # scope.mkResource already handles null passthrough? (it doesn't today)
```

**Pros:**
- Extends existing API rather than introducing a new concept
- Pipe-friendly, visible resource chain
- User still calls `scope.mkResource` — no hidden resource creation

**Cons:**
- **Null passthrough problem.** If `ingressNginx == null`, the function returns null. But `null |> scope.mkResource` would crash. Need either: (a) `scope.mkResource` handles null → null, or (b) the whole chain must be wrapped in `if hasIngress`.
- **Still needs host resolution logic.** The package still computes `effectiveHost` or passes `clusterDomain`.
- **Doesn't eliminate the gate.** The `if hasIngress` still wraps the ingress assignment in parts.

### Approach C: Derive Exposure from the Service Resource Itself

Make the *service* the unit of exposure. The service knows it can be exposed; the compiler derives the rest.

```nix
# Service declaration with exposure intent:
service = self.deployment
  |> kix.service.fromWorkload { name = "${name}-server"; }
  |> scope.mkResource;

# Exposure as a method on the service:
ingress = self.service.expose {
  host = config.ingress.host;             # null = auto from cluster.domain
  ingressNginx = ingressNginx;            # null = returns null
  clusterIssuer = clusterIssuer;          # null = no TLS
  annotations = config.ingress.annotations;
};
```

**Pros:**
- Follows "resources are rich objects" — the service exposes what it can do
- Clean: `self.service.expose { ... }` reads as "expose this service"
- Returns null naturally when deps are missing — no `if` wrapper needed
- Service already has `out.port` and `out.name` — all the info needed for the ingress backend

**Cons:**
- **Scope problem.** `.expose` needs `scope.mkResource` to seal the ingress. Services don't currently carry scope. Would need to close over scope at creation time (like `.mountAt` in doc 32) or pass scope in.
- **Not all services are exposable.** A headless ClusterIP service for internal use shouldn't have `.expose`. But there's no type distinction today — all Services are the same.
- **Scope creep.** If we put `.expose` on services, what about `.monitor` (ServiceMonitor)? `.policy` (NetworkPolicy)? Resources become god objects.

### Approach D: Extracted Host + Gate + Transformer (Minimal Change)

Don't abstract the resource creation. Just extract the repeated *computations* into helpers.

```nix
# In compose.nix:
kix.ingress.resolveHost = { host, name, clusterDomain }:
  if host != null then host
  else if clusterDomain != null then "${name}.${clusterDomain}"
  else null;

kix.ingress.withTls = { host, clusterIssuer, secretName ? "${name}-tls" }:
  ingress:
  if clusterIssuer == null then ingress
  else ingress
    // { tls = [{ hosts = [ host ]; inherit secretName; }]; }
    |> clusterIssuer.out.withCert;
```

Package code becomes:

```nix
ingressHost = kix.ingress.resolveHost {
  host = config.ingress.host;
  inherit name;
  clusterDomain = clusterConfig.cluster.domain or null;
};

ingress = if ingressNginx != null && ingressHost != null then
  self.service
  |> kix.ingress.fromService {
    inherit name;
    host = ingressHost;
    className = ingressNginx.out.ingressClassName;
    annotations = config.ingress.annotations;
  }
  |> kix.ingress.withTls { host = ingressHost; inherit clusterIssuer name; }
  |> scope.mkResource
else null;
```

**Pros:**
- Minimal API addition — two small helpers
- Transparent — every resource is still visible in the package
- Works for harbor/python-app too — `withTls` is a general transformer
- No scope leak — everything stays in compose.nix's "pure helpers" model

**Cons:**
- **Doesn't eliminate the `if` wrapper.** The gate logic is still per-package.
- **Moderate savings.** Cuts ~8 lines per package (host resolution + TLS plumbing) but the structure remains.
- **Doesn't capture intent.** "Expose this service" is still expressed as a wiring pattern, not a declaration.

### Approach E: `kix.withIngress` — Null-Safe Pipe Transformer

A pipe transformer that attaches an ingress to a service, returning both. Null-safe: returns just the service when deps are missing.

```nix
# New: kix.withIngress attaches an ingress to a service resource.
# Returns { service, ingress } — ingress is null when gated off.
# The service is returned unmodified.

service = self.deployment
  |> kix.service.fromWorkload { name = "${name}-server"; }
  |> scope.mkResource;

exposed = self.service |> kix.withIngress {
  inherit name scope;
  host = config.ingress.host;
  clusterDomain = clusterConfig.cluster.domain or null;
  ingressNginx = ingressNginx;
  clusterIssuer = clusterIssuer;
  annotations = config.ingress.annotations;
};

# exposed.ingress is null or a sealed resource
# exposed.host is the resolved host (for use in env vars etc.)
ingress = exposed.ingress;
```

**Pros:**
- Null-safe: no `if hasIngress` needed
- Pipe-friendly: extends the existing composition model
- Returns the resolved host for use elsewhere (env vars, CORS config, etc.)
- `scope` is passed explicitly, not captured

**Cons:**
- Passing `scope` breaks the convention that compose.nix helpers are scope-free. (But this is a deeper question: should derived-resource helpers exist in compose.nix at all, or in a new module?)
- Returns an attrset, not a resource — breaks the `|> pipe |> mkResource` chain
- Harbor/python-app still can't use it

---

## 4. Recommendation: Approach D+E Hybrid

**Use approach D's helpers** (resolveHost, withTls) for the common sub-expressions, **and approach E's pattern** for the full exposure shorthand — but without passing scope.

### The key insight

The problem isn't that the code is long. It's that the *intent* is obscured by *mechanics*. But the right solution isn't hiding the mechanics behind a wall — it's making each mechanical step so short that the intent is obvious.

### Concrete API

#### 4.1 `kix.ingress.resolveHost` — Host resolution helper

```nix
# lib/compose.nix
ingress = {
  # ... existing fromService ...

  # Resolve an ingress host from explicit config, cluster domain, or null.
  resolveHost = { host, name, clusterDomain ? null }:
    if host != null then host
    else if clusterDomain != null then "${name}.${clusterDomain}"
    else null;
};
```

This extracts the 8 lines of host resolution that appear in every package.

#### 4.2 `kix.ingress.fromService` gains TLS awareness

Instead of a separate `withTls`, extend `fromService` to handle TLS gating internally:

```nix
# Extended fromService:
fromService = {
  name,
  host,
  # ... existing args ...
  clusterIssuer ? null,   # NEW: null = no TLS, non-null = auto TLS
  tlsSecretName ? null,   # NEW: override auto-derived "${name}-tls"
  ...
}@cfg: svc:
let
  effectiveSecretName = if tlsSecretName != null then tlsSecretName else "${name}-tls";
  hasTls = clusterIssuer != null;
  tlsBlock = lib.optional hasTls {
    hosts = [ host ];
    secretName = effectiveSecretName;
  };
  base = {
    # ... existing ingress construction ...
    spec = {
      # ... existing rules ...
    }
    // lib.optionalAttrs (tlsBlock != []) { tls = tlsBlock; };
  } // passthrough;
in
if hasTls then base |> clusterIssuer.out.withCert else base;
```

This absorbs the `|> (if hasTls then clusterIssuer.out.withCert else lib.id)` that appears in every package.

#### 4.3 Package code: before and after

**Before** (current immich, ~25 lines):
```nix
clusterDomain = clusterConfig.cluster.domain or null;
ingressHost =
  if config.ingress.host != null then
    config.ingress.host
  else if clusterDomain != null then
    "${name}.${clusterDomain}"
  else
    null;
hasIngress = ingressNginx != null && ingressHost != null;
hasTls = hasIngress && clusterIssuer != null;

# ... later in parts:
ingress =
  if hasIngress then
    self.service
    |> kix.ingress.fromService {
      inherit name;
      host = ingressHost;
      className = ingressNginx.out.ingressClassName;
      tls = lib.optional hasTls {
        hosts = [ ingressHost ];
        secretName = "${name}-tls";
      };
      annotations = { "nginx.ingress.kubernetes.io/proxy-body-size" = "0"; }
        // config.ingress.annotations;
    }
    |> (if hasTls then clusterIssuer.out.withCert else lib.id)
    |> scope.mkResource
  else
    null;
```

**After** (~10 lines):
```nix
ingressHost = kix.ingress.resolveHost {
  host = config.ingress.host;
  inherit name;
  clusterDomain = clusterConfig.cluster.domain or null;
};

# ... in parts:
ingress = if ingressNginx != null && ingressHost != null then
  self.service
  |> kix.ingress.fromService {
    inherit name clusterIssuer;
    host = ingressHost;
    className = ingressNginx.out.ingressClassName;
    annotations = { "nginx.ingress.kubernetes.io/proxy-body-size" = "0"; }
      // config.ingress.annotations;
  }
  |> scope.mkResource
else null;
```

The savings per package are modest (~15 lines), but the *signal-to-noise ratio* improves dramatically. The two things that actually vary between packages — `annotations` and `host` — are the only things visible. The TLS ceremony is gone.

### 4.4 What about the `if` wrapper?

The `if ingressNginx != null && ingressHost != null then ... else null` remains explicit. This is intentional:

1. **Visibility.** A package author reading the code sees immediately that ingress is conditional. With `kix.expose` (approach A), the conditionality is hidden inside the function.

2. **Consistency.** Other conditional resources (serviceMonitor, configMap) use the same `if dep != null then ... else null` pattern. Making ingress special breaks the rhythm.

3. **Fixpoint safety.** The `if` prevents Nix from evaluating `ingressNginx.out.ingressClassName` when `ingressNginx` is null. Hiding this inside a function that accepts null deps requires careful null handling — a bug surface that doesn't exist with the explicit gate.

If we later want to eliminate the gate, the right path is a **null-safe pipe operator** or a **null-propagating resource builder** — but that's a language-level concern, not an exposure-specific one.

---

## 5. Harbor and Python-App: The Complex Case

These packages use raw Ingress manifests because they need multi-path or multi-host routing. The proposed changes don't help them — and that's fine. They benefit from:

1. **`kix.ingress.resolveHost`** — harbor already uses the same host resolution logic, just inlined.
2. **`clusterIssuer.out.withCert` as pipe** — both already use this. No change needed.
3. **TLS block construction** — could extract a helper: `kix.ingress.tlsBlock { host; clusterIssuer; secretName; }` that returns `[]` or `[{ hosts, secretName }]`. But this is micro-optimization — not worth a new function.

The right abstraction for multi-backend ingress is a different feature entirely (an `ingress.fromServices` builder that takes a list of `{ path, service, port }` entries). That's orthogonal to exposure compilation and can be designed independently.

---

## 6. The `ingress` Options Pattern

Every package also repeats the same options declaration:

```nix
ingress = lib.mkOption {
  type = lib.types.anything;
  default = {
    host = null;
    annotations = { };
  };
};
```

This could become a shared option constructor:

```nix
# In kixlib or a shared options module:
kix.options.ingress = lib.mkOption {
  type = lib.types.anything;
  default = {
    host = null;
    annotations = { };
  };
  description = "Ingress configuration. Host auto-derives from cluster.domain when null.";
};

# Package usage:
options = {
  ingress = kix.options.ingress;
  # ... other options ...
};
```

Small win, but it standardizes the option shape and description across packages.

---

## 7. Relationship to Other Tier 3 Features

### Storage compilation (doc 32)

Storage is a different beast — it's about volume/mount wiring within a package, not cross-concern derived resources. Doc 32's `.mountAt` / `.path` proposal is the right approach there. The two features don't interact.

### Port fan-out (doc 31)

`kix.namedPort` and exposure compilation are complementary. Named ports eliminate port repetition *within* a package; exposure compilation eliminates ingress wiring *across* packages. They compose:

```nix
ports = { http = kix.namedPort "http" 8080; };

service = self.deployment
  |> kix.service.fromWorkload { name; ports = [ ports.http.service ]; }
  |> scope.mkResource;

ingress = if ingressNginx != null && ingressHost != null then
  self.service
  |> kix.ingress.fromService {
    inherit name clusterIssuer;
    host = ingressHost;
    className = ingressNginx.out.ingressClassName;
    port = ports.http.number;   # explicit, from named port
  }
  |> scope.mkResource
else null;
```

### Monitoring compilation

The same pattern (DI dep gates resource creation) applies to ServiceMonitor. A future `kix.monitoring.fromService` could follow the same shape:

```nix
serviceMonitor = if prometheus != null then
  prometheus.out.mkServiceMonitor scope {
    inherit name;
    selector = self.service.out.selector;
    endpoints = [{ port = "http"; }];
  }
else null;
```

But monitoring has more variation per-package (which ports, which endpoints, scrape interval). The abstraction is less clear-cut.

---

## 8. Implementation Plan

### Phase 1: `kix.ingress.resolveHost` helper

Add to `lib/compose.nix`. Pure function, no dependencies. Packages can adopt incrementally.

### Phase 2: Extend `fromService` with `clusterIssuer` parameter

Add optional `clusterIssuer` and `tlsSecretName` parameters to `kix.ingress.fromService`. When `clusterIssuer` is non-null, auto-construct TLS block and apply `withCert`. Backward-compatible — existing callers don't pass these args.

### Phase 3: Migrate packages

Mechanical migration of 6 simple-pattern packages. Verify with `nix build` that output hashes don't change (same manifest content, different code path).

### Phase 4 (optional): Shared ingress options

Extract `kix.options.ingress` for package option standardization. Lower priority — it's a consistency win, not a correctness win.

---

## 9. Open Questions

### 9.1 Should `fromService` accept `ingressNginx` too?

We could go further and have `fromService` accept the `ingressNginx` dep directly, extracting `className` from `out.ingressClassName`:

```nix
fromService = { name, host, ingressNginx ? null, ... }: ...
  className = if ingressNginx != null then ingressNginx.out.ingressClassName else cfg.className;
```

This eliminates one more line per package but couples `fromService` to the `ingressNginx` package's `out` contract. Tradeoff: convenience vs. generality.

### 9.2 Where do derived-resource helpers live?

`compose.nix` is "pure composition helpers with no scope dependency." If we keep `fromService` scope-free (returning a pre-seal attrset), it stays in compose.nix. If we ever want a helper that returns a sealed resource, it needs to live elsewhere (scope.nix? a new `derived.nix`?).

For now: everything stays in compose.nix. The `scope.mkResource` call remains in the package.

### 9.3 Should the `if` gate become a null-safe pattern?

Long-term, a `scope.mkResourceOrNull` or a null-propagating pipe could eliminate the gate:

```nix
ingress = self.service
  |> kix.ingress.fromServiceIf { ... ingressNginx ... }  # returns null if gated
  |> scope.mkResourceOrNull;                               # passes null through
```

This is cleaner but introduces nullable resource handling throughout the system. Defer until there's a general need for null-safe pipes (monitoring, network policies, etc. all have the same pattern).

### 9.4 Ingress option: `type = lib.types.anything` vs structured

All packages use `lib.types.anything` for the ingress option. A structured type would catch errors:

```nix
ingressOptionType = lib.types.submodule {
  options = {
    host = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    annotations = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; };
  };
};
```

But `lib.types.anything` is deliberate — it allows packages to add custom fields (like python-app's `hosts`, `autoTls`). Standardizing the option type would constrain this flexibility. Leave as-is for now.

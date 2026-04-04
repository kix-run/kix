# 70 — Gateway API Migration: From ingress-nginx to Gateway API

**Status:** RFC (Draft)
**Related:** `62a_exposure_as_composable_build_entry.md` (current `kix.expose` design), `62_exposure_compilation.md` (exposure analysis), `29_compiler-design.md` (compiler philosophy, persona model), `48_system_contracts.md` (cluster capabilities)

---

## 1. Problem

ingress-nginx is deprecated. The Kubernetes project is moving to the [Gateway API](https://gateway-api.sigs.k8s.io/) as the standard for traffic management. Gateway API is GA since K8s 1.26 (GatewayClass, Gateway, HTTPRoute) and is now the recommended path for all new clusters.

kix currently has a hard dependency on ingress-nginx at multiple levels:

1. **DI alias:** packages discover their ingress controller via `ingressNginx ? null` — the name itself encodes the implementation
2. **Generated resources:** `kix.expose` and `ingress.fromService` emit `networking.k8s.io/v1 Ingress` resources with nginx-specific annotations
3. **Controller package:** `packages/ingress-nginx/` is the only ingress controller implementation, exposing `out.ingressClassName`
4. **Network policies:** `packages/network-policies/` references `ingress-nginx.out.selector` for cluster-wide traffic rules
5. **Complex packages:** harbor and python-app build raw `Ingress` manifests with `ingressNginx.out.ingressClassName`

This coupling means that adopting Gateway API isn't just swapping one controller package — it touches the DSL, generated resource kinds, DI contracts, and network policy generation.

But the news is better than it looks.

---

## 2. Why This Is Actually a Strength Test for kix

The Gateway API migration is a perfect case study for kix's core value proposition: **absorbing infrastructure complexity so app developers don't have to care.**

Today, 6 packages use `kix.expose { service = "service"; }` and never mention ingress-nginx. They're already insulated. The question is: can we make the migration invisible to them?

If yes, kix proves that it can absorb a Kubernetes-ecosystem-wide breaking change without touching app-level code. That's the whole pitch.

---

## 3. Gateway API Primer: What Changes

### 3.1 Resource Model

| Ingress API | Gateway API | Who owns it |
|---|---|---|
| IngressClass | GatewayClass | Infrastructure provider (e.g. Envoy, Cilium, nginx) |
| *(implicit)* | Gateway | Cluster operator (defines listeners: ports, protocols, TLS) |
| Ingress | HTTPRoute | App developer (defines routing: host, path → backend) |
| *(annotations)* | Policy resources | Platform engineer (rate limiting, auth, etc.) |

The key structural change: **the Ingress resource is split into two**. The Gateway defines *where* traffic enters (listeners, TLS termination, allowed routes). The HTTPRoute defines *how* it's routed (host matching, path matching, backend refs). These are separate resources, often in separate namespaces, owned by different personas.

### 3.2 Persona Mapping to kix

| Gateway API persona | kix equivalent | What they control |
|---|---|---|
| **Infrastructure provider** | Package author (`packages/envoy-gateway/`) | GatewayClass resource + controller deployment |
| **Cluster operator** | Cluster definition (`clusters/nw1/platform.nix`) | Gateway resources (listeners, TLS config) |
| **Application developer** | Package author (`packages/n8n/`, etc.) | HTTPRoute resources |

This maps almost perfectly to kix's existing three-tier model. The compiler design doc (§6) already says:

> **App Developer** declares: "I have a web service that listens on port 8080." Does NOT care about: RBAC rules, NetworkPolicy details, **Ingress annotations, certificate management.**

Gateway API makes this separation structural rather than conventional. The app developer *literally cannot* configure TLS termination — that's on the Gateway, which they don't own.

### 3.3 TLS Changes

With Ingress API, TLS is configured *on the Ingress resource* via `spec.tls` + a cert-manager annotation. The app developer (or `kix.expose`) must know about certificate management.

With Gateway API, TLS is configured *on the Gateway's listener*. The cluster operator configures `spec.listeners[].tls.certificateRefs`. The HTTPRoute just says "match host X" — it doesn't touch TLS at all.

This is a strict improvement for kix: TLS wiring can move entirely out of `kix.expose` and into the Gateway package/cluster definition.

### 3.4 What Replaces nginx-Specific Annotations

Ingress-nginx relies heavily on annotations for behavior:
- `nginx.ingress.kubernetes.io/proxy-body-size`
- `nginx.ingress.kubernetes.io/ssl-redirect`
- `nginx.ingress.kubernetes.io/rate-limit`

Gateway API replaces these with:
- **Policy resources** (e.g. `BackendTLSPolicy`, `BackendLBPolicy`) — structured, typed, controller-agnostic
- **HTTPRoute filters** — request/response header modification, URL rewrite, mirroring
- **Implementation-specific Policy CRDs** — e.g. Envoy Gateway's `ClientTrafficPolicy`, `BackendTrafficPolicy`

This means the `annotations` passthrough in `kix.expose` needs to become either filter configuration or separate Policy resources.

---

## 4. Impact Analysis: What Needs to Change

### 4.1 Changes by Layer

#### Layer 1: Controller Package (new `packages/envoy-gateway/` or similar)

**Current:** `packages/ingress-nginx/` provides:
- Controller deployment, RBAC, webhook
- IngressClass resource
- `out.ingressClassName` for DI consumers

**New:** A Gateway API implementation package (e.g. envoy-gateway, nginx-gateway-fabric, or cilium's built-in) provides:
- Controller deployment, RBAC, CRDs
- GatewayClass resource
- Gateway resource(s) — these are the "entry points" (listeners)
- `out.gatewayRef` (name + namespace) for DI consumers — replaces `out.ingressClassName`
- `out.selector` for network policies (unchanged pattern)

The Gateway resource is interesting because it sits between "infrastructure" and "cluster config." The GatewayClass is pure infrastructure. The Gateway is cluster-operator territory — it defines which ports/protocols/hosts are available. It could be:
- Part of the controller package (with config options for listeners)
- A separate package or a cluster-level resource
- Multiple Gateways per cluster (public vs. private, different listener configs)

**Recommendation:** The controller package creates the GatewayClass. The Gateway resources are either part of the same package (configured via options) or separate instances — same pattern as today's multiple `ingress-nginx` instances (public, private).

#### Layer 2: DI Contract

**Current:** `ingressNginx ? null` with `out.ingressClassName`
**New:** A generic alias like `gateway ? null` with:
```nix
out = {
  gatewayRef = { name = "public"; namespace = "gateway-system"; };
  gatewayClassName = "envoy";  # informational
  selector = { ... };           # for network policies
};
```

The DI alias should be **implementation-agnostic**: `gateway` not `envoyGateway`. This is exactly what the ROADMAP already anticipates: *"ingressController → DI dep with out.ingressClassName"*. We just go further and make it `gateway` with `out.gatewayRef`.

#### Layer 3: `kix.expose` Build Entry (`lib/compose.nix`)

This is the highest-leverage change point. Today `kix.expose`:
1. Takes `ingressNginx ? null` as DI dep
2. Emits a `networking.k8s.io/v1 Ingress` resource
3. Applies TLS via `clusterIssuer.out.withCert`

After migration, `kix.expose`:
1. Takes `gateway ? null` as DI dep (and possibly still `clusterIssuer ? null` for cert-manager, though Gateway often handles this)
2. Emits a `gateway.networking.k8s.io/v1 HTTPRoute` resource
3. TLS is **not its concern** — the Gateway handles it

```nix
# New kix.expose output (sketch):
expose = { service, partName ? "httpRoute", ... }:
{ self, config, clusterConfig, scope, lib,
  gateway ? null, ... }:
let
  svc = self.${service};
  name = scope.instanceName;
  effectiveHost = /* same resolution logic */;
  hasRoute = gateway != null && effectiveHost != null;
in {
  ${partName} = if hasRoute then
    svc
    |> httpRoute.fromService {
      inherit name;
      host = effectiveHost;
      parentRef = gateway.out.gatewayRef;
      # no TLS, no className, no annotations
    }
    |> scope.mkResource
  else null;
};
```

**Impact on app packages using `kix.expose`:** Zero. They call `(kix.expose { service = "service"; })` and get whatever resource the platform provides. The build entry's DI dep name changes from `ingressNginx` to `gateway`, but that's internal to `kix.expose` — app packages never see it.

#### Layer 4: `ingress.fromService` Helper

**Current:** Produces an `Ingress` attrset.
**New:** Add a parallel `httpRoute.fromService` helper:

```nix
httpRoute.fromService = { name, host, parentRef, path ? "/", pathType ? "PathPrefix", port ? null, ... }:
svc:
{
  apiVersion = "gateway.networking.k8s.io/v1";
  kind = "HTTPRoute";
  inherit name;
  spec = {
    parentRefs = [ parentRef ];
    hostnames = [ host ];
    rules = [{
      matches = [{ path = { type = pathType; value = path; }; }];
      backendRefs = [{
        name = svc.out.name;
        port = servicePort;
      }];
    }];
  };
};
```

**Keep `ingress.fromService` too?** Yes, at least during migration. Complex packages (harbor, python-app) may need time to migrate, and some clusters may still use Ingress API.

#### Layer 5: Complex Packages (harbor, python-app)

These build raw Ingress manifests because they need multi-path/multi-host routing. In Gateway API, this actually gets *easier* — HTTPRoute natively supports multiple rules with different backends:

```nix
# Harbor's 5-path routing becomes:
spec.rules = [
  { matches = [{ path = { value = "/api/"; }; }];
    backendRefs = [{ name = self.coreService.out.name; port = 80; }]; }
  { matches = [{ path = { value = "/v2/"; }; }];
    backendRefs = [{ name = self.coreService.out.name; port = 80; }]; }
  { matches = [{ path = { value = "/"; }; }];
    backendRefs = [{ name = self.portalService.out.name; port = 80; }]; }
];
```

No annotations needed. No TLS block needed. The HTTPRoute is actually simpler than the Ingress for multi-backend cases.

**These packages still need manual migration** — they reference `ingressNginx.out.ingressClassName` and build raw manifests. But the migration is straightforward and the result is cleaner.

#### Layer 6: Network Policies

**Current:** `packages/network-policies/` has `ingressNginxAccess` policy using `ingress-nginx.out.selector`.
**New:** Same pattern, different name: `gatewayAccess` using `gateway.out.selector`. The selector resolution fallback changes from `{ "app.kubernetes.io/name" = "ingress-nginx"; }` to whatever the gateway controller uses.

#### Layer 7: Cluster Definitions

**Current** (`clusters/nw1/`):
```nix
ingress-public = { package = packages.ingress-nginx; ... };
# Apps wire: deps.ingressNginx = ref.nginx-system.ingress-public;
```

**New:**
```nix
gateway-public = { package = packages.envoy-gateway; config = { listeners = [ ... ]; }; };
# Apps wire: deps.gateway = ref.gateway-system.gateway-public;
# Or: auto-resolved via alias "gateway"
```

#### Layer 8: `kix.options.ingress`

The shared option definition changes semantics:
- `host` stays (HTTPRoute still needs hostnames)
- `annotations` goes away (no annotations on HTTPRoute — behavior is via filters/policies)
- Possibly add `filters` or `policies` for Gateway API-specific behavior

```nix
kix.options.expose = {  # rename from ingress to expose
  host = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
  # annotations removed — Gateway API uses structured policies
};
```

### 4.2 Coupling Inventory

| Coupling point | Files | Effort | App-visible? |
|---|---|---|---|
| `kix.expose` DI dep name | `lib/compose.nix:415` | Low — rename arg | **No** (internal to build entry) |
| `kix.expose` resource kind | `lib/compose.nix:442-458` | Medium — new builder | **No** |
| `ingress.fromService` builder | `lib/compose.nix:148-201` | Medium — add `httpRoute.fromService` | **No** (new parallel API) |
| `kix.options.ingress` | `lib/compose.nix:356-369` | Low — rename/trim | Low (option path change) |
| `packages/ingress-nginx/` | Entire package | High — new package needed | **No** (infra concern) |
| `packages/network-policies/` | Lines 138, 149-153, 253-268 | Low — rename DI dep + selector | **No** |
| harbor raw Ingress | `packages/harbor/default.nix:1381-1454` | Medium — rewrite to HTTPRoute | Yes (package-level) |
| python-app raw Ingress | `packages/python-app/ingress.nix` | Medium — rewrite to HTTPRoute | Yes (package-level) |
| Cluster defs: dep wiring | `clusters/nw1/apps.nix`, `platform.nix` | Low — rename dep refs | **No** (operator concern) |
| ROADMAP / capability TODOs | `lib/modules.nix:282-289`, `ROADMAP.md:93` | Low — update text | N/A |

**Bottom line:** 6 packages using `kix.expose` need zero changes. 2 complex packages need manual migration. Everything else is infrastructure/platform work invisible to app developers.

---

## 5. How kix Absorbs the Complexity

### 5.1 The `kix.expose` Abstraction Holds

The key insight: `kix.expose` already captures the *intent* ("expose this service externally") rather than the *mechanism* (Ingress vs. HTTPRoute). The app developer writes:

```nix
(kix.expose { service = "service"; })
```

This line is implementation-agnostic *today*. Whether `kix.expose` emits an Ingress or an HTTPRoute is an implementation detail. The DI system resolves whichever controller package the cluster provides.

**This is the design payoff of doc 62a's approach.** By making exposure a composable build entry with its own DI deps, the app developer is fully insulated from the ingress controller choice.

### 5.2 Gateway as a DI-Provided Capability

The migration path for DI:

```
Today:       ingressNginx ? null  →  out.ingressClassName
Transition:  ingressController ? null  →  out.ingressClassName OR out.gatewayRef
Target:      gateway ? null  →  out.gatewayRef
```

The transition phase uses a generic alias (`ingressController`) that both ingress-nginx and gateway packages can satisfy. `kix.expose` checks which `out` fields are present and emits the appropriate resource kind:

```nix
# Transition-phase kix.expose (sketch):
expose = { service, ... }:
{ self, config, scope, lib,
  ingressController ? null, clusterIssuer ? null, ... }:
let
  ctrl = ingressController;
  isGateway = ctrl != null && ctrl ? out.gatewayRef;
  isIngress = ctrl != null && ctrl ? out.ingressClassName;
in {
  ${partName} =
    if isGateway then
      # Emit HTTPRoute
      svc |> httpRoute.fromService { parentRef = ctrl.out.gatewayRef; ... } |> scope.mkResource
    else if isIngress then
      # Emit Ingress (legacy path)
      svc |> ingress.fromService { className = ctrl.out.ingressClassName; ... } |> scope.mkResource
    else null;
};
```

This lets clusters migrate one controller at a time. Packages don't change. The emitted resource kind follows the cluster's infrastructure.

### 5.3 TLS Becomes the Gateway's Problem

Today, every `kix.expose` call threads `clusterIssuer ? null` and constructs TLS blocks. With Gateway API, TLS termination moves to the Gateway's listener configuration:

```nix
# In the gateway controller package or cluster config:
gateway = {
  spec.listeners = [{
    name = "https";
    port = 443;
    protocol = "HTTPS";
    tls = {
      mode = "Terminate";
      certificateRefs = [{ name = "wildcard-cert"; }];
    };
    allowedRoutes.namespaces.from = "All";
  }];
};
```

The HTTPRoute just references `parentRefs = [{ name = "gateway"; }]` — no TLS, no cert-manager interaction. This means:

1. `kix.expose` drops the `clusterIssuer` DI dep entirely (for Gateway API mode)
2. TLS configuration moves to the gateway package's options
3. cert-manager integration (if needed) is between the gateway package and cert-manager, not per-app

**Net effect:** `kix.expose` gets simpler. The TLS ceremony disappears from the app-level abstraction.

### 5.4 Annotations → Policies: A Cleaner Model

ingress-nginx annotations are stringly-typed, controller-specific, and scattered across Ingress resources. Gateway API replaces them with:

1. **HTTPRoute filters** (inline, structured):
   ```nix
   rules = [{
     filters = [{
       type = "RequestHeaderModifier";
       requestHeaderModifier.add = [{ name = "X-Request-ID"; value = "..."; }];
     }];
   }];
   ```

2. **Policy resources** (separate resources, attachable):
   ```nix
   # BackendTrafficPolicy (Envoy Gateway example)
   apiVersion = "gateway.envoyproxy.io/v1alpha1";
   kind = "BackendTrafficPolicy";
   spec = {
     targetRefs = [{ group = "gateway.networking.k8s.io"; kind = "HTTPRoute"; name = "myapp"; }];
     rateLimit = { ... };
   };
   ```

For kix, this means:
- Simple cases (most apps): no per-app policy needed. The gateway handles global defaults.
- Complex cases: `kix.expose` could accept a `filters` parameter (structured, not stringly-typed) or the package creates separate Policy resources.
- Platform-wide policies: a separate package or cluster-level config, not per-app annotations.

The `defaultAnnotations` parameter on `kix.expose` would be replaced by something like:
```nix
(kix.expose {
  service = "service";
  filters = [
    { type = "RequestHeaderModifier"; ... }
  ];
})
```

Or for harbor's `proxy-body-size` needs — that becomes a BackendTrafficPolicy resource, possibly managed by a `kix.policy` build entry.

### 5.5 Network Policy Continuity

The network-policies package uses `ingress-nginx.out.selector` to create cluster-wide "allow traffic from/to ingress controller" policies. This pattern is controller-agnostic — it just needs a selector. Whether that selector comes from `ingress-nginx.out.selector` or `envoy-gateway.out.selector` doesn't matter. The DI rename handles it.

### 5.6 Multi-Gateway Support

Gateway API natively supports multiple Gateways — e.g. a public Gateway and a private Gateway. kix already handles this via multiple instances:

```nix
instances.gateway-system = {
  gateway-public = {
    package = packages.envoy-gateway;
    aliases = [ "gateway" ];  # default for apps
    config.listeners = [{ port = 443; protocol = "HTTPS"; ... }];
  };
  gateway-private = {
    package = packages.envoy-gateway;
    aliases = [ "gateway-private" ];
    config.listeners = [{ port = 8443; protocol = "HTTPS"; ... }];
  };
};

# Apps choose which gateway:
instances.apps.n8n.deps.gateway = ref.gateway-system.gateway-public;
instances.apps.internal-tool.deps.gateway = ref.gateway-system.gateway-private;
```

Same pattern as today's multiple ingress-nginx instances. No new concepts needed.

---

## 6. Migration Strategy

### Phase 0: Generalize the DI alias (non-breaking)

- Add `meta.defaultAliases = ["ingressController" "gateway"]` to `packages/ingress-nginx/`
- Update `kix.expose` to accept `ingressController ? null` (keeping `ingressNginx` as a fallback via alias)
- No resource changes — still emits Ingress
- All packages continue working unchanged

### Phase 1: Add `httpRoute.fromService` builder

- New helper in `lib/compose.nix` alongside `ingress.fromService`
- Produces `gateway.networking.k8s.io/v1 HTTPRoute` resources
- Pure addition — no existing code changes

### Phase 2: Gateway controller package

- New package: `packages/envoy-gateway/` (or `packages/gateway-nginx/`, depending on chosen implementation)
- Provides GatewayClass + Gateway resources
- Exposes `out.gatewayRef`, `out.selector`
- Has `meta.defaultAliases = ["gateway" "ingressController"]`

### Phase 3: `kix.expose` dual-mode

- `kix.expose` detects whether the injected controller provides `out.gatewayRef` or `out.ingressClassName`
- Emits HTTPRoute or Ingress accordingly
- Apps using `kix.expose` work with either controller — zero changes
- TLS logic becomes conditional: only for Ingress mode

### Phase 4: Migrate complex packages

- harbor: rewrite raw Ingress to HTTPRoute (simpler result — no TLS block, no annotations)
- python-app: rewrite ingress.nix to use `httpRoute.fromService` or raw HTTPRoute
- Both gain a DI dep on `gateway ? null` instead of `ingressNginx ? null`

### Phase 5: Migrate cluster definitions

- Replace ingress-nginx instances with gateway instances in `clusters/nw1/`
- Update dep wiring from `deps.ingressNginx` to `deps.gateway`
- Update network-policies package to reference gateway selector

### Phase 6: Remove legacy (optional, later)

- Remove `ingress.fromService` or deprecate it
- Remove `packages/ingress-nginx/`
- Clean up dual-mode logic in `kix.expose`

---

## 7. The Bigger Picture: What This Proves About kix

If this migration succeeds with **zero changes to packages using `kix.expose`**, it validates kix's core architecture:

1. **Composable build entries absorb infrastructure shifts.** The `kix.expose` pattern — a reusable build entry with its own DI deps — means app packages don't couple to infrastructure choices. This isn't just about ingress controllers; the same pattern applies if the monitoring stack changes (Prometheus → VictoriaMetrics) or the CNI changes (Cilium → Calico).

2. **DI aliases enable implementation swapping.** A generic alias (`gateway`) satisfied by different packages (`ingress-nginx`, `envoy-gateway`) is exactly how kix handles this. The `out` contract is the interface; the package is the implementation.

3. **The persona model is structural, not just conceptual.** Gateway API's explicit persona separation (infra provider / cluster operator / app developer) validates doc 29's claim that these personas have different concerns that should be addressed at different levels. kix's three-tier model (package definition / cluster definition / DI resolution) maps cleanly.

4. **"Don't invent new fields" pays off.** Because `kix.expose` wraps real K8s resources (not an invented DSL), switching from Ingress to HTTPRoute is a matter of changing which real resource gets emitted. There's no intermediate abstraction to maintain or migrate.

---

## 8. Open Questions

### 8.1 Which Gateway API implementation?

Options: Envoy Gateway (CNCF, feature-rich), nginx-gateway-fabric (NGINX's official Gateway API impl), Cilium Gateway API (if cluster uses Cilium), Istio (if service mesh is desired). kix shouldn't care — the package wraps whichever impl the cluster uses. But we need to pick one for the reference implementation.

**Lean:** Envoy Gateway — it's the CNCF reference implementation, has the broadest feature coverage, and doesn't require a service mesh.

### 8.2 CRD management for Gateway API

Gateway API CRDs are installed separately from the controller (unlike ingress-nginx where the IngressClass CRD is built into K8s). kix needs to handle the CRD installation — either as part of the controller package or as a separate `gateway-api-crds` package. The existing `mkCRDRef` pattern handles this.

### 8.3 How long to support dual-mode?

Phase 3's dual-mode `kix.expose` adds complexity. How long do we keep it? Options:
- **Short:** One release cycle. Force migration.
- **Long:** Indefinitely. Some clusters may be stuck on old K8s without Gateway API.
- **Config-based:** `cluster.capabilities.gatewayAPI = true/false` gates which mode `kix.expose` uses.

The config-based approach fits the existing capabilities model and lets clusters migrate at their own pace.

### 8.4 What about `config.ingress.annotations` in existing cluster configs?

Cluster definitions that set `config.ingress.annotations` (e.g. `nginx.ingress.kubernetes.io/proxy-body-size`) would need migration to Gateway API equivalents. This is a cluster-level concern, not a package concern, but it's a migration task that needs documentation.

### 8.5 Should `kix.expose` gain a `kix.policy` companion?

Gateway API's policy attachment model (separate Policy resources that target HTTPRoutes) suggests a pattern like:

```nix
build = [
  ./app.nix
  (kix.expose { service = "service"; })
  (kix.policy { route = "httpRoute"; rateLimit = { ... }; })
];
```

This mirrors the `kix.expose` / `kix.monitor` pattern. Worth exploring but not required for initial migration.

### 8.6 ReferenceGrant for cross-namespace backends

Gateway API requires explicit `ReferenceGrant` resources when an HTTPRoute in namespace A references a Service in namespace B. kix's dependency graph already tracks cross-namespace references — could the compiler auto-generate ReferenceGrants? This would be a significant compile-time safety feature unique to kix.

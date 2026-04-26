# 107: Overlay-edge exposure (tailscale, firezone) and `kix.expose`

**Status:** RFC / Draft
**Relevance:** Active — drives ludo D-day item B3 in doc 105.
**Related:** `105_ludo_homelab_operational_readiness.md`, `97_service_contract_primitives.md`, `archive/70_gateway_api_migration.md`, `archive/62_exposure_compilation.md`.
**Supersedes (partial):** `meta.exposure` proposal in `105_ludo_homelab_operational_readiness.md` §B3 — replaced by engine-side wiring described here.

## Why this doc

Doc 105 §A5/B3 calls for a `meta.exposure` intent so packages can say "expose this on the tailnet." That's the wrong layer: a marker someone downstream is supposed to interpret, with no concrete renderer. The renderer already exists (`kix.expose` in `kix/lib/compose.nix:599`); it just doesn't know about overlay edges.

This doc asks: what does it actually take, in K8s primitives and DSL wiring, to support tailscale and firezone as first-class edges — without leaking edge names into package authors' code, and without inventing any vocabulary K8s doesn't already have.

## Guiding principle: K8s already has the words

Three K8s primitives carry edge intent:

| K8s primitive | DI dep | What it provides |
|---|---|---|
| `IngressClass` | `ingress` | `out.ingressClassName` (+ optional `out.tlsTermination` hint) |
| `GatewayClass` / `Gateway` | `gateway` (exists today) | `out.gatewayRef` |
| `Service { type: LoadBalancer, loadBalancerClass }` | `loadBalancer` | `out.loadBalancerClass`, `out.serviceAnnotations` |

We do not invent `httpEdge` / `l4Edge` / `meta.exposure`. We rename the legacy `ingressNginx` DI dep to `ingress` (it was never nginx-specific), keep `gateway`, add `loadBalancer`. Tailscale and firezone slot into one or more of these three slots — same as cilium-LB, MetalLB, and ingress-nginx already do.

## Roles and responsibilities

| Actor | Owns | Doesn't touch |
|---|---|---|
| Package author | The *protocol nature* of their service. Encoded via Service port naming (`name: http` vs `name: postgres`) and an optional `port = self.svc.ports.http` selector on `kix.expose`. Calls `kix.expose { service = "service"; }` once. | Edge names. TLS issuers. Tailscale/firezone/nginx as words. |
| Cluster operator | Which edges exist (which packages are installed). DI-wires `ingress` / `gateway` / `loadBalancer` to whichever package provides them. Wires `clusterIssuer` only if HTTPS comes from cert-manager. | Per-instance expose mode. Protocol shape. |
| Engine (`kix.expose`) | Inspects the resolved port shape; routes to the right renderer based on which deps are wired. Surfaces structured diagnostics on missing/conflicting wiring. | Magical defaults. |

The package author's mental model is `expose this`. Nothing else. That is the point.

## What `kix.expose` becomes

One call. Dispatch by service-port shape:

- **HTTP-shaped port** (port name in `{http, https, web, api}`, or explicit `port = svc.ports.http`):
  - `gateway` wired → `HTTPRoute` (today's behavior).
  - `ingress` wired → `Ingress` (today's behavior, post-rename).
  - **Both wired → throw.** Cluster operator picks one. (Same as today; not relaxing this in v1 — Gateway-API maturity varies per provider.)
  - `clusterIssuer` wired → `Certificate` + tls block. Absent → no TLS resource. Tailscale-style upstream-TLS edges *may* surface `out.tlsTermination = "upstream"`; engine emits a structured-diagnostic warning if `clusterIssuer` is wired against an upstream-terminating edge (lint, not fail).
- **Non-HTTP port** (everything else, default case):
  - `loadBalancer` wired → patch the referenced Service to `type: LoadBalancer`, set `loadBalancerClass = loadBalancer.out.loadBalancerClass`, merge `loadBalancer.out.serviceAnnotations` (e.g. `tailscale.com/hostname`, firezone resource metadata).
  - Not wired → structured diagnostic at eval time. No silent skip.

No `mode` flag, no `exposeL4` sibling. Mode is intrinsic to the service's port shape, which the package author already declares. Ambiguous packages (HTTP API with a metrics port) use the existing `port = ...` selector to disambiguate, exactly as they do today.

### Renames and breaking changes

- `ingressNginx` DI dep → `ingress`. Touches every cluster definition that wires it (small set; project policy is breaking changes are fine).
- New DI dep `loadBalancer`. Optional. Absent in clusters that only do HTTP edges.
- `gateway` unchanged.
- `clusterIssuer` unchanged.

## Tailscale: how it slots in

`tailscale-operator` (new package, `kix/packages/tailscale-operator/`) ships:

- Operator Deployment + RBAC + CRDs (`Connector`, `ProxyClass`, `ProxyGroup`, `Recorder`).
- OAuth client secret (kix-secret, hydrated via SOPS).
- Configurable: tailnet name, default tags, MagicDNS settings.

It *exports* multiple edge personalities via `out`:

```nix
out = {
  ingressClassName  = "tailscale";   # so it can feed `ingress` dep
  tlsTermination    = "upstream";    # hint for the linter
  loadBalancerClass = "tailscale";   # so it can feed `loadBalancer` dep
  serviceAnnotations.${"tailscale.com/expose"} = "true";
  gatewayRef = { ... };              # so it can feed `gateway` dep (Gateway API)
};
```

Cluster wires whichever personalities it wants:

```nix
deps = {
  ingress      = self.tailscaleOperator;   # HTTP via tailscale
  loadBalancer = self.tailscaleOperator;   # L4 via tailscale
  # clusterIssuer omitted — tailscale terminates TLS itself
};
```

A package that calls `kix.expose { service = "service"; }` on a service whose front-door port is named `http` gets an Ingress with `ingressClassName: tailscale`, no Certificate. A package whose service has port `name: postgres` gets the same Service patched to `type: LoadBalancer, loadBalancerClass: tailscale`. The package author wrote one call.

## Firezone: same shape, with a controller

Firezone DOES have a working helm chart (gateway StatefulSet + portal). The kix-side challenge is that *which resources are reachable through firezone* lives in firezone's control-plane API, not in K8s.

Solution: **build a small in-cluster controller** that watches K8s objects and reconciles them to the firezone API. Two object kinds:

1. `Service { type: LoadBalancer, loadBalancerClass: firezone }` — same shape tailscale and every cloud LB use. The controller registers each such Service as a firezone Resource with the matching ports/protocol.
2. `FirezoneResource` CRD (kix-defined) for non-Service resources: CIDRs, DNS names, internal infra not represented as a K8s Service. Controller reconciles these against firezone API.

The `firezone-resource` package wraps the controller (Go or Rust, small) and exports:

```nix
out = {
  loadBalancerClass = "firezone";
  serviceAnnotations.${"firezone.dev/policy"} = config.defaultPolicy;
  ingressClassName  = "firezone";   # firezone also has an HTTP gateway path
  tlsTermination    = "upstream";
};
```

Same wiring story as tailscale. From the package author's seat, firezone vs tailscale is invisible.

Why in-cluster controller rather than a `kix deploy` post-step or out-of-band Terraform: continuous reconciliation, drift correction, and a real K8s-native experience. The post-step variant was considered for v1 simplicity but rejected — firezone's value is dynamic resource policy, and a once-per-deploy reconciler can't hold that promise. Investment is bounded: cloud-controller-manager-style watchers are a known shape, ~500 LOC of operator scaffolding.

## Gateway API consideration

Tailscale ships `GatewayClass: tailscale`. So `kix.expose` against `gateway = self.tailscaleOperator` produces an HTTPRoute attached to a tailscale-managed Gateway. Same renderer as today's nginx-Gateway path. No new code in `compose.nix` for this case; it's purely a packaging matter.

The current "both `ingress` and `gateway` wired = throw" rule stays. We're not auto-preferring Gateway over Ingress in v1 — Gateway-API support is uneven across providers (firezone has none yet) and the explicit-pick rule keeps cluster definitions readable.

## Multi-edge clusters: deferred to v2

Three real multi-edge stories exist:

1. Different services to different edges (readdeck on tailnet, public-blog on nginx+LE).
2. Same service on two edges (grafana on both tailnet and public).
3. HTTP-via-X, L4-via-Y (already supported — `ingress` and `loadBalancer` are independent).

Story 3 works today. Stories 1 and 2 are **out of scope for v1**. v1 enforces "one `ingress`, one `gateway`, one `loadBalancer` per cluster". When a real driver appears (likely when a customer beyond ludo wants split-edge), revisit with either:

- Per-instance DI overrides (kix DI already supports per-instance binding).
- Or `edges = [...]` parameter on `kix.expose` with cluster-side name-to-provider mapping.

Capturing the option now means we don't paint ourselves into a corner; building it now would be premature.

## Cluster-level "what's exposed" view

Doc 105 wants a single explicit list of exposed services for operator readability. **This is a derived query, not new declarations.** The engine sees every `kix.expose` call. Surface:

- `cluster.out.exposures = [ { instance, service, edge, host or ip, port } ... ]` — derived attr, accessible from any consumer.
- `kix exposures` CLI command — pretty-prints the same data, optionally grouped by edge.

Zero new fields for the operator to write. The "single list" ask is satisfied by *reading* the graph. Aligns with the project principle (`CLAUDE.md`): resources are rich objects; consumers query the resource directly.

## Migration plan

1. **Rename `ingressNginx` → `ingress` in `kix/lib/compose.nix`** and every cluster that wires it. Greppable, mechanical.
2. **Add `loadBalancer` DI dep** to `kix.expose`. Implement the Service-patch path (`type: LoadBalancer` + `loadBalancerClass` + merged annotations). Structured diagnostic when an L4-shape expose call has no `loadBalancer` wired.
3. **Add port-shape dispatch** in `kix.expose`: HTTP-shaped → existing path; else → loadBalancer path.
4. **Optional `tlsTermination` lint**: warning when `clusterIssuer` wired against `out.tlsTermination = "upstream"`.
5. **Ship `kix/packages/tailscale-operator/`** — operator + CRDs + OAuth secret. Exports `ingressClassName`, `loadBalancerClass`, `gatewayRef`.
6. **Wire `ludo/cluster.nix`** — `ingress = self.tailscaleOperator`, `loadBalancer = self.tailscaleOperator`. Drop `clusterIssuer` for ludo (tailscale-only edge).
7. **Add `cluster.out.exposures` + `kix exposures` CLI** — derived view, no new declarations.
8. **Firezone controller** — build small operator (Go or Rust), package as `kix/packages/firezone-resource/`, ship alongside upstream firezone helm chart for the gateway. Tracked separately; not a ludo-D-day blocker.

Steps 1–6 satisfy doc 105 §B3 for the ludo D-day. Step 7 closes the operator-readability ask. Step 8 unlocks firezone clusters (post-ludo).

## What this doc is not

- Not a controller-design doc for the firezone reconciler. That gets its own doc when step 8 is scheduled.
- Not a Gateway-API-vs-Ingress strategy doc. Archived doc 70 covers that; current rule (explicit pick) stays.
- Not a multi-edge design. Deferred until a real driver materializes.

## Open questions

1. **Port-shape heuristic specifics.** Which port names count as HTTP-shaped? Proposal: `{http, https, web, api}` plus `targetPort` numeric heuristic (80, 443, 8080, 8443) only as a tiebreaker. Should the package author's explicit `port = ...` always win? (Probably yes.)
2. **Tailscale `Connector` / `ProxyGroup` CRDs vs Service-LB path.** Newer tailscale-operator versions prefer `Connector` for subnet-router-style exposure. Does `loadBalancer` dep cover both, or do we need a separate `connector` dep? (Likely cover with a config option on the tailscale-operator package; `loadBalancerClass` is the K8s-native primitive.)
3. **Firezone CRD shape.** What does `FirezoneResource` look like for non-Service resources (CIDRs, internal DNS)? Defer to firezone-controller design doc.
4. **TLS-termination lint severity.** Warning vs error when `clusterIssuer` is wired against an upstream-terminating edge? Warning for v1 (operators may have transitional setups); revisit.
5. **`kix exposures` CLI output shape.** Plain table, JSON, or both? (Both, JSON for piping.) Lives in `cli/` — separate impl ticket.

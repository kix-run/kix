# Networking & package meta

This chapter covers two things a package author mostly does NOT do by hand: network policy and capability ownership. Network policy in kix is **derived** from the dependency graph, not declared per resource, so most packages author zero CiliumNetworkPolicies. The exception is `meta.network.intents`, a small declarative escape hatch for connectivity the store-path graph cannot see. The second half is the full `meta` field reference: lifecycle/version/maintainer descriptors, the `scope`/conflict/version constraints enforced at eval time, and `meta.provides` plus the `kix.dev/capability` annotation that let one package own a capability and hand consumers a builder instead of letting them hand-roll resources.

The source of truth is `kix/lib/netpol.nix` (derivation orchestration), `kix/lib/meta.nix` (meta validation), `kix/lib/modules.nix` (the cluster-level `networkPolicy` and `cluster.network` options), `kix/lib/rules/architecture.nix` (the `capabilityOwnership` rule), and the enforcer rule builder in `kix/packages/cilium-external/netpol-rules.nix`.

## Network policy is derived, not declared

When a cluster sets `networkPolicy.enable = true` (see `kix/lib/modules.nix`), kix synthesizes CiliumNetworkPolicies (CNPs) by inspecting the store-path DAG and the resource set. A package normally writes none of these. The derivation reads five signals, none of which require a meta field:

- **Cross-package Service egress.** When a workload's manifest references a Service's store path (because you used `kix.service.fromWorkload` outputs, `svc.out.fqdn`, or any `out.*` value, see 06-composition-helpers.md), that store-path context is a DAG edge. `extractServiceEdgesFromJson` in `kix/lib/netpol.nix` walks `builtins.getContext` of the workload args' JSON, matches paths against the cluster's Service registry, and emits an egress rule to that Service's pod selector and ports.
- **DNS egress.** Every generated egress policy includes `enforcerApi.dnsEgressRule`. Separately, any workload with cross-instance Service edges gets the DNS instance root injected as a deploy-ordering dependency (`dnsDeps`, spliced into the workload's `requires` by `scope.mkWorkload`), so it waits for the DNS stack at deploy time. This DNS dep injection runs even when `networkPolicy.enable` is false, because DNS ordering is a platform concern, not a netpol concern.
- **API-server egress.** Derived in `processInstance` from RBAC presence, but precisely: a workload gets `apiServerEgressRule` only if its ServiceAccount is the subject of some `RoleBinding`/`ClusterRoleBinding` in the instance closure (the `boundSAKeys` walk). Merely having RBAC in the instance is not enough; the SA must actually be bound.
- **External (LoadBalancer) ingress.** If the instance contains a `Service` of `type: LoadBalancer`, non-hostNetwork workloads get a world-ingress supplement rule. The entities default to `[ "world" ]` but are overridable via `meta.network.externalIngressEntities`. (hostNetwork is no longer a trigger, see Gotchas.)
- **Self-communication.** `StatefulSet` workloads get self-ingress and self-egress rules (pods of the same selector talking to each other), built by `enforcerApi.mkSelfRules`.

Plus a per-namespace **default-deny** CNP when `networkPolicy.defaultDeny = true` (the default). `generateDefaultDeny` respects `directions`, so an `egress`-only cluster denies only egress.

### Two emission sites

The CNPs are produced in two places, for a deploy-ordering reason:

- `buildWorkloadCnps` runs inside the workload constructor (`scope.mkDeployment` and friends), BEFORE the workload resource is built. The CNPs it returns are spliced into the workload's `requires`, so the workload's own store-path context transitively includes its policies and `kix deploy` places them in an earlier wave. This closes the window where a workload is Ready but its policy has not been applied yet. It handles the signals visible from the workload args alone: service egress, DNS, StatefulSet self-rules, and `meta.network.intents`.
- `processInstance` runs post-fixpoint over `allPartResources`. It adds the supplements that need the whole instance closure: api-server egress (the SA→binding walk) and external-ingress (LoadBalancer detection). These CNPs do not gate workload readiness; they float to an earlier wave to grant permissions before the workload starts.

### `directions` gating

`networkConfig.directions` (`ingress` | `egress` | `both`, default `both`) gates every emitter. `doEgress`/`doIngress` are checked before building each policy, so a cluster enforcing only one direction gets only those rules.

## meta.network.intents: declarative connectivity

The store-path graph misses two kinds of edges: traffic to the outside world (no store path for "the internet"), and intra-package traffic inside an opaque Helm chart (the chart's internal Services are not wired through kix `out.*`). For these you declare intents under `meta.network.intents`. Each named intent has an `egress` and/or `ingress` list. `translateIntentRules` (in `kix/packages/cilium-external/netpol-rules.nix`) converts them to enforcer-native rules.

Egress rule `to` targets: `"world"` (with optional `entities`, default `[ "world" ]`), `"apiserver"`, `"dns"`. Ingress rule `from` sources: `"world"` (optional `entities`), `"all-pods"` (maps to Cilium entity `cluster`). Both accept an optional `ports` list (`{ port; protocol; }`). An unknown target/source throws at eval time.

World egress, from `kix/packages/stackgres-operator/default.nix` (the operator fetches extensions at runtime):

```nix
meta = {
  version = "1.18.6";
  defaultAliases = [ "stackgresOperator" ];
  network.intents = {
    external = {
      egress = [ { to = "world"; } ];
    };
  };
};
```

Opaque-Helm intra-package ingress, from `kix/packages/loki/default.nix` (gateway → backend is invisible through the chart):

```nix
network.intents = {
  intra-package = {
    ingress = [
      {
        from = "all-pods";
        ports = [
          { port = 3100; protocol = "TCP"; }  # Loki HTTP API
          { port = 9095; protocol = "TCP"; }  # gRPC
        ];
      }
    ];
  };
};
```

`externalIngressEntities` lives alongside `intents` under `meta.network`. It does not create a policy on its own; it only changes the entity list of the auto-derived LoadBalancer ingress supplement. From `kix/packages/caddy/default.nix`:

```nix
network = {
  externalIngressEntities = [ "all" ];
  intents = {
    external = { egress = [ { to = "world"; entities = [ "all" ]; } ]; };
  };
};
```

## meta.provides and capability ownership

`meta.provides` is a list of capability names this package owns. It does two things.

First, it is how kix finds the enforcer. The cluster looks up the package whose `meta.provides` contains `"network-policy-enforcer"` and routes every generated CNP through its `out.netpol.mkPolicy` (binding the right CRD ref). Cilium declares it:

```nix
# kix/packages/cilium/default.nix
meta.provides = [ "cni" "network-policy" "network-policy-enforcer" "cilium" ];
```

When `networkPolicy.enable = true`, an enforcer instance MUST be declared, or kix throws at cluster eval time (the CNP→CRD→enforcer store-path edge would otherwise be missing and policies would race the operator at apply time). For externally-managed Cilium use `packages."cilium".external`, which emits only the CNP CRD-ref marker without deploying Cilium.

Second, `provides` participates in the `capabilityOwnership` scorecard rule (`kix/lib/rules/architecture.nix`, see 11-scorecard.md). The principle: resources are owned by the capability that provides them. A storage provider owns PVCs; a reflector owns cross-namespace reflection wiring; prometheus-operator owns ServiceMonitors. Consumers request these via a DI dep arg and call the owner's `out.mk*` builder (see 07-dependency-injection.md); they do not hand-roll equivalents.

The rule is fingerprint-driven. A resource matches a fingerprint by kind, annotation domain, or label domain. The package is considered to OWN that capability iff either:

- `meta.provides` contains the capability name, OR
- one of its emitted resources carries the annotation `kix.dev/capability: <name>`.

That annotation is the key mechanism. When a consumer calls the owner's builder (for example `reflector.out.reflectSecret`), the builder stamps `kix.dev/capability` on the resources it returns. So the rule can tell "built inline" (fires) from "built via the owner's DI builder" (passes) with no provenance machinery. The reflector owner sets it directly and declares the capability:

```nix
# kix/packages/reflector/default.nix
meta = {
  version = "10.0.28";
  provides = [ "reflection" ];
  defaultAliases = [ "reflector" ];
};
# ... and its builder stamps:  "kix.dev/capability" = "reflection";
```

Current built-in fingerprints: `storage` (any `PersistentVolumeClaim`) and `reflection` (the `reflector.v1.k8s.emberstack.com` domain). If your package emits a fingerprinted resource and does not own the capability, the rule fires with a suggestion to use DI.

## Full meta field reference

`meta` is a static attrset on the package (see 02-package-anatomy.md). Fields fall into two groups: descriptive (passed through to the PackageInstance marker and consumed by tooling like migration detection) and enforced (checked by `kix/lib/meta.nix` at build time).

Descriptive (informational, not validated):

- `version` - package version string, semver-ish `major.minor[.patch]`. Used by dependent packages' `compatibleWith` checks and surfaced as `out.version`.
- `description` - one-line human summary.
- `lifecycle` - workload nature. `kix/lib/k8s.nix` documents the accepted set as `"stateful"`, `"durable"`, `"ephemeral"`, or `null` (treated as `ephemeral`), and uses it for migration-pair detection. It is not enum-validated, so packages also set values like `"stateless"`. Surfaced on the PackageInstance marker.
- `maintainer` - owning team/person, e.g. `"platform"`.
- `provides` - capability names owned (see above).
- `defaultAliases` - DI resolution keys, used unless the instance overrides `aliases` (see 07-dependency-injection.md and 12-overrides.md).
- `network` - `{ intents; externalIngressEntities; }` (see above).

Enforced at eval time (failed assertions throw at cluster eval via `collectClusterDiagnostics`). The first four are checked by `checkMetaStatic` in `kix/lib/meta.nix`; `scope` is checked separately in `kix/lib/eval/instance.nix`:

- `k8s.minVersion` / `k8s.maxVersion` - checked against the cluster's `k8sVersion` option. Out-of-range fails the build. Cilium sets `k8s.minVersion = "1.27"`.
- `compatibleWith.<depName>` - `{ minVersion?; maxVersion?; reason?; }` constraints checked against each resolved dependency's `version`. Version mismatch fails the build with the optional `reason` appended.
- `conflictsWith` - list of instance/alias names. A bare name conflicts within the same namespace; a `"cluster:"`-prefixed name conflicts cluster-wide. If a matching other instance exists, the build fails listing the offenders.
- `deprecated` - `{ message?; replacement?; }`. Emits a build-time warning (not an error), with "use '<replacement>' instead" appended when set.
- `scope` - `"namespace"` or `"cluster"` (default `"cluster"` when unset). Enforced in `kix/lib/eval/instance.nix` (`_crossNsCheck`): a dependency that declares `meta.scope = "namespace"` and is resolved in a different namespace than the consumer throws ("cross-namespace reference not allowed"). `"cluster"` packages can be consumed from any namespace. Examples: `secret`, `persistent-volume-claim`, `secret-ref` all set `scope = "namespace"`.

Package-declared `warnings` and `assertions` functions (called with `{ config; self; deps; }`) are evaluated separately by `evaluatePackageDiagnostics`; see 02-package-anatomy.md.

## Gotchas

- **hostNetwork pods cannot be gated by CiliumNetworkPolicy.** `buildWorkloadCnps` skips CNP emission entirely for a hostNetwork workload, and `processInstance` emits a warning: `workload '<kind>/<name>' uses hostNetwork — CiliumNetworkPolicy has no effect`. hostNetwork is also no longer an external-ingress trigger (the old behavior wrongly granted world-ingress to *sibling* workloads).
- **Opaque Helm packages warn.** If `meta.isHelm` is set, `processInstance` warns that intra-package edges may be missing. That is exactly the case `meta.network.intents` exists to patch (see the Loki example).
- **An enforcer is mandatory when `networkPolicy.enable = true`.** No resolved `network-policy-enforcer` provider means a throw at eval time, not a silent no-op.
- **A literal selector or hand-rolled FQDN produces no edge.** Network policy derivation is only as good as the store-path context. A Service selector written as a literal `{ app = "..."; }`, or a `"name.ns.svc"` FQDN string typed by hand, carries no context, so no egress rule is derived and the workload silently fails under default-deny. The `selectorCoherence` and `fqdnWithoutContext` rules (`kix/lib/rules/architecture.nix`) catch both; use `kix.service.fromWorkload` and `out.fqdn`/`out.host` instead (see 04-resources-and-out.md, 06-composition-helpers.md).
- **`provides` does not stamp resources.** Declaring `meta.provides = [ "x" ]` makes the package OWN capability `x` (so its own resources pass the rule), but it does NOT put `kix.dev/capability` on consumers' resources. Only an owner's `out.mk*` builder does that, which is why consumers must go through the builder, not just resolve the dep.

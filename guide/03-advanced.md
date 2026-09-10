# Advanced & overrides

Secrets/CRDs/RBAC, derived networking + meta, Helm packages, scorecard, and cluster-side overrides.

Sections: [Secrets, CRDs, RBAC](#secrets-crds-rbac) · [Networking & package meta](#networking--package-meta) · [Helm-backed packages](#helm-backed-packages) · [Scorecard & rules](#scorecard--rules) · [Overrides](#overrides) · [Store-path context internals](#store-path-context-and-closure-internals)

## Secrets, CRDs, RBAC

Scope helpers for Secrets, CRDs + their CRs, RBAC, and admission webhooks. All are methods on the per-instance `scope` (see 02-authoring.md#resources-and-the-out-surface). All track dependencies via Nix string context, not data (see 01-fundamentals.md#overview--mental-model, store-path DAG).

### Secrets

#### scope.mkSecret

kix-managed `Secret` with key-aware `out`. Source: `kix/lib/eval/scope.nix` (`mkSecret`); `out` helpers in `kix/lib/k8s.nix` (`mkSecretHelpers`).

Contents, pick one:

- `stringData` - inline values (dev / config-derived).
- `source` + `hash` - SOPS-encrypted file; kix-deploy hydrates ciphertext at deploy time, `hash` is the change-detection signal.

```nix
creds = scope.mkSecret {
  name = "db-credentials";
  keys = [ "username" "password" ];
  stringData = { username = "admin"; password = "s3cret"; };
};
```

- `keys` = declared key names; drives build-time validation in `out`. Omit -> derived from `attrNames stringData`. Neither `keys` nor `stringData` -> throws.
- Annotations: always `kix.run/secret-keys`; `source` -> `kix.run/sops-source`; `hash` -> `kix.run/content-hash`; `meta.classification` / `meta.rotationPolicy` -> own annotations.

`out` API (`mkSecretHelpers`), each validates requested keys against declared `keys` at build time:

| Helper | Maps | Returns |
|---|---|---|
| `out.mkEnv { ENV = "key"; ... }` | env var names -> keys | list of env entries (`keyRef` per entry + `name`) |
| `out.keyRef "key"` | single key | `{ valueFrom.secretKeyRef = { name; key; }; }` |
| `out.envFrom` | all keys as env | `{ secretRef = { name; }; }` |
| `out.volume "vol-name"` | mount | `{ name; secret.secretName; }` |

```nix
env    = creds.out.mkEnv { DB_USER = "username"; DB_PASS = "password"; };
pw     = creds.out.keyRef "password";
allEnv = [ creds.out.envFrom ];
vol    = creds.out.volume "db-creds-vol";
```

- `keyRef "nope"` throws `secret "db-credentials" does not declare key "nope"` (lists declared keys); typos fail at eval, not pod startup.
- Each helper attaches the Secret's store-path context to the name string and stamps `_kix.namespace` -> how workload `checkNamespacedRefs` (see 02-authoring.md#workloads) knows the ref is DI-tracked + same-namespace.

##### realizedSource gotcha

- `source` is NOT referenced by path directly. `mkSecret` runs `builtins.path { path = source; ... }` to force-copy the file into the store (`realizedSource`), then stamps `toString realizedSource` into `kix.run/sops-source`.
- Without this, a self-relative path (`./secrets/x.enc.yaml`) dangles (`path '/nix/store/…-source' is not valid`) under strict Linux sandbox / CI. macOS's loose sandbox tolerates it, so the bug only bites in CI.
- Ciphertext is deliberately NOT a manifest DAG edge; change detection is `hash`'s job. Re-encrypting same plaintext does not redeploy.

#### scope.mkSecretRef

For secrets kix does not create (Vault, ESO, cert-manager, bootstrap). Emits a `PackageInstance` import marker (see below), not a `Secret`, but exposes the same `out.{name, keyRef, mkEnv, envFrom, volume}` as `mkSecret`. Consumers can't tell.

```nix
creds = scope.mkSecretRef {
  name = "vault-db-creds";
  keys = [ "username" "password" ];
};
env = creds.out.mkEnv { DB_USER = "username"; };
```

- CLI deploy engine (`cli/kix/src/cluster/readiness.rs`) polls for the named Secret; when `keys` non-empty, waits until every declared key is in `data` before any consuming wave. Build-time validation -> deploy-time gate.
- Marker store-path context flows onto `out.name` -> consuming workload gets a forward-closure DAG edge to the marker (won't deploy until external secret exists). Satisfies workload ref checks that reject untracked refs.
- `keys = [ ]` allowed (referenced via `envFrom`/`volume` only); CLI then only checks existence. `keyRef` still throws "does not declare key" at use site.
- Marker name = `secret-ref-${instanceName}-${name}` -> two instances can reference the same external secret without colliding.
- Cross-namespace consumption rejected by default (K8s disallows). If mirrored by emberstack reflector, pass `reflect = true` -> stamps `_kix.reflected = true`, relaxing the same-namespace check in `checkNamespacedRefs`. Producer must still put reflector annotations on the source Secret.

### The import marker

`mkSecretRef` and `mkCRDRef` both build on `mkImportMarker` (`kix/lib/eval/scope.nix`):

- Emits a namespaced `PackageInstance` annotated `kix.run/mode=import` + `kix.run/import-{kind,apiversion,name}`.
- CLI readiness parses these into an `ImportTarget`, gates consuming waves until the resource exists (and for Secrets, all `expected_keys` present).
- Marker lives in consumer's namespace; imported resource expected in same namespace. Cross-namespace imports unsupported.
- Every marker `requires` the kix `PackageInstance` CRD, plus `extraRequires` (how `installedBy` works).

### CRDs

#### scope.mkCRD

Takes a K8s-native CRD spec, returns a cluster-scoped `CustomResourceDefinition` whose `out` is extended with CR builders (`cr`, `mkCR`). Build the spec with `scope.crd` pipe transforms (`kix/lib/crd.nix`):

```nix
mkCrdInput = def:
  scope.crd.fromKind def.kind (
    lib.recursiveUpdate { spec.group = sgGroup; } (def.specOverrides or { })
  )
  |> scope.crd.withShortNames def.shortNames
  |> scope.mkCRD;
```

Transforms (`crd.nix`), all consume + produce the CRD spec attrset (chain with `|>`):

| Transform | Effect |
|---|---|
| `fromKind kind extra` | seed full spec from kind. Auto `plural` (lowercase+"s"), `singular`, `listKind` (`<Kind>List`). Defaults: `scope = "Namespaced"`, version `v1`, permissive schema (`x-kubernetes-preserve-unknown-fields` on `spec`/`status`), `status` subresource. `extra` is `recursiveUpdate`-merged (override e.g. `spec.names.plural` for irregular plurals). |
| `clusterScoped` | `spec.scope = "Cluster"` |
| `withShortNames [...]` / `withCategories [...]` | add to `spec.names` |
| `withVersion v` / `withPrinterColumns cols` | rewrite all versions |
| `withSchema schema` | replace `spec` property's openAPIV3Schema on every version (real schema vs permissive default) |
| `withLabels` / `withAnnotations` | set metadata on the CRD resource (not spec) |

```nix
crd.fromKind "SGCluster" { spec.group = "stackgres.io"; }
|> crd.clusterScoped
|> crd.withShortNames [ "sgclu" ]
|> crd.withSchema mySchema
|> scope.mkCRD
```

- `mkCRD` derives name `${plural}.${group}`; reads `version`, `kind`, `scope` from spec to wire CR builders. Returns `out = crdResource.out // builders` (builders from `mkCRDBuilders` in `kix/lib/k8s.nix`).

#### Custom resources: out.cr, out.mkCR, scope.mkCR

`mkCRDBuilders` returns two builder styles:

- `out.cr args` - pure transform: stamps `apiVersion = "${group}/${version}"` + `kind`, appends CRD to `requires`. You pass result to `scope.mkResource` / `scope.mkClusterResource`.
- `out.mkCR consumerScope args` - full builder, curried on scope. Runs `cr`, auto-routes to `mkResource`/`mkClusterResource` by CRD scope. `crd.out.mkCR scope` -> `args -> resource` function.

CRD added to each CR's `requires` -> wave graph places CRD (or import marker) before any CR using it (forward-closure walker). No string context on `apiVersion`/`kind`.

```nix
mkIssuerCR = certManager.crds.clusterIssuers.out.mkCR scope;
issuer = mkIssuerCR {
  name = "letsencrypt";
  spec.acme = { server = ...; email = ...; };
};
```

`scope.mkCR crd args` = sugar for `crd.out.mkCR scope args` using package's own scope.

#### scope.mkCRDRef

CRD installed by something other than kix (operator `INSTALL_CRDS`, Helm chart, pre-existing). Emits a `PackageInstance` import marker (same machinery as `mkSecretRef`), attaches same `out.{cr, mkCR}`. CLI polls for the CRD, waits until `Established=True`, gating the wave with any CR built through the ref.

```nix
cnpCrdRef = scope.mkCRDRef {
  group = "cilium.io";
  kind = "CiliumNetworkPolicy";
  plural = "ciliumnetworkpolicies";
  version = "v2";
  crdScope = "Namespaced";
  installedBy = resources.workloads;
};
```

- `installedBy` gates the marker. Single resource or list. Each entry -> hard `requires` edge -> CR's wave waits on all being Ready (not merely applied). For Helm-bundled operators (CRD + DaemonSet + operator Deployment), pass the whole workload list so the CRD waits for every webhook-serving component.
- `mkCRDBuilders` auto-adds the marker to every CR's `requires`; no `root.requires` plumbing.

### RBAC

`scope.rbac` (`kix/lib/rbac.nix`): pipe DSL for `rules` lists + `mkClusterRoleSet` / `mkRoleSet` for paired Role+Binding boilerplate.

#### Rule DSL

Model: `Ref` points at a resource type; an `intent` turns `Ref` (or `[Ref]`) into `[Rule]`; `grant` flattens + merges intent results.

`group apiGroup [ resources ]` -> Ref. Result is both attrset (dot access) and callable fallback for unlisted resources:

```nix
inherit (scope.rbac) grant allow core;
discovery = scope.rbac.group "discovery.k8s.io" [ "endpointslices" ];
# core = "" group pre-populated (pods, services, secrets, ...)
# core.pods, core.services, discovery.endpointslices
# group "x" [] |> (g: g "ondemand")  for unlisted resources
```

Ref modifiers (chain before an intent):

- `restrictTo [ names ]` - sets `resourceNames`.
- `sub "status"` / `sub "finalizers"` - subresource (`resource/status`). `map (sub "status") refs` for lists.

Intents (`Ref | [Ref] -> [Rule]`):

- `watch` (get/list/watch), `reconcile` (get/list/watch + patch/update + status patch/update), `own`, `readWrite`, `full`, `emit` (create/patch), `finalize`, `watchAndFinalize`.
- `allow [ verbs ]` - explicit verb list.

`grant [ [Rule] [Rule] ... ]` concatenates + merges rules sharing `apiGroups` + `verbs` + `resourceNames`, combining `resources`.

```nix
roles = {
  "${controllerName}" = grant [
    ([ core.pods core.serviceaccounts ] |> allow [ "list" "watch" ])
    (actionResources |> full)
    (map (sub "finalizers") actionResources |> allow [ "patch" "update" ])
    (map (sub "status") actionResources |> allow [ "get" "patch" "update" ])
  ];
};
```

#### mkClusterRoleSet / mkRoleSet

Take package `scope` + `{ subjects, labels?, roles }`; return flat attrset `{ <roleName> = <Role>; "<roleName>-binding" = <Binding>; ... }`.

- `mkClusterRoleSet` -> `ClusterRole` + `ClusterRoleBinding`.
- `mkRoleSet` -> namespaced `Role` + `RoleBinding`.
- Each `roles` entry: plain rules list, or `{ rules, bindingName? }`.

Merge result onto `self` with `//`; feed `builtins.attrValues` into a `requires` list.

```nix
self:
{ ... }
// scope.rbac.mkClusterRoleSet scope {
  subjects = [{
    kind = "ServiceAccount";
    name = self.serviceAccount.out.name;
    namespace = scope.namespaceName;
  }];
  labels = commonLabels;
  roles = {
    "${scope.instanceName}" = grant [
      ([ core.endpoints core.services core.pods ] |> allow [ "list" "watch" ])
    ];
  };
}
```

Binding's `roleRef.name` = `role.out.name` (context-carrying) -> Binding orders after its Role.

### mkWebhookService

`scope.mkWebhookService` builds an admission-webhook `Service` + its `ValidatingWebhookConfiguration` and/or `MutatingWebhookConfiguration` in one call. Returns `{ service, validatingConfiguration?, mutatingConfiguration? }` to spread into `self`.

```nix
webhook = scope.mkWebhookService {
  name = "my-operator-webhook";
  selector = self.operatorDeployment.rawSelector;
  port = 443;              # default
  targetPort = "webhook";  # default container port name
  validating = [{
    name = "validate.example.com";
    path = "/validate";
    rules = [{ apiGroups = [ "example.com" ]; resources = [ "widgets" ]; }];
  }];
};
# self // { inherit (webhook) service validatingConfiguration; }
```

- Hook entry: `{ name, path, rules, failurePolicy?, sideEffects?, timeoutSeconds?, admissionReviewVersions?, matchPolicy? }`.
- `rules` entry: `{ resources, operations?, apiGroups?, apiVersions?, scope? }`.
- Per-rule defaults: `operations = [ "CREATE" "UPDATE" ]`, `apiGroups`/`apiVersions = [ "*" ]`, `scope = "*"`.
- Per-hook defaults: `admissionReviewVersions = [ "v1" ]`, `sideEffects = "None"`, `failurePolicy = "Fail"`, `matchPolicy = "Equivalent"`, `timeoutSeconds = 10`.
- Service `out.name` (context) feeds each webhook's `clientConfig.service` -> Service -> Config ordering automatic.
- `caBundle` optional; `null` default -> consumer patches post-deploy (cert-manager CA injector, Helm hook).
- Use `self.<workload>.rawSelector` (not `out.selector`) for `selector` to avoid hashing the full workload manifest (see 02-authoring.md#workloads, `rawSelector`).

### Gotchas

- Set CR `apiVersion`/`kind` by hand instead of `out.cr`/`out.mkCR` -> lose the auto `requires` edge to the CRD; the CR can land before its CRD exists.
- `mkWebhookService` `selector`: use `rawSelector`, not `out.selector`, when the workload also references a `self` resource (`out.selector` can cycle).
- Cross-namespace `mkSecretRef`/`mkCRDRef` is unsupported; run an adapter instance in the owning namespace and DI the handle (see 02-authoring.md#dependency-injection).

## Networking & package meta

Network policy is derived from the dependency graph; packages author zero CNPs. `meta.network.intents` is the escape hatch for edges the store-path graph cannot see. Plus the full `meta` field reference.

Sources: `kix/lib/netpol.nix` (derivation), `kix/lib/meta.nix` (validation), `kix/lib/modules.nix` (`networkPolicy` / `cluster.network` options), `kix/lib/rules/architecture.nix` (`capabilityOwnership`), `kix/packages/cilium-external/netpol-rules.nix` (enforcer rule builder).

### Network policy is derived, not declared

`networkPolicy.enable = true` (`kix/lib/modules.nix`) -> kix synthesizes CiliumNetworkPolicies (CNPs) from the store-path DAG and resource set. Packages write none. Five derived signals, no meta field required:

- **Cross-package Service egress.** Workload manifest references a Service store path (via `kix.service.fromWorkload`, `svc.out.fqdn`, any `out.*`; see 02-authoring.md#composition-helpers-kix) -> DAG edge. `extractServiceEdgesFromJson` walks `builtins.getContext` of workload args' JSON, matches the cluster Service registry, emits egress to that Service's pod selector + ports.
- **DNS egress.** Every egress policy includes `enforcerApi.dnsEgressRule`. Any workload with cross-instance Service edges also gets the DNS instance root injected as deploy-ordering dep (`dnsDeps`, spliced into `requires` by `scope.mkWorkload`). Runs even when `networkPolicy.enable = false` (DNS ordering is a platform concern, not netpol).
- **API-server egress.** `processInstance` emits `apiServerEgressRule` only if the workload's ServiceAccount is the subject of a `RoleBinding`/`ClusterRoleBinding` in the instance closure (`boundSAKeys` walk). RBAC presence alone is insufficient; the SA must be bound.
- **External (LoadBalancer) ingress.** Instance has a `Service` of `type: LoadBalancer` -> non-hostNetwork workloads get a world-ingress supplement. Entities default `[ "world" ]`, overridable via `meta.network.externalIngressEntities`. (hostNetwork no longer a trigger; see Gotchas.)
- **Self-communication.** `StatefulSet` workloads get self-ingress + self-egress (same-selector pods), via `enforcerApi.mkSelfRules`.

Plus a per-namespace **default-deny** CNP when `networkPolicy.defaultDeny = true` (default). `generateDefaultDeny` respects `directions` (egress-only cluster denies only egress).

#### Two emission sites

- `buildWorkloadCnps` - inside the workload constructor (`scope.mkDeployment` et al.), BEFORE the workload is built. Returned CNPs spliced into workload `requires`, so workload store-path context transitively includes its policies and `kix deploy` places them an earlier wave. Closes the Ready-but-policy-not-applied window. Handles workload-args signals: service egress, DNS, StatefulSet self-rules, `meta.network.intents`.
- `processInstance` - post-fixpoint over `allPartResources`. Adds closure-wide supplements: api-server egress (SA->binding walk), external-ingress (LoadBalancer detection). These do not gate workload readiness; float to an earlier wave to grant permissions before workload start.

#### `directions` gating

`networkConfig.directions` (`ingress` | `egress` | `both`, default `both`) gates every emitter. `doEgress`/`doIngress` checked before building each policy.

### meta.network.intents: declarative connectivity

Two edge kinds the store-path graph misses: outside-world traffic (no store path for the internet), intra-package traffic in an opaque Helm chart (internal Services not wired through `out.*`). Declare under `meta.network.intents`. Each named intent has `egress` and/or `ingress` lists. `translateIntentRules` (`kix/packages/cilium-external/netpol-rules.nix`) converts to enforcer-native rules.

- Egress `to`: `"world"` (optional `entities`, default `[ "world" ]`), `"apiserver"`, `"dns"`.
- Ingress `from`: `"world"` (optional `entities`), `"all-pods"` (Cilium entity `cluster`).
- Both accept optional `ports` (`{ port; protocol; }`).
- Unknown target/source throws at eval time.

World egress - `kix/packages/stackgres-operator/default.nix` (fetches extensions at runtime):

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

Opaque-Helm intra-package ingress - `kix/packages/loki/default.nix` (gateway -> backend invisible through the chart):

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

`externalIngressEntities` - sibling of `intents` under `meta.network`. Creates no policy; only changes the entity list of the auto-derived LoadBalancer ingress supplement. `kix/packages/caddy/default.nix`:

```nix
network = {
  externalIngressEntities = [ "all" ];
  intents = {
    external = { egress = [ { to = "world"; entities = [ "all" ]; } ]; };
  };
};
```

### meta.provides and capability ownership

`meta.provides` - list of capability names the package owns. Two effects.

**1. Enforcer lookup.** Cluster finds the package whose `meta.provides` contains `"network-policy-enforcer"` and routes every CNP through its `out.netpol.mkPolicy` (binds the right CRD ref). Cilium declares it:

```nix
# kix/packages/cilium/default.nix
meta.provides = [ "cni" "network-policy" "network-policy-enforcer" "cilium" ];
```

- `networkPolicy.enable = true` requires a declared enforcer instance, else kix throws at cluster eval (missing CNP->CRD->enforcer store-path edge would race the operator at apply time).
- Externally-managed Cilium: `packages."cilium".external` - emits only the CNP CRD-ref marker, deploys no Cilium.

**2. `capabilityOwnership` scorecard rule** (`kix/lib/rules/architecture.nix`; see 03-advanced.md#scorecard--rules). Principle: resources owned by the capability that provides them (storage provider owns PVCs; reflector owns cross-ns reflection; prometheus-operator owns ServiceMonitors). Consumers request via DI dep arg + owner's `out.mk*` builder (see 02-authoring.md#dependency-injection); they do not hand-roll.

Fingerprint-driven. A resource matches a fingerprint by kind, annotation domain, or label domain. Package OWNS the capability iff:

- `meta.provides` contains the capability name, OR
- an emitted resource carries annotation `kix.run/capability: <name>`.

The annotation is the key mechanism. Owner builder (e.g. `reflector.out.reflectSecret`) stamps `kix.run/capability` on returned resources, so the rule distinguishes "built inline" (fires) from "built via owner's DI builder" (passes) with no provenance machinery:

```nix
# kix/packages/reflector/default.nix
meta = {
  version = "10.0.28";
  provides = [ "reflection" ];
  defaultAliases = [ "reflector" ];
};
# ... and its builder stamps:  "kix.run/capability" = "reflection";
```

Built-in fingerprints: `storage` (any `PersistentVolumeClaim`), `reflection` (`reflector.v1.k8s.emberstack.com` domain). Emit a fingerprinted resource without owning the capability -> rule fires, suggests DI.

### Full meta field reference

`meta` is a static attrset on the package (see 01-fundamentals.md#package-anatomy). Descriptive fields pass through to the PackageInstance marker (consumed by tooling like migration detection); enforced fields are checked by `kix/lib/meta.nix` at build time.

Descriptive (informational, not validated):

| Field | Meaning |
|---|---|
| `version` | Version string, semver-ish `major.minor[.patch]`. Used by dependents' `compatibleWith`; surfaced as `out.version`. |
| `description` | One-line human summary. |
| `lifecycle` | Workload nature. `kix/lib/k8s.nix` documents `"stateful"`, `"durable"`, `"ephemeral"`, `null` (= `ephemeral`); used for migration-pair detection. Not enum-validated, so packages also set e.g. `"stateless"`. Surfaced on PackageInstance marker. |
| `maintainer` | Owning team/person, e.g. `"platform"`. |
| `provides` | Capability names owned (see above). |
| `defaultAliases` | DI resolution keys, used unless instance overrides `aliases` (see 02-authoring.md#dependency-injection, 03-advanced.md#overrides). |
| `network` | `{ intents; externalIngressEntities; }` (see above). |

Enforced at eval time (failed assertions throw via `collectClusterDiagnostics`). First four checked by `checkMetaStatic` in `kix/lib/meta.nix`; `scope` checked in `kix/lib/eval/instance.nix`:

| Field | Constraint |
|---|---|
| `k8s.minVersion` / `k8s.maxVersion` | Checked against cluster `k8sVersion`. Out-of-range fails build. Cilium sets `k8s.minVersion = "1.27"`. |
| `compatibleWith.<depName>` | `{ minVersion?; maxVersion?; reason?; }` checked against each resolved dependency's `version`. Mismatch fails build with optional `reason` appended. |
| `conflictsWith` | List of instance/alias names. Bare name conflicts within same namespace; `"cluster:"`-prefixed conflicts cluster-wide. Matching other instance -> build fails listing offenders. |
| `deprecated` | `{ message?; replacement?; }`. Build-time warning (not error); "use '<replacement>' instead" appended when set. |
| `scope` | `"namespace"` or `"cluster"` (default `"cluster"`). Enforced in `kix/lib/eval/instance.nix` (`_crossNsCheck`): a dep with `meta.scope = "namespace"` resolved in a different namespace than the consumer throws ("cross-namespace reference not allowed"). `"cluster"` consumable from any namespace. Examples: `secret`, `persistent-volume-claim`, `secret-ref`. |

Package-declared `warnings` / `assertions` functions (called with `{ config; self; deps; }`) are evaluated separately by `evaluatePackageDiagnostics`; see 01-fundamentals.md#package-anatomy.

### Gotchas

- **Literal selector / hand-rolled FQDN produces no edge.** A literal `{ app = "..."; }` selector or hand-typed `"name.ns.svc"` FQDN carries no store-path context -> no egress rule -> workload silently fails under default-deny. `selectorCoherence` / `fqdnWithoutContext` (see 03-advanced.md#scorecard--rules) catch both; use `kix.service.fromWorkload` and `out.fqdn` (see 02-authoring.md#composition-helpers-kix).
- **`provides` does not stamp resources.** `meta.provides = [ "x" ]` makes the package OWN capability `x`; it does NOT put `kix.run/capability` on a consumer's resources. Consumers must go through the owner's `out.mk*` builder, not just resolve the dep.
- **Opaque Helm packages warn.** `meta.isHelm` -> `processInstance` warns intra-package edges may be missing; patch with `meta.network.intents`.
- **hostNetwork bypasses CNPs.** `buildWorkloadCnps` skips emission and `processInstance` warns; hostNetwork is not an external-ingress trigger.

## Helm-backed packages

Wrap upstream Helm charts; turn rendered manifests into first-class kix resources. Code: `kix/lib/helm.nix` (fetch, template, wrap, `importChart`, `mkParts`), `kix/lib/helm-dag.nix` (intra-chart edge inference).

Mechanism: chart rendered once via IFD (`helm template`), every resource re-wrapped through `scope.mkResource` so it joins the same store-path DAG, identity hashing, and netpol generation as a hand-written package (see 02-authoring.md#resources-and-the-out-surface).

### Three tiers

| Tier | Entry point | Where | Control |
|------|-------------|-------|---------|
| 1 | `kix.helmChart { repo; name; version; hash; }` | inline in cluster def | minimal: `config.values`, auto root |
| 2 | `scope.helm.importChart { chart; scope; ... }` then `resources.mkParts { root = ...; }` | inside package `build` | full: explicit root, extra deps, network deps, strip, resource replacement |
| 3 | `scope.helm.importChartCrds { chart; scope; }` (or hand-rolled CRDs) | native package wrapping a charted upstream | package authors workloads, borrows only chart CRDs |

All sit on two primitives: `fetchHelmChart` (content-pinned fetch) and `importChart` / `importChartCrds` (IFD render + wrap).

### fetchHelmChart: content-pinning

Fixed-output derivation pulling a chart tarball from OCI or HTTP registry. Pins exact bytes via `hash`; chart is part of the reproducible build, not fetched at deploy time.

```nix
chart = scope.helm.fetchHelmChart {
  repo = "https://helm.cilium.io/";
  name = "cilium";
  version = "1.16.5";
  hash = "sha256-GCA1rnws+NGUkOzs9hj2oRrcRg7R59vTiyMGXwLxi00=";
};
```

- `repo` `oci://` -> `helm pull oci://...`; else `helm repo add` + `helm pull`.
- Hash algo inferred from prefix (`sha256-` -> sha256, else sha512).
- Fresh hash: build with wrong/empty hash, copy value Nix reports.

### Tier 1: kix.helmChart inline

Returns a complete package function; drop into an instance's `package` field, no separate package file. Single `values` option. Uses `autoRoot` (first Service, else Deployment, else StatefulSet, else DaemonSet, else first resource) as entry point.

```nix
homeassistant.homeassistant = {
  package = kix.helmChart {
    repo = "https://pajikos.github.io/home-assistant-helm-chart";
    name = "home-assistant";
    version = "0.3.51";
    hash = "sha256-gcZzrAYS23YiOyVJg8cIntyBQmF/Q+/d0q5sKWtl8WY=";
    releaseName = "homeassistant";
    patchResources = map (
      r:
      if r.kind == "Service" && r.metadata.name == "homeassistant-home-assistant" then
        r // { spec = r.spec // { clusterIP = "None"; }; }
      else
        r
    );
  };
  config.values = { ingress.enabled = false; };
};
```

Args: `repo`, `name`, `version`, `hash`, optional `releaseName` (default `name`), `includeCrds` (default `true`), `strip`, `patchResources` (raw-JSON transform applied before wrapping; above sets `clusterIP: None` on one Service). Instance sets `config.values = { ... }`. Use for quick one-offs; move to Tier 2 when you need explicit root, cross-package wiring, or resource replacement.

### Tier 2: scope.helm.importChart inside a package

Not a package, not a factory; a tool called inside `build`. Runs `helm template` via IFD, parses JSON, reconstructs intra-chart DAG, wraps every resource through scope, returns a structured collection. Pick a root, call `resources.mkParts`.

Minimal shape (`kix/packages/redis/default.nix`):

```nix
build =
  { config, scope, ... }:
  let
    resources = scope.helm.importChart {
      inherit chart scope;
      values = lib.recursiveUpdate defaultValues (config.values or { });
      releaseName = scope.instanceName;
    };
  in
  resources.mkParts {
    root = builtins.head (resources.byKind "StatefulSet");
  };
```

#### Collection API

| Member | Meaning |
|--------|---------|
| `all` | flat list of every wrapped resource |
| `get kind name` | lookup, throws if not found (e.g. `resources.get "DaemonSet" "cilium"`) |
| `find kind name` | lookup, `null` if absent |
| `byKind kind` | all resources of a kind, as list |
| `workloads` | all Deployment/StatefulSet/DaemonSet/Job/CronJob (`helmDag.workloadKinds`) |
| `excluding [resources]` | everything except given resources |
| `attrs` | collection keyed by `"<lowerkind>-<name>"` |
| `edges` | inferred `{ from, to, type }` triples between wrapped resources |
| `depsOf resource` | resource's inferred intra-chart deps |
| `orphans` | diagnostics for selectors/refs matching nothing |
| `crds` | auto-derived `{ cr, mkCR }` per shipped CRD (see below) |
| `autoRoot` | heuristic root (Tier 1 uses this) |
| `replaceResource kind name newResource` | substitution, returns new collection (see below) |
| `mkParts { root; ... }` | assemble final parts tree |

#### importChart knobs

Beyond `chart` and `scope`:

| Knob | Default | Meaning |
|------|---------|---------|
| `values` | `{}` | chart values |
| `releaseName` | `"release"` | |
| `namespace` | `scope.namespaceName` | |
| `includeCrds` | `true` | |
| `includeHooks` | `true` | |
| `extraFlags` | | extra `helm template` flags |
| `strip` | (see below) | annotation/label cleanup |
| `preserveAnnotationPrefixes` | | rescue helm-prefixed annotations |
| `patchResources` | `lib.id` | raw-JSON transform on filtered list before wrapping |
| `extraEdges` | | manually injected intra-chart edges (see below) |
| `deps` | | cross-package wiring for netpol (see below) |
| `networkDeps` | | explicit context-carrying values for netpol (see below) |

Auto: Helm test hooks (`helm.sh/hook` containing `"test"`) dropped; `List` resources unpacked into items; null/empty docs filtered.

#### mkParts and auto-derived out

`mkParts { root, extraParts ? {}, extraRequires ? [], out ? {} }` assembles the `self` attrset. DAG-aware: `root` directly requires only resources NOT targets of intra-chart edges (DAG entry points); everything else reachable transitively since each wrapped resource carries its own `requires` (see 02-authoring.md#resources-and-the-out-surface on `requires`/`identityHash`). Same forward-closure deploy ordering as a native package.

Auto-derived public `out` for `root` (see 01-fundamentals.md#package-anatomy, 02-authoring.md#resources-and-the-out-surface):

- `out.byKind.<Kind>.<name>` always emitted; stable flat lookup so a downstream package reaches a non-root resource. E.g. `redis.out.byKind.Service.redis-master.out.fqdn`.
- Service promotion: when `root` is a workload (Deployment/StatefulSet/DaemonSet/Job) and exactly one Service selects it (via `selects` DAG edge), that Service's `out.{name, fqdn, selector, ports, url}` promoted onto root's `out`. So `pkg.out.fqdn` is the Service FQDN, not the workload's synthetic one. Skipped silently on 0 or >1 matches; then supply via explicit `out` arg.
- `root.kind == "Service"`: no promotion (scope already derived right outs); only `byKind` added.
- `out.crds.<Kind> = { cr, mkCR }` per shipped CRD (Phase 3, see below).

User `out = { ... }` shallow-merges over auto-derived (user wins on collisions). `extraParts` merges additional named parts (CRD refs, extra resources) into `self`.

### Intra-chart dependency inference (helm-dag.nix)

Reconstructs edges from raw JSON before wrapping; inferred deps become real `requires` (part of content hash and `kix.run/depends-on`). Edge direction "from depends on to"; `to` deploys first. Patterns:

- Workload -> ServiceAccount (`serviceAccountName`).
- Workload -> ConfigMap/Secret via volumes (incl. projected sources), `envFrom`, `env[].valueFrom.*KeyRef`.
- RoleBinding/ClusterRoleBinding -> ServiceAccount (subjects).
- Service -> Workload (selector label subset match).
- HPA -> Workload (`scaleTargetRef`).
- PodDisruptionBudget -> Workload (selector match).
- Ingress -> Service and HTTPRoute -> Service (backend refs).
- ServiceMonitor -> Service (selector match).

What the DAG can't see from a manifest reference needs `extraEdges`. Example (`kix/packages/loki/default.nix`): loki-gateway (nginx) proxies to loki backend with no K8s reference, so edge declared by hand:

```nix
extraEdges = [
  {
    from = { kind = "Deployment"; name = "loki-gateway"; };
    to   = { kind = "StatefulSet"; name = "loki"; };
  }
];
```

`importChart` resolves each `extraEdges` entry against the chart and throws if either endpoint missing (typo fails build, not silent drop).

### Cross-package wiring: deps and networkDeps

For network-policy generation, not deploy ordering. Workload kinds wrapped through `scope.mkHelmWorkload` (skips DI-reference validation that `mkDeployment` does, since helm manifests have no DI references); emit per-workload CiliumNetworkPolicies for DNS egress, self-ingress, cross-package service egress.

- `deps = [ dep, ... ]` - DI dep instances the chart's manifests reference. Phase 2: every context-carrying string at `dep.out.*` (top level only) auto-collected and merged into `networkDeps`, so egress edge to dep is discovered. Dep must also be a `build` arg so its Services land in the netpol service registry (see 02-authoring.md#dependency-injection, 03-advanced.md#networking--package-meta).
- `networkDeps = [ value, ... ]` - explicit context-carrying values that `deps` auto-discovery misses: values nested under `dep.out.byKind.*` or hand-built strings not at a top-level `dep.out.*` attr.

`kix/packages/promtail/default.nix` (modern `deps` form): interpolates `loki.out.fqdn` into config, passes `deps = [ loki ]` so promtail -> loki-gateway egress edge generated automatically (replaces older explicit `networkDeps = [ loki.out.fqdn ]`):

```nix
resources = scope.helm.importChart {
  inherit chart scope;
  values = lib.recursiveUpdate (lib.recursiveUpdate defaultValues lokiValues) (config.values or { });
  releaseName = "promtail";
  deps = [ loki ];
};
```

### Annotation/label stripping (lossy on purpose)

Default `importChart` strips Helm bookkeeping so rendered output matches what the cluster stores (clean diffs vs live cluster; see 03-advanced.md#scorecard--rules). Intentionally lossy.

Dropped by default:
- Annotations with prefixes `meta.helm.sh/`, `helm.sh/`, `checksum/`.
- Labels `app.kubernetes.io/managed-by` (Helm sets `Helm`) and `helm.sh/chart`.
- Default `strategy` / `updateStrategy` blocks matching K8s built-in defaults; Helm-injected pod-template annotations.

Control via `strip` and `preserveAnnotationPrefixes`:

```nix
resources = scope.helm.importChart {
  inherit chart scope;
  strip = {
    helmAnnotations = true;   # default
    helmLabels = true;        # default
    defaultStrategy = true;   # default
  };
  preserveAnnotationPrefixes = [ "meta.helm.sh/" ];  # keep these helm annotations
};
```

`preserveAnnotationPrefixes`: predicate keeps annotation if NOT a helm annotation OR key matches a listed prefix (`!(isHelmAnnotation k) || anyPrefixMatch`). Only affects keys that are already helm annotations (`meta.helm.sh/`, `helm.sh/`, `checksum/`). Listing a non-helm prefix (e.g. `prometheus.io/`) is a no-op (those are never stripped). Use to rescue a specific helm-prefixed annotation a chart needs.

### Replacing a chart resource

Charts ship resources kix wants to own per-cluster (commonly an Ingress: cluster decides Ingress vs HTTPRoute vs nothing). `resources.replaceResource kind name newResource` returns a new collection with the swap applied across every lookup, `mkParts`, DAG op.

```nix
ingress = scope.expose.mk { ... };
patched = resources.replaceResource "Ingress" "myapp" ingress;
# then: patched.mkParts { root = ...; }
```

- Edges INTO the original (chart resources that depended on it) are dropped; replacement must declare its own `requires` if it needs chart resources first. For leaf resources (Ingress, ServiceMonitor) usually nothing.
- Edges OUT of the original survive through `mkParts`'s root requires.
- Throws if no resource matches `kind`/`name`.

To mutate a raw resource (not swap for a kix-native one), use `patchResources` instead (runs on raw JSON before wrapping; the HomeAssistant Tier 1 example patches a Service `clusterIP` this way).

### Auto-derived CRD builders

Per CustomResourceDefinition a chart ships, collection exposes `crds.<Kind> = { cr, mkCR }` (also `out.crds.<Kind>` via `mkParts`).
- `cr args` enriches a CR spec with right `apiVersion`/`kind`, adds the CRD plus every chart workload to `requires`.
- `mkCR consumerScope args` builds it cluster- or namespaced depending on CRD scope.
- Consumer CR waits for CRD Establishment and every controller workload's readiness (any could be the admission/conversion webhook).
- Only works for CRDs in `helm template --include-crds` output.

Charts installing CRDs at runtime (not `--include-crds`) need explicit CRD refs. Cilium: CRDs installed by agent at startup (`INSTALL_CRDS`), so package hand-builds `scope.mkCRDRef` markers wired to `installedBy = resources.workloads`, gating CNP/CCNP application on the whole stack Ready. See `kix/packages/cilium/default.nix`.

### Tier 3: native package borrowing chart CRDs

kix authors workloads itself (full control over Deployments, RBAC, config) but ships upstream chart CRDs verbatim. `scope.helm.importChartCrds { chart; scope; releaseName ? "release"; values ? {}; }` renders only `kind: CustomResourceDefinition` docs, returns a list of wrapped cluster-scoped resources. Add to root's `extraParts` or `requires`. (To fully hand-author CRDs instead, use `scope.crd.fromKind` pipe builders; see `kix/packages/cert-manager/crds.nix` and 03-advanced.md#secrets-crds-rbac.)

### Real example: cilium (Tier 2 end to end)

`kix/packages/cilium/default.nix` - wraps the upstream chart: explicit DaemonSet root via `resources.get`, hand-built `scope.mkCRDRef` markers (chart installs CRDs at runtime via `INSTALL_CRDS`) threaded through `extraParts` (deploy) and `out` (consumer reach, shallow-merged over auto-derived `byKind`), netpol builder API on `out`. Read it for the full runtime-CRD Tier-2 shape.

### Gotchas

- **IFD cost.** `importChart` runs `helm template` at eval time; any `values` change re-renders.
- **`values` only, no CLI flags.** Anything that would be a `helm` CLI flag must be a value (or `extraFlags`).
- Real consequences detailed in their sections above: autoRoot is a heuristic; Service promotion skips silently on 0 or >1 matches; stripping is lossy; `replaceResource` drops inbound edges; `extraEdges` endpoints are validated (rename on chart upgrade breaks the build).

## Scorecard & rules

Declarative policy engine run at build time; scores resources packages emit. Engine: `kix/lib/scorecard.nix`. Rules: `kix/lib/rules/`. Config surface: `kix/lib/modules.nix`.

### Model

- Policy-as-code, evaluated during cluster compile. Rules inspect manifests, emit *findings*; each has a `severity`.
- `info` / `warning` -> kix trace warnings (printed, non-blocking).
- `error` -> assertions (`assertion = false`), **fail the build**.
- Conversion: `scorecard.scorecardToWarnings` splits findings by severity; non-errors -> `"[scorecard:<rule>] <loc>: <message>"`, errors -> failing assertions. Shares the normal build diagnostics channel (see 01-fundamentals.md#package-anatomy).
- **Off by default.** Runs only when a cluster opts in with `scorecard.enable = true` AND a non-empty `rules` set. Guard: `scorecardEnabled = enable && rules != {}` (`kix/lib/eval/instance.nix`).

```nix
scorecard.enable = true;
```

### Four levels

Rule declares a `level` -> decides `check` ctx and run frequency. Narrowest to widest:

| level | runs per | `check` ctx keys | wired in |
|-------|----------|------------------|----------|
| `manifest` | each emitted resource | `resource`, `instanceName`, `namespaceName` | `eval/instance.nix` |
| `package` | each package instance | `resources`, `parts`, `config`, `meta`, `instanceName`, `namespaceName` | `eval/instance.nix` |
| `namespace` | each namespace | `instances`, `resources`, `namespaceName` | `eval/cluster.nix` |
| `cluster` | once, whole cluster | `allInstances`, `allResources`, `clusterConfig` | `eval/cluster.nix` |

- `check` returns a **list** of `{ message = "..."; }`; empty list = passed. Each entry -> one finding at the resolved severity.
- Evaluators: `evaluateManifestRules`, `evaluatePackageRules`, `evaluateNamespaceRules`, `evaluateClusterRules` (`kix/lib/scorecard.nix`).
- `appliesTo` (optional predicate over same ctx): false -> rule skipped for that target. Default true.

```nix
appliesTo = { resource, ... }: isWorkload resource;
```

### Rule anatomy

From `kix/lib/rules/security.nix`:

```nix
nonRoot = {
  description = "All containers must run as non-root";
  level = "manifest";
  severity = "error";
  tags = [ "security" "cis-benchmark" ];
  appliesTo = { resource, ... }: isWorkload resource;
  check =
    { resource, ... }:
    let
      containers = getContainers resource;
      failing = builtins.filter (c: !(c.securityContext.runAsNonRoot or false)) containers;
    in
    map (c: { message = "container '${c.name or "unnamed"}' does not set runAsNonRoot"; }) failing;
};
```

Fields:

- `description` - human text, documents intent (not in output).
- `level` - one of the four. Unrecognized/missing level silently filtered out (`filter (r: (r.rule.level or "") == "manifest")`).
- `severity` - rule's own default: `info` / `warning` / `error`.
- `tags` - free-form labels copied onto findings.
- `appliesTo` (optional) - predicate; default true.
- `check` - returns list of `{ message; }`.

Rules nested as `{ category.ruleName = rule; }`; `flattenRules` -> dotted names. `security.nonRoot` is the canonical name used in override config and warning prefix.

### Built-in rule library

`kix/lib/rules/default.nix`. Import all as `kix.rules`, or by category (`kix.rules.security`, `kix.rules.architecture`, ...). Per-rule names and severities live in the source and drift - read `kix/lib/rules/<category>.nix` for the current set.

- **security** (`security.nix`) - non-root, no privileged, no host namespaces, no `:latest`, read-only rootfs, namespace has a NetworkPolicy. non-root / no-privileged / no-host-namespaces default to `error` (block build); rest `warning`.
- **reliability** (`reliability.nix`) - requests+limits bounded, probes present, PDB for multi-replica, graceful shutdown. All `warning`/`info`.
- **governance** (`governance.nix`) - `meta.owner`, `meta.description`, standard labels.
- **architecture** (`architecture.nix`) - DI-hygiene; encodes the store-path discipline, referenced by netpol and overrides:

| rule | level | checks |
|------|-------|--------|
| `capabilityOwnership` | package | capability-owned resource requested via DI, not hand-rolled. Ownership model: 03-advanced.md#networking--package-meta. Fingerprint-driven; adding a fingerprint is data-only (append `{ capability; detect; describe; rationale; suggest; }` to `fingerprints` in `architecture.nix`). |
| `selectorCoherence` | manifest | `Service` selector value carries store-path context (from `kix.service.fromWorkload`), not a literal `{ app = "..."; }`. |
| `fqdnWithoutContext` | manifest | `*.svc` FQDN string carries store-path context (from a Service/ServiceRef `out.*`), not a literal. |

`selectorCoherence` / `fqdnWithoutContext` trust a value iff `builtins.getContext` is non-empty; context-free literals are the smell. Canonical default-on set in `ludo/base.nix`. `rawSelector` (escape hatch, see 02-authoring.md#workloads) intentionally trips `selectorCoherence`.

### Enabling & configuring

`scorecard` submodule (`kix/lib/modules.nix`):

```nix
scorecard = {
  enable = true;
  rules = { ... };         # nested { category.ruleName = rule; }
  ruleDefaults = { ... };  # cluster-wide fallbacks
  ruleOverrides = { ... }; # per-rule / per-owner / per-namespace tuning
};
```

Minimal opt-in (`ludo/base.nix`), architecture category only:

```nix
scorecard = {
  enable = true;
  rules = {
    architecture = kix.rules.architecture;
  };
};
```

Everything: `rules = kix.rules;`. `rules` is just an attrset -> mix categories or hand-write rules under any category name.

### Severity precedence (chain, not flat config)

Resolved per (rule, namespace, owner) by `resolveEffectiveSeverity` (`kix/lib/scorecard.nix`). Most specific wins; first matching tier applies:

1. **Per-rule disable** - `ruleOverrides.byRule.<rule>.enabled = false` -> rule skipped (resolves `null`, no finding).
2. **Per-rule severity** - `ruleOverrides.byRule.<rule>.severity`.
3. **Per-owner severity** - `ruleOverrides.byOwner.<ownerPattern>.<rulePattern>.severity`.
4. **Per-namespace severity** - `ruleOverrides.byNamespace.<nsPattern>.<rulePattern>.severity`.
5. **Rule's own `severity`** field.
6. **Cluster-wide** `ruleDefaults.severity`, else hardcoded fallback `"warning"`.

Order is `byRule -> byOwner -> byNamespace -> rule -> ruleDefaults`. `byRule` most specific, `byNamespace` least specific of the three override scopes. NOT alphabetical, NOT "most recently written wins".

Pattern matching (`matchPattern`): `"*"` matches anything; trailing `*` = prefix match (`"kube-*"`); else exact. Both the namespace/owner key AND the inner rule key are patterns, so `"security.*"` matches every security rule. `owner` = package's `meta.owner` (`eval/instance.nix`); `null` owner -> `byOwner` never matches.

Override examples:

```nix
# disable a single rule cluster-wide
scorecard.ruleOverrides.byRule."security.readOnlyRootfs".enabled = false;

# lift a rule to build-blocking
scorecard.ruleOverrides.byRule."reliability.boundedResources".severity = "error";

# relax a category for a system namespace
scorecard.ruleOverrides.byNamespace."kube-system"."reliability.*".severity = "info";

# stricter bar for one team by owner
scorecard.ruleOverrides.byOwner."platform-team"."security.*".severity = "error";

# baseline for rules that declare no severity
scorecard.ruleDefaults.severity = "warning";
```

### How findings surface

Package-instance findings merged into instance diagnostics (`eval/instance.nix`): non-error -> `warnings`, error -> `assertions`.

```
[scorecard:security.nonRoot] myns/myapp/myapp-web: container 'web' does not set runAsNonRoot
```

- Location is `namespace/instance/resource`, `null` segments dropped.
- Error findings stop the build with the same message as an assertion.
- Author loop: build, read `[scorecard:...]` lines, fix the manifest or (legit exception) silence via `ruleOverrides`.

### Legitimately silencing findings

Prefer fixing the manifest. True exception -> silence at the *narrowest* scope via the precedence chain:

- One known-good resource type in one namespace -> `byNamespace."<ns>"."<rule>".severity = "info"`.
- Rule doesn't apply to whole-cluster posture -> `byRule."<rule>".enabled = false`.
- Subsystem owned by a team with different constraints -> `byOwner."<owner>"."<rule>".severity`.

Don't disable unless downgrading to `info` is insufficient: `info` still prints (breadcrumb), `enabled = false` makes the rule vanish. No per-resource inline annotation to suppress a single finding; suppression is always config-driven through the chain.

### Gotchas

- **Opt-in and rules-gated.** `enable = true` with `rules = {}` does nothing; both needed.
- **Unknown `level` silently dropped.** Typo `level = "manifests"` -> never runs, no error.
- **`error` findings block the build.** Fix the workload or override severity before enabling an error-defaulting category broadly.
- **Precedence is first-match, not merge.** Only the first matching tier in `byRule -> byOwner -> byNamespace -> rule -> ruleDefaults` applies; tiers don't combine.
- **Glob matching takes the first match** (`builtins.head`), not the most specific. Avoid overlapping patterns at one tier.
- **`capabilityOwnership` checks emitted resources, not the resolved dep graph.** The resource must carry `kix.run/capability` (owner's builder) or the package must list the capability in `meta.provides`.

## Overrides

Every lever for changing package behavior from the cluster definition, without editing the package's `default.nix`.

Sources: instance submodule + `globalPartsOverlays` in `kix/lib/modules.nix`; `mkLocked` + dep `config` injection in `kix/lib/eval/resolve.nix`; `kix.mkEnv` in `kix/lib/env.nix`.

### The instance submodule

`instances.<namespace>.<instanceName>` fields (`kix/lib/modules.nix`):

```nix
instances.media.immich = {
  package = packages.immich;          # required: the package function/attrset
  aliases = [ "photos" ];             # DI resolution keys (replaces meta.defaultAliases)
  config = { /* deep-merged options */ };
  deps = { storageClasses = ref.kube-system.platform-storage; };  # explicit DI overrides
  partsOverlays = [ /* post-build transforms */ ];
  labelStyle = "kix";                 # or "helm"
  selectorLabels = null;              # or an explicit { } to override auto labels
  optional = false;                   # dormant-until-depended-upon
  extraDeps = [ ];                    # extra ordering edges on the PackageInstance marker
  version = null;                     # overrides packageMeta.version on the marker
};
```

| Field | Effect | Merge across modules |
|-------|--------|----------------------|
| `package` | Required. Package function/attrset. | - |
| `aliases` | DI resolution keys. Non-empty **replaces** `meta.defaultAliases`; `[ ]` keeps defaults. | - |
| `config` | Deep-merge option overrides (`deferredModule`). | merges (use `mkDefault`/`mkForce`) |
| `deps` | Explicit DI overrides. | collision = hard error |
| `partsOverlays` | Post-build resource transforms. | list concatenates |
| `labelStyle` | `"kix"` (`app.kubernetes.io/*`) or `"helm"` (`app`/`release`). | - |
| `selectorLabels` | `null`, or explicit map replacing auto selector labels. | - |
| `optional` | `true` = deploy only if a non-optional instance depends on it. | - |
| `extraDeps` | Extra ordering edges on PackageInstance marker. | - |
| `version` | Overrides `packageMeta.version` on the marker. | - |

### config: deep-merge option overrides

Primary lever. Fed through `evaluateInstanceConfig` (`kix/lib/eval/resolve.nix`): `lib.evalModules` over `{ options = packageOptions; }` + cluster `global` + dep injections + instance config, then `lib.recursiveUpdate optionDefaults evaluated` (evaluated wins, defaults fill gaps). Setting one nested field does not drop sibling defaults.

```nix
instances.immich.storage.config.size = lib.mkForce "200Gi";
instances.immich.valkey.config.auth = {
  secretSource = null;
  password = "dev-password";
};
```

- `config` is a `deferredModule`; use `lib.mkDefault`/`lib.mkForce` for priority across modules (see 01-fundamentals.md#options--config).

### aliases: rename the DI key

Resolution index (`buildResolutionIndex`, `kix/lib/eval/resolve.nix`) unions `[ instName ] ++ aliases`. Non-empty `aliases` **replaces** `meta.defaultAliases`.

```nix
instances.kube-system.platform-storage = {
  package = kix.mkImport { out = { storageClassName = "kind-fast"; }; };
  aliases = [ "storageClasses" ];   # consumers requesting `storageClasses` resolve here
};
```

- Slots a package into a DI role it does not name itself (import standing in for `dns`, `storageClasses`, `database`).
- To disambiguate multiple instances of a role, prefer `deps.<argName> = ref.<ns>.<inst>` at the consumer (see 02-authoring.md#dependency-injection).

### labelStyle: kix vs helm labels

Passed to `mkScope` as `labelStyle`. Controls selector/instance label keys.

- `"kix"`: `app.kubernetes.io/*` keys.
- `"helm"`: `app`/`release` keys (both = instance name). Use when adopting resources a Helm release already owns, so `kubectl apply` matches selectors instead of duplicating.

```nix
# cluster-wide helper, from nw1-luca/cluster.nix:
helmInstance = cfg: { labelStyle = "helm"; } // cfg;
```

- `"helm"` covers selector/instance labels only, not Helm ownership annotations (`meta.helm.sh/release-*`) - see `ROADMAP.md`.

### selectorLabels: pin immutable selectors

Default `null`; passed to `mkScope` as `selectorLabelsOverride`. Replaces auto selector labels entirely. Use when a live resource has an immutable selector (StatefulSet `spec.selector` is immutable post-creation) matching neither kix nor Helm convention. Copy live selector verbatim so apply is a no-op.

```nix
instances.data.postgres.selectorLabels = {
  "app.kubernetes.io/name" = "postgres";
  "statefulset.kubernetes.io/pod-name" = "postgres-0";
};
```

### optional: dormant instances

`optional = true`: included in DI resolution, deployed only if a non-optional instance transitively depends on it. Activated optionals get annotation `kix.run/optional-activated = "true"` (`kix/lib/eval/instance.nix`).

```nix
# platform storage import that ships only if a PVC consumes it.
instances.kube-system.platform-storage = lib.mkForce {
  package = kix.mkImport { out = { storageClassName = "kind-fast"; }; };
  aliases = [ "storageClasses" ];
  optional = true;
};
```

### partsOverlays: post-build resource transforms

Signature `scope: self: base: attrset`. Runs after the package's `build` produces parts. Bound to scope then folded into the fixpoint (`kix/lib/eval/instance.nix`):

```nix
allOverlays  = globalPartsOverlays ++ (instCfg.partsOverlays or [ ]);
parts = lib.fix (self:
  let merged = /* build output */; in
  builtins.foldl' (acc: overlay: acc // (overlay self acc)) merged boundOverlays);
```

Each overlay gets `scope` (already applied), fixpoint `self`, `base` (accumulated parts); returns attrset `//`-merged onto `base`. Three ops:

- **Mutate**: return key with modified value, e.g. `root = base.root // { out = (base.root.out or {}) // { ... }; };`.
- **Add**: return a new key not in `base`.
- **Remove**: return key set to `null`. Parts collector filters to `(v._type or "") == "k8s-resource"`, so `null` drops out. `root` must stay a resource.

Example, exposing CRD builders on a Helm package's `out` (`clusters/test-monitoring-helm.nix`):

```nix
partsOverlays = [
  (scope: self: base:
    let smRef = scope.mkCRDRef {
          group = "monitoring.coreos.com";
          kind = "ServiceMonitor";
          plural = "servicemonitors";
        };
    in {
      root = base.root // {
        out = (base.root.out or { }) // {
          mkServiceMonitor = smRef.out.mkCR;
        };
      };
    })
];
```

- Runs inside fixpoint with `self`: can reference other overlaid parts.
- Gets `scope`: can mint resources with `scope.mkResource`/`scope.mkCRDRef` (see 02-authoring.md#resources-and-the-out-surface, 03-advanced.md#secrets-crds-rbac).

### globalPartsOverlays: transform every instance

Top-level cluster option (`kix/lib/modules.nix`). Same `scope: self: base: attrset` signature. Applied to **every** instance, ordered **before** each instance's own `partsOverlays`. Overlay decides per-instance whether to act by inspecting `base` (and `scope` for instance/namespace name); no-op = return `{ }`.

```nix
globalPartsOverlays = [
  (scope: self: base:
    if base ? deployment
    then { deployment = base.deployment // { /* ... */ }; }
    else { })
];
```

### mkLocked: freeze a field against dep injection

`kix.mkLocked value` wraps as `{ _type = "locked"; value; }` (`kix/lib/eval/resolve.nix`). Config eval scans for locked **top-level** fields; any dep injection targeting a locked key throws with source attribution:

```
dep config injection blocked by locked fields: 'extensions' (injected by media/immich)
```

Wrapper is unwrapped before `evalModules`, so value applies normally; only blocks injections. Top-level only; nested keys not scanned.

```nix
instances.data.postgres.config.extensions = kix.mkLocked [ "pg_stat_statements" ];
# Now no consumer's deps.postgres.config.extensions can override this.
```

### Dep config injection (what mkLocked guards)

Lever lives in the *package*, not the instance. Package declares `deps.<argName>.config` to forward config into the resolving instance. Value = static attrset or function `consumerConfig: { ... }` receiving the consumer's evaluated config (`kix/packages/stackgres-database/default.nix`):

```nix
deps.postgres.config = consumerConfig: {
  extensions = map (e: if builtins.isString e then { name = e; } else e)
                   consumerConfig.extensions;
};
```

- `buildConfigInjections` inverts into per-target injection lists; `evaluateInstanceConfig` merges at same priority as instance config (lists concatenate, scalars error on conflict).
- Operator overrides by setting the target field explicitly (`lib.mkForce`) or `mkLocked`-ing it. See 02-authoring.md#dependency-injection.

### mkEnv: same instances, many environments

`kix.mkEnv` (`kix/lib/env.nix`) stamps named instance sets into env-prefixed namespaces. Signature `mkEnv envName envConfig instanceSets`:

```nix
instances = kix.mkEnv "dev" {
  config = { /* env-wide values exposed to set functions via env.config */ };
  overrides = {
    app.api.config = { replicas = 1; };   # per-set, per-instance override
  };
} {
  app  = { ref, env }: { api = { package = packages.api; config = { }; }; };
  data = { ref, env }: { postgres = { package = packages.postgres; }; };
};
# => instances."dev-app".api, instances."dev-data".postgres
```

- Each set function called with `{ ref = { }; env = { name; config; }; }`.
- `overrides.<set>.<inst>.config` **shallow-merged** (`//`, not deep) onto `config`; `overrides.<set>.<inst>.parts` replaces `parts` if present.
- Isolation is the namespace prefix and nothing else. A plain auto-instantiated dep follows the requesting namespace, so each env gets its own; role-named deps are keyed by the role and shared, as are packages pinned by `namespace` or `autoNamespace`.
- Call once per env (`"prod"`, `"stage"`, `"demo"`); merge results into `instances`. DI graph independent per env (namespaces differ, resolution is namespace-scoped; see 02-authoring.md#dependency-injection).

Gotcha: override merge is shallow `//`, unlike instance `config` deep-merge. `overrides.app.api.config.resources = { cpu = ...; }` replaces the whole `resources` block, dropping sibling defaults. For deep semantics prefer plain `instances."dev-app"` defs with `lib.mkDefault`, or hand-written prefixed instances (`ludo/variants/cluster-kind-env-stamped.nix`).

### Gotchas

- **`aliases` replaces, not extends, `meta.defaultAliases`.** Re-list everything still needed.
- **mkLocked is top-level only.** Locking `config.foo` does not protect `config.foo.bar` against an injection targeting `foo` wholesale.
- **`deps` collisions error.** Two modules setting `deps.<arg>` for one instance = hard error.
- **Cross-namespace + `meta.scope = "namespace"` throws** (`_crossNsCheck`, `kix/lib/eval/instance.nix`). mkEnv per-env namespaces keep deps in-env.
- **partsOverlay removes a key via `= null`, never via `//`** (the fold can't drop keys); `root` cannot be removed. **`selectorLabels` must match live pods exactly.**

### Decision guide: I want to change X, use lever Y

| Goal | Lever |
|------|-------|
| Change a config value (size, replicas, image, host) | `instances.<ns>.<inst>.config` (with `mkDefault`/`mkForce`) |
| Make a package resolve under a different DI name | `aliases` (or `deps.<arg>` at the consumer) |
| Pin a dep to a specific instance | `deps.<argName> = ref.<ns>.<inst>` |
| Adopt Helm-managed resources on a live cluster | `labelStyle = "helm"` |
| Match an immutable StatefulSet selector | `selectorLabels = { ... }` |
| Pre-stage an instance that ships only when used | `optional = true` |
| Mutate / add / remove a rendered resource on one instance | `partsOverlays` |
| Apply a transform to every instance | `globalPartsOverlays` |
| Forbid a consumer from injecting into a field | `kix.mkLocked value` |
| Forward config from a consumer into its dep | `deps.<arg>.config` (in the package) |
| Run the same stack in dev/stage/prod namespaces | `kix.mkEnv` (or hand-written prefixed instances) |
| Add an extra ordering edge to the deploy graph | `extraDeps` |
| Override the version on the PackageInstance marker | `version` |

## Store-path context and closure internals

How the dependency graph is encoded. You rarely type this; it matters when writing a custom builder, debugging a missing edge, or wrapping opaque manifests. Full pipeline in `kix/lib/architecture.md`.

### Context = the edge carrier

- Every `mkResource` (`kix/lib/k8s.nix`) writes manifest JSON to a content-addressed store path via `builtins.toFile`.
- A resource's `out.*` values are plain strings (`"echo-server"`) with that store path attached as Nix **string context**.
- Embedding one resource's `out.*` in another's manifest makes the consuming JSON inherit the context. `mkResource` reads it back:

```nix
implicitCtxPaths = builtins.filter (p: lib.hasPrefix "/nix/store/" p) (
  builtins.attrNames (builtins.getContext manifestJson)
);
```

- Each referenced store hash is stamped into `kix.run/depends-on`. The CLI walks the store DAG for deploy order and waves (see 01-fundamentals.md#overview--mental-model).

### Helpers (`kix/lib/k8s.nix`)

- `attachCtxDeep ctx value` - recursively attach store-path context to every string leaf (used for `self.x.manifest` field access).
- `extractStoreHash path` - pull the 32-char hash from a store path for the depends-on annotation.

### Names stay real, context rides alongside

- Emitted YAML carries plain K8s names (`metadata.name: echo-server`), never store paths.
- `mkResource` strips context off the store-path filename (filenames cannot carry references) but keeps full context on file content, so every edge survives. Manifests stay `kubectl apply`-able while encoding the graph.
- `_kix.*` reserved keys carry internal metadata (cross-namespace validation, provenance); `stripKixMeta` removes them before serialization, so nothing leaks into YAML.

### Activation roots the closure

- `mkActivation` builds one cluster-scoped `Activation` CR; `spec.instances` references every `PackageInstance` by name, each carrying that PI's context.
- Every PI references its resources, so `nix-store -q --tree` on the Activation derivation yields the entire deploy DAG. The CLI's contract: Activation = single root, whole closure reachable.
- Each `PackageInstance` is a per-package sub-root (stamps `kix.run/root`, inverse-deps, package-level requires).

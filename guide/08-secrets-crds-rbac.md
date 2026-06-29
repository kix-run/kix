# Secrets, CRDs, RBAC

This chapter covers the scope helpers for the three "supporting cast" resource
families a package usually needs alongside its workloads: Secrets (kix-managed
and externally-managed), CustomResourceDefinitions plus the custom resources
that consume them, and RBAC (the pipe DSL plus the paired Role/Binding set
builders). It also covers `scope.mkWebhookService`, which emits an admission
webhook Service and its webhook configurations in one shot. All of these are
methods on the per-instance `scope` object (see 04-resources-and-out.md), and
every one of them tracks dependencies through Nix string context rather than
plain data (see 01-overview.md on the store-path DAG).

## Secrets

### scope.mkSecret

`scope.mkSecret` builds a kix-managed `Secret` resource and enriches its `out`
with a key-aware API. The source code lives in `kix/lib/eval/scope.nix`
(`mkSecret`) and the `out` helpers in `kix/lib/k8s.nix` (`mkSecretHelpers`).

Two ways to provide the contents:

- `stringData` - inline values, for dev / config-derived secrets.
- `source` + `hash` - a SOPS-encrypted file. kix-deploy hydrates the ciphertext
  at deploy time; `hash` is the change-detection signal.

```nix
creds = scope.mkSecret {
  name = "db-credentials";
  keys = [ "username" "password" ];
  stringData = { username = "admin"; password = "s3cret"; };
};
```

`keys` is the declared set of key names. If you omit it, kix derives the keys
from `attrNames stringData`; if you supply neither `keys` nor `stringData` the
builder throws. The declared keys drive build-time validation in the `out`
helpers below. The resource always stamps a `kix.dev/secret-keys` annotation;
`source` adds `kix.dev/sops-source`, `hash` adds `kix.dev/content-hash`, and
`meta.classification` / `meta.rotationPolicy` map to their own annotations.

The `out` API (from `mkSecretHelpers`) gives you four context-carrying
builders, each validating requested keys against the declared `keys` list at
Nix build time:

```nix
# Map env var names to secret keys → list of env entries
env = creds.out.mkEnv { DB_USER = "username"; DB_PASS = "password"; };

# Single key reference → { valueFrom.secretKeyRef = { name; key; }; }
pw = creds.out.keyRef "password";

# Inject every key as env vars → { secretRef = { name; }; }
allEnv = [ creds.out.envFrom ];

# Mount as a volume → { name; secret.secretName; }
vol = creds.out.volume "db-creds-vol";
```

`keyRef "nope"` throws `secret "db-credentials" does not declare key "nope"`
listing the declared keys, so typos fail at evaluation, not at pod startup.
`mkEnv` is just `keyRef` per entry with a `name` added. Each helper attaches the
Secret's store-path context to the returned name string and stamps a
`_kix.namespace` marker, which is how the workload's `checkNamespacedRefs`
validation (see 05-workloads.md) knows the reference is DI-tracked and
same-namespace.

#### The realizedSource gotcha

When you pass `source`, `mkSecret` does NOT reference the file path directly. It
runs `builtins.path { path = source; ... }` to force-copy just that file into
the store (`realizedSource`), then stamps `toString realizedSource` into the
`kix.dev/sops-source` annotation. Without this, a self-relative path like
`./secrets/x.enc.yaml` can dangle (`path '/nix/store/…-source' is not valid`)
under a strict Linux build sandbox or CI, because nothing else forces the flake
source into the store. macOS's loose sandbox happens to tolerate the unrealized
reference, so this bug only bites in CI. Note the ciphertext is deliberately NOT
made a manifest DAG edge - change detection is `hash`'s job, so re-encrypting
the same plaintext does not trigger a redeploy.

### scope.mkSecretRef

For secrets that kix does not create - produced by Vault, External Secrets
Operator, cert-manager, or a bootstrap step - use `scope.mkSecretRef`. It emits
a real resource (a `PackageInstance` import marker, see below) instead of a
`Secret`, but exposes the exact same `out.{name, keyRef, mkEnv, envFrom, volume}`
interface as `mkSecret`. Consumers cannot tell the difference.

```nix
creds = scope.mkSecretRef {
  name = "vault-db-creds";
  keys = [ "username" "password" ];
};
env = creds.out.mkEnv { DB_USER = "username"; };
```

What the marker buys you: the CLI deploy engine
(`cli/kix/src/cluster/readiness.rs`) polls the cluster for the named Secret and,
when `keys` is non-empty, waits until every declared key is present in the
Secret's `data` before any consuming wave runs. Build-time key validation
becomes a deploy-time gate. The marker's store-path context flows onto
`out.name`, so a workload that references the secret picks up a forward-closure
DAG edge to the marker - the workload won't deploy until the external secret
exists. This is what satisfies the workload ref checks that would otherwise
reject an "untracked" reference.

`keys` may be `[ ]` (the Secret is referenced via `envFrom`/`volume` only and
kix doesn't know the key names); the CLI then only checks the Secret exists.
`keyRef` on such a ref still throws a clear "does not declare key" message at the
use site. The marker name is `secret-ref-${instanceName}-${name}` so two
instances in the same namespace can reference the same external secret without
colliding.

Cross-namespace consumption is rejected by default (K8s does not allow it).
If the secret is mirrored by the emberstack reflector controller, pass
`reflect = true`; that stamps `_kix.reflected = true` on the helpers, which
relaxes the same-namespace check in `checkNamespacedRefs`. The producer is still
responsible for putting the reflector annotations on the source Secret.

## The import marker

Both `mkSecretRef` and `mkCRDRef` are built on `mkImportMarker`
(`kix/lib/eval/scope.nix`). It emits a namespaced `PackageInstance` resource
annotated with `kix.dev/mode=import` plus `kix.dev/import-{kind,apiversion,name}`
describing an externally-managed resource. The CLI readiness check parses these
into an `ImportTarget` and gates consuming waves until the described resource
exists (and, for Secrets, until all `expected_keys` are present). The marker
lives in the consumer's namespace and the imported resource is expected in the
same namespace - cross-namespace imports are not supported. Every marker
`requires` the kix `PackageInstance` CRD, plus any `extraRequires` (this is how
`installedBy` works, below).

## CRDs

### scope.mkCRD

`scope.mkCRD` takes a K8s-native CRD spec shape and returns a cluster-scoped
`CustomResourceDefinition` resource whose `out` is extended with CR builders
(`cr`, `mkCR`). You rarely hand-write the spec; you build it with the pipe
transforms in `kix/lib/crd.nix`, exposed as `scope.crd`:

```nix
mkCrdInput = def:
  scope.crd.fromKind def.kind (
    lib.recursiveUpdate { spec.group = sgGroup; } (def.specOverrides or { })
  )
  |> scope.crd.withShortNames def.shortNames
  |> scope.mkCRD;
```

The transforms (all in `crd.nix`) consume and produce the CRD spec attrset, so
they chain with `|>`:

- `fromKind kind extra` - seeds a full spec from a kind. Auto-derives `plural`
  (lowercase + "s"), `singular`, and `listKind` (`<Kind>List`). Defaults to
  `scope = "Namespaced"`, version `v1`, a permissive schema
  (`x-kubernetes-preserve-unknown-fields` on `spec`/`status`), and a `status`
  subresource. The second arg is `recursiveUpdate`-merged, so override any field
  (e.g. `spec.names.plural` for irregular plurals).
- `clusterScoped` - sets `spec.scope = "Cluster"`.
- `withShortNames [ ... ]` / `withCategories [ ... ]` - add to `spec.names`.
- `withVersion v` / `withPrinterColumns cols` - rewrite all versions.
- `withSchema schema` - replace the `spec` property's openAPIV3Schema on every
  version (use a real schema instead of the permissive default).
- `withLabels` / `withAnnotations` - set metadata on the CRD resource itself
  (not the spec).

So a fuller pipeline reads:

```nix
crd.fromKind "SGCluster" { spec.group = "stackgres.io"; }
|> crd.clusterScoped
|> crd.withShortNames [ "sgclu" ]
|> crd.withSchema mySchema
|> scope.mkCRD
```

`mkCRD` derives the CRD name as `${plural}.${group}` and reads `version`,
`kind`, and `scope` out of the spec to wire up the CR builders. The returned
value is the CRD resource with `out = crdResource.out // builders`, where the
builders come from `mkCRDBuilders` in `kix/lib/k8s.nix`.

### Creating custom resources: out.cr, out.mkCR, scope.mkCR

`mkCRDBuilders` returns two builder styles:

- `out.cr args` - a pure transform: stamps `apiVersion = "${group}/${version}"`
  and `kind` onto your resource args and appends the CRD to `requires`. You then
  pass the result to `scope.mkResource` / `scope.mkClusterResource` yourself.
- `out.mkCR consumerScope args` - the full builder, curried on a scope. It runs
  `cr` then auto-routes to `mkResource` or `mkClusterResource` based on the
  CRD's scope. `crd.out.mkCR scope` gives you an `args -> resource` function.

Adding the CRD to each CR's `requires` is how dependency tracking happens for
CRs - the wave graph places the CRD (or import marker) before any CR that uses
it, via the standard forward-closure walker. There is no string context on
`apiVersion`/`kind`.

```nix
# cluster-issuers binds mkCR to its own scope, then builds CRs:
mkIssuerCR = certManager.crds.clusterIssuers.out.mkCR scope;

issuer = mkIssuerCR {
  name = "letsencrypt";
  spec.acme = { server = ...; email = ...; };
};
```

`scope.mkCR crd args` is sugar for `crd.out.mkCR scope args` using the package's
own scope.

### scope.mkCRDRef

When the CRD is installed by something other than kix - an operator's
`INSTALL_CRDS` bootstrap, a Helm chart, or a pre-existing cluster CRD - you
declare a reference instead of the definition. `scope.mkCRDRef` emits a
`PackageInstance` import marker (same machinery as `mkSecretRef`) and attaches
the same `out.{cr, mkCR}` builders. The CLI polls for the named CRD and waits
until it is `Established=True`, which gates the wave containing any CR built
through the ref.

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

`installedBy` gates the marker - accepts a single resource or a list. Every
entry becomes a hard `requires` edge on the marker, so each CR's wave waits on
all of them being Ready, not merely applied. For a Helm-bundled operator where
the chart installs the CRD alongside several workloads (e.g. a DaemonSet plus an
operator Deployment), pass the whole workload list so the CRD waits for every
component that serves its webhooks. `mkCRDBuilders` auto-adds the marker to
every CR's `requires`, so there is no `root.requires` plumbing needed.

## RBAC

`scope.rbac` (defined in `kix/lib/rbac.nix`) is a pipe-friendly DSL for building
`rules` lists, plus `mkClusterRoleSet` / `mkRoleSet` for the paired
Role+Binding boilerplate.

### The rule DSL

The model is: a `Ref` points at a resource type, an `intent` turns a `Ref` (or
list of `Ref`s) into `[Rule]`, and `grant` flattens and merges intent results.

Construct refs with `group apiGroup [ resources ]`. The result is both an
attrset (dot access) and a callable fallback for resources you didn't
pre-list:

```nix
inherit (scope.rbac) grant allow core;
discovery = scope.rbac.group "discovery.k8s.io" [ "endpointslices" ];
# core is the "" group pre-populated with pods, services, secrets, etc.
# core.pods, core.services, discovery.endpointslices ...
# group "x" [] |> (g: g "ondemand") works for unlisted resources.
```

Ref modifiers (chain before an intent):

- `restrictTo [ names ]` - sets `resourceNames`.
- `sub "status"` / `sub "finalizers"` - access a subresource
  (`resource/status`). Use `map (sub "status") refs` for lists.

Intents (each is `Ref | [Ref] -> [Rule]`):

- `watch` (get/list/watch), `reconcile` (get/list/watch + patch/update +
  status patch/update), `own`, `readWrite`, `full`, `emit` (create/patch),
  `finalize`, `watchAndFinalize`.
- `allow [ verbs ]` - explicit verb list.

`grant [ [Rule] [Rule] ... ]` concatenates and merges rules that share
`apiGroups` + `verbs` + `resourceNames`, combining their `resources` lists.

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

### mkClusterRoleSet / mkRoleSet

These take the package `scope` and `{ subjects, labels?, roles }`, and return a
flat attrset `{ <roleName> = <Role>; "<roleName>-binding" = <Binding>; ... }`.
`mkClusterRoleSet` builds `ClusterRole` + `ClusterRoleBinding`;
`mkRoleSet` builds namespaced `Role` + `RoleBinding`. Each `roles` entry is
either a plain rules list or `{ rules, bindingName? }`.

Merge the result onto `self` with `//`, and feed
`builtins.attrValues` into a `requires` list:

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

The binding's `roleRef.name` is taken from `role.out.name` (context-carrying),
so the Binding correctly orders after its Role.

## mkWebhookService

`scope.mkWebhookService` builds an admission-webhook `Service` plus its
`ValidatingWebhookConfiguration` and/or `MutatingWebhookConfiguration` in one
call - the boilerplate that operators (stackgres-operator, cert-manager,
ingress-nginx) used to reinvent. It returns
`{ service, validatingConfiguration?, mutatingConfiguration? }` ready to spread
into `self`.

```nix
webhook = scope.mkWebhookService {
  name = "my-operator-webhook";
  selector = self.operatorDeployment.rawSelector;
  port = 443;            # default
  targetPort = "webhook";  # default container port name
  validating = [{
    name = "validate.example.com";
    path = "/validate";
    rules = [{ apiGroups = [ "example.com" ]; resources = [ "widgets" ]; }];
  }];
};
# self // { inherit (webhook) service validatingConfiguration; }
```

Each hook entry takes `{ name, path, rules, failurePolicy?, sideEffects?,
timeoutSeconds?, admissionReviewVersions?, matchPolicy? }`, where each entry in
`rules` is `{ resources, operations?, apiGroups?, apiVersions?, scope? }`. Per
rule, `operations` defaults to `[ "CREATE" "UPDATE" ]`, `apiGroups`/`apiVersions`
to `[ "*" ]`, and `scope` to `"*"`. Per hook, `admissionReviewVersions` defaults
to `[ "v1" ]`, `sideEffects` to `"None"`, `failurePolicy` to `"Fail"`,
`matchPolicy` to `"Equivalent"`, `timeoutSeconds` to `10`. The Service's `out.name` (with context) feeds each webhook's
`clientConfig.service`, so the ordering edge Service → Config is automatic.
`caBundle` is optional - when `null` (the default), a consumer is expected to
patch it post-deploy (cert-manager CA injector, Helm hook). Use
`self.<workload>.rawSelector` (not `out.selector`) for the `selector` to avoid
hashing the full workload manifest (see 05-workloads.md on `rawSelector`).

## Common mistakes

- Passing a self-relative SOPS `source` and seeing
  `path '/nix/store/…-source' is not valid` only in CI - the realization is
  automatic now, but if you replicate the pattern by hand, remember macOS hides
  the bug.
- Requesting a key that isn't declared in `mkSecret`/`mkSecretRef` `keys` -
  `keyRef`/`mkEnv` throw at eval time. Add the key to `keys` (or `stringData`).
- Consuming a `mkSecretRef` secret from a different namespace - rejected unless
  `reflect = true` and the source actually carries reflector annotations.
- Setting CR `apiVersion`/`kind` by hand instead of via `out.cr` / `out.mkCR` -
  you lose the auto-added `requires` edge to the CRD/ref, so the CR can land in
  a wave before its CRD exists.
- Using `out.selector` for `mkWebhookService`'s `selector` when the workload
  also references one of the resources in `self` - can cycle; prefer
  `rawSelector`.
- Cross-namespace imports (`mkSecretRef`/`mkCRDRef` describing a resource in
  another namespace) are not supported - run an adapter instance in the owning
  namespace and DI the handle instead (see 07-dependency-injection.md).

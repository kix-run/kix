# Workloads

This chapter covers the workload constructors `scope.mkDeployment`, `scope.mkStatefulSet`, `scope.mkDaemonSet`, and `scope.mkJob` exposed on the per-instance scope (defined in `kix/lib/eval/scope.nix`). These wrap a raw K8s workload spec, auto-fill `apiVersion`/`kind`, copy the selector into the pod template labels, run a battery of build-time validators, emit per-workload network policies, and return a resource with the usual `out` surface plus a few workload-only extras. It also covers the `serviceAccount` and `headlessService` shorthands, the `rawSelector` cycle escape hatch, `scope.mkOptional`, and `scope.mkWebhookService`.

## The four constructors

All four share one implementation. `mkDeployment`/`mkStatefulSet`/`mkDaemonSet` are partial applications of an internal `mkWorkload apiVersion kind`, and `mkJob` is a near-clone with Job-specific tweaks:

```nix
mkDeployment  = mkWorkload "apps/v1" "Deployment";
mkStatefulSet = mkWorkload "apps/v1" "StatefulSet";
mkDaemonSet   = mkWorkload "apps/v1" "DaemonSet";
# mkJob is "batch/v1" "Job"
```

You pass an attrset shaped like a real K8s workload manifest, minus `apiVersion` and `kind` (the constructor sets those). Each is pipe-friendly: the idiomatic form builds the attrset and pipes it into the constructor. From `kix/packages/echo-server/default.nix`:

```nix
deployment =
  {
    inherit name;
    spec = {
      replicas = config.replicaCount;
      selector.matchLabels = scope.selectorLabels;
      template.spec = {
        containers = [
          {
            name = "nginx";
            image = "${config.image.repository}:${config.image.tag}";
            ports = [ (kix.port "http" 80) ];
            # ... probes, resources, volumeMounts ...
          }
        ];
        volumes = [
          { name = "config"; configMap.name = self.configmap.out.name; }
        ];
      };
    };
  }
  |> scope.mkDeployment;
```

The return value is a normal kix resource (`out.name`, `out.selector`, `out.fqdn`, etc. - see 04-resources-and-out.md), so it flows straight into `kix.service.fromWorkload` and the rest of the composition helpers (see 06-composition-helpers.md).

## What the constructor does to your spec

Given `attrs`, `mkWorkload` does the following before constructing the resource:

- **Sets `apiVersion` and `kind`.** You never write them.
- **Requires `spec.selector.matchLabels`.** Absence throws `mkWorkload (<kind>): spec.selector.matchLabels is required - use scope.selectorLabels`. Use `scope.selectorLabels` (the instance's canonical pod-selector labels) so the Service and the workload agree.
- **Copies selector into template labels.** If you do *not* set `spec.template.metadata.labels`, the constructor sets the template labels equal to `selector.matchLabels`. This guarantees the controller can find its own pods. If you *do* supply template labels (common for StatefulSets that add a `component` label), the constructor instead validates selector subset (see below) and keeps your labels.
- **Expands the `serviceAccount` and (StatefulSet only) `headlessService` shorthands** (see below).
- **Generates per-workload CiliumNetworkPolicies** and DNS/egress ordering deps via `netpol.buildWorkloadCnps`, attaching them as `requires` on the workload and as `_generatedNetpol` sideband metadata (see 09-networking-and-meta.md). This happens at resource-construction time, before `build` returns.

`mkJob` differs: Jobs usually omit `spec.selector` (the API server generates it), so the selector falls back to `spec.template.metadata.labels`; it does not copy selector into labels, skips the DaemonSet and selector-subset checks, and only emits `selector.matchLabels` if you supplied one.

## Build-time validators

The constructors run a chain of validators with `builtins.seq`, so any failure throws during evaluation (before deploy). Each message is prefixed with `[<instanceName>]`. The checks, and what trips them:

- **`checkSelectorSubset`** (Deployment/StatefulSet/DaemonSet, only when you supplied your own template labels): every `selector.matchLabels` key must be present in `template.metadata.labels` with an equal value. A missing key throws `spec.selector.matchLabels ⊄ spec.template.metadata.labels`; a value mismatch throws a value-mismatch error. This catches a workload that deploys pods it can never manage.
- **`checkNamespacedRefs`**: every reference to a namespaced resource (Secret volume/`secretRef`/`secretKeyRef`, ConfigMap volume/`configMapRef`/`configMapKeyRef`, PVC `claimName`, `imagePullSecrets`, `serviceAccountName`) must (1) carry Nix string context - i.e. come from `resource.out.*` or `kix.untrackedRef`, not a bare string literal - and (2) be same-namespace as the workload. An untracked ref throws `Untracked <kind> reference ...`; a cross-namespace ref throws `Cross-namespace <kind> reference ...`. K8s does not allow cross-namespace mounts/env/SA refs; mirror the resource into the workload's namespace or use a reflector.
- **`checkNamedPorts`**: any named port used by a `livenessProbe`/`readinessProbe`/`startupProbe` (`httpGet`/`tcpSocket`/`grpc` with a string `port`) must be declared as a named `containerPort` on the *same* container. Integer ports pass through unchecked. Suggests `ports = [ (kix.port "name" N) ]`.
- **`checkContainerResources`**: per container, `resources.limits.{cpu,memory}` must be `>=` the matching `requests`. Quantities are parsed (`100m`, `1`, `128Mi`, `1Gi`, decimals); unparseable values are silently skipped. K8s rejects `limits < requests` at admission.
- **`checkDuplicateNames`**: container names (incl. initContainers) unique within the pod; volume names unique within the pod; env var names unique within each container; named ports unique within each container. Duplicate volume names are a common symptom of two auto-derived mounts from same-named resources.
- **`checkFieldRefs`**: every `env[].valueFrom.fieldRef.fieldPath` must be a supported downward-API path (`metadata.name`, `metadata.namespace`, `metadata.uid`, `metadata.labels`, `metadata.annotations`, `spec.nodeName`, `spec.serviceAccountName`, `status.hostIP`, `status.podIP`, `status.podIPs`, plus `metadata.labels['key']` / `metadata.annotations['key']`). Unsupported paths fail pod creation cryptically, so this surfaces it early.
- **`checkPrivileged`** (capability gate): if any container sets `securityContext.privileged = true`, or the pod uses `hostNetwork`/`hostPID`/a `hostPath` volume, and `cluster.capabilities.privilegedContainers` is `false`, it throws. The message names the specific offending feature.
- **`checkDaemonSet`** (capability gate, DaemonSet only): if `cluster.capabilities.daemonSets` is `false`, throws (e.g. GKE Autopilot).
- **`checkLoadBalancer`** (capability gate, runs inside `scopeMkResource` for any `Service`): a `type=LoadBalancer` Service with `cluster.capabilities.loadBalancer = false` throws.

`mkJob` runs only `checkPrivileged`, `checkNamespacedRefs`, `checkContainerResources`, `checkDuplicateNames`, and `checkFieldRefs`. It skips `checkDaemonSet`, `checkSelectorSubset`, and `checkNamedPorts`.

Capability checks are skipped entirely when `capabilities == {}` (e.g. standalone scope in tests). A `true` or absent capability passes.

## The `serviceAccount` shorthand

Instead of writing `serviceAccountName = self.serviceAccount.out.name` you may set `serviceAccount = self.serviceAccount` directly on `spec.template.spec`. `_expandServiceAccount` rewrites it to `serviceAccountName = sa.out.name` and stamps `_kix.serviceAccountNamespace` so `checkNamespacedRefs` can enforce the same-namespace rule. The `serviceAccount` key is removed from the final spec. Both forms work (valkey uses the explicit `serviceAccountName = self.serviceAccount.out.name`); the shorthand is preferred because it also enables cross-namespace validation. Setting `serviceAccount = null` just drops the field.

## The `headlessService` shorthand (StatefulSet)

A StatefulSet needs `spec.serviceName` pointing at its headless Service. Rather than wiring it by hand you can set `headlessService = self.headlessService` on the spec; `_expandHeadlessService` validates the value is a `Service` resource in the same namespace and sets `spec.serviceName = svc.name`.

Note it uses `svc.name` (plain string), **not** `svc.out.name`. This is deliberate and load-bearing:

> `spec.serviceName` is a plain K8s name match, not a dependency. Using `.out.name` would create a store-path DAG edge to the Service; if the Service also `requires` the StatefulSet (a common back-reference), that closes an evaluation cycle and Nix recurses infinitely.

The valkey package writes this out explicitly for the same reason:

```nix
serviceName = self.headlessService.name;   # .name, NOT .out.name
```

So: use the `headlessService` shorthand, or set `serviceName = self.headlessService.name` by hand - never `.out.name` there.

## `rawSelector`: the cycle escape hatch

Every workload resource is returned with an extra `rawSelector` attribute equal to the `selector.matchLabels` you passed in. It is a cheap accessor for the pod selector that does **not** force `out` (and thus does not hash the full manifest).

Use it from a sibling resource in the same `self` fixpoint when reading `out.selector` would cycle. The classic case (from `kix/packages/ingress-nginx/default.nix`): the Service's selector comes from the Deployment, but the Deployment also `requires` the Service (so the controller finds its `--publish-service`). Reading `self.deployment.out.selector` would force the Deployment manifest, which depends on the Service, which depends back on the Deployment:

```nix
# Service spec
selector = self.deployment.rawSelector;   # not .out.selector -> no cycle
```

The default and preferred surface is still `out.selector` (it carries store-path context that `kix.service.fromWorkload` consumes for ordering). Reach for `rawSelector` only to break a real cycle. Because a `rawSelector` is a plain attrset with no store-path context, the consuming Service trips the `selectorCoherence` scorecard rule (manifest level, severity `warning`, defined in `kix/lib/rules/architecture.nix`), which fires on any Service whose selector has no context on any value. This is the intended warning surface: `rawSelector` should only appear as an explicit cycle workaround. Keep the workload and Service coupled through `rawSelector` (derived from the actual spec) rather than a hand-rolled label literal (see 11-scorecard.md).

## `scope.mkOptional`

`mkOptional cond builder` gates a resource on a condition, returning `null` when `cond` is false. `null` resources are dropped by `collectTypedAttrs` and tolerated by `root.requires`, so an optional resource simply disappears when disabled:

```nix
nodeAgent = scope.mkOptional config.nodeAgent.enabled (_: scope.mkDaemonSet { ... });
```

`builder` may be a thunk (function of one ignored arg) or a plain value. Prefer the thunk form: when `cond` is false the builder is never evaluated, so its side effects (context stamping, CNP generation) stay dormant.

## `scope.mkWebhookService`

For operators that serve admission webhooks, `mkWebhookService` builds a Service plus its `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration` in one call, replacing per-package webhook boilerplate. It takes `name`, `selector` (usually `self.operatorDeployment.rawSelector`), `port` (default 443), `targetPort` (default `"webhook"`), an optional `caBundle`, and `validating` / `mutating` hook lists. It returns `{ service, validatingConfiguration?, mutatingConfiguration? }` ready to spread into `self`; the webhook configs carry the Service's `out.name` context so the Service -> Config ordering edge is automatic. When `caBundle` is null the configs expect a post-deploy injector (cert-manager, helm hook) to patch it in.

## Gotchas

- **`serviceName` / `spec.serviceName` must use `.name`, not `.out.name`.** This is the single sharpest edge: `.out.name` creates a DAG edge and, with a back-referencing Service, infinite recursion. The `headlessService` shorthand does this correctly for you.
- **Selector mismatch throws, it does not warn.** If you supply your own `template.metadata.labels`, every selector key must be present with an equal value. When in doubt, omit template labels and let the constructor copy the selector.
- **`spec.selector.matchLabels` is mandatory** for Deployment/StatefulSet/DaemonSet. Jobs may omit it (then template labels are required instead).
- **Bare-string refs throw.** A Secret/ConfigMap/PVC/SA name that is a plain string literal (no Nix context) fails `checkNamespacedRefs`. Reference `resource.out.name` (or `kix.untrackedRef` for genuinely external resources).
- **Cross-namespace refs throw.** Mounts, env refs, and ServiceAccount references must be same-namespace; mirror or reflect the resource instead.
- **Capability gates depend on the cluster.** `LoadBalancer` Services, DaemonSets, and privileged/`hostNetwork`/`hostPath`/`hostPID` pods throw when the corresponding `cluster.capabilities.*` flag is `false`. They pass silently when capabilities are unset (e.g. tests).
- **Per-workload CNPs are emitted by the constructor**, not by your `build`. If network policy is enabled, the workload gains `requires` edges on its generated CNPs and DNS/egress deps automatically (see 09-networking-and-meta.md).

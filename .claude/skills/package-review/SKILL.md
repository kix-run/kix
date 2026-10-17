---
name: package-review
description: Review a Kix package against the Kix principles and the package conventions. Use this skill when reviewing a new or changed package under kix/packages, a contributed package, a package deletion, or your own package before opening a pull request. It gives a short set of principles, a long checklist of known mistakes with detection hints, and a token-efficient way to run the checks and report only the failures.
---

# Package review

This skill is for two readers: a package author checking their own work before
opening a pull request, and an agent reviewing a contributed package. The top
section says what a good package is. The checklist says how to find the ways a
package usually falls short. Cite principles as `P<n>` (`PRINCIPLES.md`).
An author starting a package uses the `package-authoring` skill first
(`.claude/skills/package-authoring/SKILL.md`): the decision order, upstream
research, and verification steps live there, not here.

Every helper named here exists in `kix/lib` (`vocab/compose.nix`,
`vocab/default.nix`, `scope/builders.nix`, `meta.nix`). When a name does not
resolve, search for the behaviour, then fix this file in the same change
(`CLAUDE.md` makes keeping it current part of changing the conventions).

## What a good package is

1. **Everything another package needs flows through DI and `out`.** Names,
   FQDNs, ports, selectors, Secret names, and URLs come from `dep.out.*` or
   `self.<part>.out.*`, never from a literal or `"${self.x}"` (P1, P12).
2. **The package says what it needs and lets the cluster choose who provides
   it.** Depend on the narrowest contract (`database`, not the whole Postgres
   server; `storage`, not a PVC you build) (P10, P13).
3. **Mistakes fail at evaluation with a message that names the instance, the
   constraint, and the fix.** A footgun documented in a comment is a bug
   (P4, P5, P6).
4. **Options are typed, and a partial override keeps the other defaults.**
   No `types.anything` that the build reads; no placeholder defaults for
   inputs only the user can know (P5).
5. **The package is a superset of Kubernetes.** Accept real Kubernetes and
   upstream shapes, do not rename fields one to one, and keep an escape hatch
   for what is not modelled (P7, P8).
6. **Defaults are correct and safe for a stranger on a fresh cluster.**
   No site's values, no dangerous upstream toggles on by default, nothing
   that only works on the author's cluster.
7. **Replica counts come from the cluster's availability level.** The
   package maps the level; the compiler derives spread and disruption
   budgets. Packages write no spread or anti-affinity.
8. **Network policy comes from the graph.** A package declares intents only
   for edges the graph cannot see, as narrow as possible, and never writes
   an allow-all policy (P1).
9. **Operators expose their kinds.** Vendored CRDs or `mkCRDRef` markers with
   the real served version and readiness, handles on `out.crds.<Kind>`, and
   typed builders where they add behaviour; consumers never write a raw
   `apiVersion` (P4, P7).
10. **Images and versions have one source of truth.** One `release` binding
    feeds `meta.version`, image tags, and vendored CRDs; every default image
    is digest pinned (P3).
11. **Two instances never collide.** Names derive from `scope.instanceName`;
    one-per-cluster packages say so in `meta` and fail clearly when doubled.
12. **No feature without a consumer.** Options, outputs, builders, checks,
    and test clusters each name who reads them; delete the rest (P14).
13. **Every refusal is tested.** Each eval-time refusal has a committed
    negative test beside a positive control, and each optional path is
    evaluated with its toggle on.
14. **Comments describe the current contract in plain, verified sentences.**
    No history, no site names, no claims the code does not enforce
    (`CLAUDE.md` "Code comments", `CLAUDE.prose.md`).
15. **A package with metrics ships alerts for its own failure modes.** It
    alerts when it stops reporting, when data is at risk, on stuck states,
    and on exhaustion, at a severity that says how soon to act. It does not
    restate the cluster's generic rules (BEST-PRACTICES §9.6; research steps
    in "Writing a package's alerts" below).

## Checklist

Each item is a yes/no question where **yes means a problem**, followed by a
detection hint and the usual fix. Item IDs (M1, O3, ...) are for reports.
Items marked *(lib)* are enforced by evaluation; read the code for them only
when a check fails or the path is not evaluated by default.

### Meta (M)

- M1. Is `meta.description` or `meta.owner` (`"platform"` or `"app-team"`) missing? *(lib: `governance.hasDescription`, `hasOwner`)*
- M2. Is `meta.version` a placeholder (`1.0.0`, `bundled`) or different from the image tag? Fix: one `let release = "...";` feeding `meta.version`, `image.tag`, and `crds/sources.txt`. A `v` prefix is fine when upstream tags carry it (package-eval accepts `"v1.19.6"`).
- M3. Is `meta.version` set on a package that deploys no upstream software (it only writes a built-in kind or CRs of another package's operator without pinning an image)? Fix: omit it. A package whose CR pins the image an operator runs (arc-runner-set) does deploy upstream software. The "has no version set" trace from `core/activation.nix` is expected for the others; do not add a placeholder to silence it.
- M4. Is the version string typed in more than one place, including a `v`-prefixed tag beside an unprefixed version? `grep -c '<version>'` in the package. Fix: derive both from `release`.
- M5. Does `meta` restate a default (`lifecycle = "stateless"`, `availability.max` at its default)? Fix: delete.
- M6. Does a package that holds state others depend on (a volume, a database inside another server, a Secret) lack `meta.lifecycle = "stateful"`, or does a package that only consumes state claim it? Fix: match what it provides.
- M7. Does the package fill an infrastructure role (`cni`, `dns`, `storageClasses`, `loadBalancer`, `network-policy-enforcer`, `snapshotController`, `metricsApi`, `registryMirror`) without claiming it in `meta.roles`, or claim a role for a plain service? Check `kix/lib/eval/roles.nix`. Fix: roles for registry slots only; `meta.defaultAliases` for services. A CSI driver does not claim `storageClasses`; the cluster aliases the instance.
- M8. Is `meta.defaultAliases` missing on a package others consume, so an instance with another name is invisible? Fix: add the provider alias (`database`, `valkey`, `storage`, `prometheus`, ...).
- M9. Is the package genuinely one per cluster (its controller watches every namespace with no option to scope it, or two copies would fight over the same objects) without `meta.conflictsWith = [ "cluster:<defaultAlias>" ]`? Fix: add it and say "one per cluster" in the header. The entry must name one of the package's own keys: auto-instantiation reads it to refuse a copy in each of several requesting namespaces (a role claim also counts). Shipping CRDs or other cluster-scoped objects is not by itself a reason: two instances that render the same cluster-scoped object fail evaluation without the entry. When the package also declares `meta.annotationDomains`, the annotation-domain check fires first on a second instance; test each guard with the other removed (T3).
- M10. Is a `meta.unsafe` grant (`raw-pvc`, `host-network`, `privileged`, `run-as-root`, `cluster-admin`) missing a comment saying why, or described as debt? Is a needed grant replaced by a `knownFailures` entry? Fix: grant with reason, or restructure.
- M11. Do pods use hostPath, host network, or uid 0 without `meta.podSecurity` and a reason? hostPath has no `meta.unsafe` grant; `meta.podSecurity` is its only declaration. Fix: declare it.
- M12. Does the operator act on annotations of consumers without `meta.annotationDomains`, listing every subdomain it reads (the index matches exactly)? Fix: declare the domains.
- M13. Does `compatibleWith` give a reason with no `minVersion`/`maxVersion`? It checks nothing. Fix: add bounds or delete.
- M14. Does `meta.k8s.minVersion` miss an API the rendered objects or enabled flags need (CEL `x-kubernetes-validations` in vendored CRDs; csi-provisioner `--enable-capacity` writes storage.k8s.io/v1 CSIStorageCapacity, served from 1.24)? `rg -l x-kubernetes-validations <pkg>/crds`. The upstream README's minimum is not enough when the package turns features on. Fix: raise it, with the reason in one line.
- M15. Does a build function destructure args it never uses (`clusterConfig`, `kix`, `availability`), or does a build-list entry omit `...`? `grep` each arg in the body. Fix: drop unused args. The package's top-level function omits `...` by convention; a build-list entry needs it, and a wrapper build function around `kix.monitor` or `kix.expose` must name `scope` and `lib`, because the lib passes only named arguments.

### Options (O)

- O1. Is any option `types.anything`, `attrsOf anything`, `listOf anything`, or `attrs` that the build reads structurally? Fix: typed `submodule`, `enum`, `nullOr`. Untyped is fine only for a passthrough (`values`, `extraSpec`, or `settings`) or a whole CR `spec` validated against the vendored CRD (field names and JSON types). A build that reads a key inside a passthrough (cilium `values.ipam.mode`, harbor `settings.storage`) validates that key first and refuses other values with the package prefix, not a Nix type error.
- O2. Does an attrset or submodule option carry a non-empty default, so setting one key drops its siblings? *(lib: the option contract, `kix/lib/eval/options.nix`, checked by every-package-evaluates; `kix.checkPackageOptions` for a package outside kixpkgs)* Fix: defaults on each field; `{ }` default plus `lib.mkDefault` in package `config`. A `settings` whose default names the package's own parts may replace as a whole, with the reason in its description. The check reads declarations only, so also read every key the build writes after the user's value is merged (`// { storageClassName = ...; }`).
- O3. Is `resources` a local type? Fix: `kix.options.resources { requests = { cpu; memory; }; }`; a default without a limit gets a one-line upstream reason.
- O4. Is `env` a local type, merged with `// config.env`, or missing from a Kix-native workload? Fix: `kix.options.env` rendered through `kix.mkEnvVars (kix.mergeEnv { who; defaults; owned; } config.env)`. `mergeEnv` has no `option` argument, so a package with several env options (`runners.env`) puts the option path in `who`.
- O5. Is any image a plain string or a local submodule, including sidecars, init containers, and Jobs? Fix: `kix.options.image` per image, `kix.image.ref` to render.
- O6. Does an option rename one upstream key, env var, flag, or Kubernetes field one to one (`logLevel`, `serviceType`, `priorityClassName`, `hpa.targetCPU`)? Check whether it is read anywhere besides being copied. Fix: delete; use `extraArgs`, `env`, `settings`, `extraSpec`, or `values`. Typing a built-in kind's complete field set under the Kubernetes names (priority-class's `value`, `globalDefault`) is not a rename.
- O7. Does a flag get a typed option although the package never reads its value? Fix: default in base args; a typed option only when the package checks the value, derives something from it, or the upstream binary requires the flag with no default (external-dns `--policy`), so leaving it unset must fail at eval.
- O8. Is there an option nothing reads, or read only to feed a label? `grep` each option name. Fix: wire or delete.
- O9. Is a required input given a placeholder default (`admin@example.com`, a bucket, an empty Secret, `"default"` class)? Fix: no default (required option) or a required dep.
- O10. Does a required option, when unset, fail with "used but not defined" naming no instance? Eval with it unset. Fix: add `example` and state bounds in `description`; the lib prefixes the option path.
- O11. Is a closed set typed `str`? Fix: `types.enum`; one enum per context when upstream accepts different subsets.
- O12. Is a `nullOr (enum [ "x" ])` really a boolean, or is `""` a sentinel? Fix: `bool` or `nullOr`. Optional text the apiserver drops when empty is `nullOr nonEmptyStr`, or `kix diff` reports drift.
- O13. Does a type accept values the program or apiserver rejects (`replicas = 0`, a zero interval, a non-IP clusterIP, a zone that already carries the port the renderer appends)? Fix: `ints.positive`, `strMatching`, `addCheck`; a string the renderer decorates refuses the decoration itself.
- O14. Does a type reject values upstream accepts (resources limited to cpu/memory, a regex stricter than upstream, a trimmed enum)? Fix: mirror the upstream parser.
- O15. Are invalid combinations that evaluation can see left to fail at runtime (a feature needing a disabled component, quorum math, RWO with replicas > 1, config entries rendered for a disabled feature that upstream still parses)? Fix: an assertion naming instance, both values, and the fix; checks cover every entry the rendered config contains, not only enabled ones.
- O16. Does an option default read `config` inside `options`? Fix: set it in package `config` with `lib.mkDefault` and give `defaultText`.
- O17. Is an option missing `description`, or `defaultText` when the shipped value comes from `config`? A default the package sets in `config` for a lib option (`ingress.annotations`) is invisible in the option reference, so the header or description states it.
- O18. Is a toggle named `enable` instead of `enabled`? Fix: `enabled` (as `kix.options.monitor` and `kix.options.healthCheck`).
- O19. Is there a `replicaCount` option, or a `replicas` option on a leader-elected controller or singleton? Fix: `replicas` (`ints.positive`, default `kix.availability.pick`) only on load-serving workloads. A load-serving workload may omit the option and take the `pick` default with the instance's `availability` override; say why in the header.
- O20. Are there options for `nodeSelector`, `tolerations`, `affinity`, or `priorityClassName`? Fix: delete; placement goes through `partsOverlays`, priority through an optional `priorityClass ? null` dep read as `priorityClass.out.name`. Exception: a DaemonSet tied to a host resource.
- O21. Is a size a `str` or `int`? Fix: `kix.types.quantity`. A package that owns its claim template may default the size; a generic claim may not. A package that narrows the type (string-only, positive) overrides the description so the error does not contradict itself.
- O22. Does the build parse user strings with a hand-rolled parser or `toInt` that fails with a generic Nix error? Fix: `kix.parseQuantity "<resource>" q` (null when not a quantity), or avoid parsing.
- O23. Is a list option given a rich default, so users must restate it to add one entry? Fix: `attrsOf` keyed by name, rendered to a list.
- O24. Can users override selector labels or spread constraints through options? Fix: delete.
- O25. Does a refusal or a required input apply in modes where the user's own config makes it unnecessary (a pool required under a non-pool IPAM mode)? Fix: condition the check on the effective config.

### Dependencies and `out` (D)

- D1. Are names, FQDNs, ports, or URLs hand-copied, including through a name helper in a shared file where `self.<part>.out.name` is in scope? Fix: `dep.out.fqdn`, `dep.out.port`, `svc.out.url { port; scheme; }`, `self.x.out.name`.
- D2. Does a workload set `serviceAccountName` or `serviceName` from a string or `out.name`? Fix: `serviceAccount = self.sa`, `headlessService = self.svc`. A `fromWorkload` Service of the same StatefulSet works as `headlessService` (valkey), and `fromWorkload` passes `spec.clusterIP`.
- D3. Does a Service selector come from a literal, `scope.selectorLabels`, or `rawSelector` without a cycle to break? (A workload's own `spec.selector.matchLabels = scope.selectorLabels` is correct.) Fix: `kix.service.fromWorkload` or `self.deployment.out.selector`.
- D4. Does a part list `requires` for something it already reaches through string context? The redundant-requires trace warns, but only when the toggle that creates the part is on. Fix: delete it; `requires` only for label-only references.
- D5. Does an app depend on a server (`postgres`) when it needs a per-app facade (`database`)? Fix: depend on the facade and read its `out`.
- D6. Is a dep taken and its `out` never reaching a pod or resource, so no edge forms? Fix: wire the facts or drop the dep.
- D7. Is there an `out` field, build arg, part, or export of the package's own helper files that nothing reads? `git grep` across packages, clusters, and docs. Fix: delete.
- D8. Does a consumer read a dep's parts (`dep.crds.x`, `dep.someRoute`) instead of `dep.out.*`? Fix: read `out`; the provider publishes what consumers need.
- D9. Does a provider publish no `out` for what consumers retype (SA, namespace, class name, URL, operand selectors)? Fix: publish it.
- D10. Is a known-bad combination exported as an output flag instead of failing? Fix: assertion.
- D11. Does a builder or transformer leave callers to remember annotations, finalizers, or `requires`? Fix: the builder takes the resources and stamps them.
- D12. Is a transformer applied after an `mk*` builder, where it does nothing, or does it crash on a DI view? Fix: pipe args into the builder; unwrap DI views.
- D13. Is there an `out.mk<Kind>` that adds nothing over `scope.mkCR dep.out.crds.<Kind>`? When the gating or defaults live on the handle, `out.mk<Kind>` adds nothing; keep only the handle. Fix: delete; builders exist only to gate, default, or refuse.
- D14. Does a build-list entry lack formals (`args: ...`), so DI never injects its deps? Fix: spell out `{ config, gateway ? null, ... }@args`.
- D15. Does a build entry dereference a part that is null when a component is off? Eval with each toggle. Fix: gate with `lib.optionalAttrs`.
- D16. Can an optional dep (`x ? null`) turn a feature with side effects on just because an instance exists, or bind an unintended instance? Fix: an explicit option that requires the dep. An optional role dep that only adds a harmless sidecar while the role resolves (zfs-localpv's csi-snapshotter) is fine. A provider with `meta.scope = "namespace"` is never bound automatically from another namespace, and an explicit `ref` to it across namespaces fails; evaluate the provider in a second namespace to see which applies.
- D17. Does a cluster object referenced by name (PriorityClass, IngressClass, a StatefulSet claim template's class) get no dependency edge? *(lib for StorageClass names on claims and ephemeral volumes)* Fix: take the provider as a dep and read `out.name`, or `kix.untrackedRef { by; }`.
- D18. Is a fact re-derived that a dep, the cluster, or the lib owns (pod CIDR, cluster domain, TLS, public URL, `multiNode` beside `kix.availability.pick`)? Fix: `clusterConfig.clusterDomain`, `dep.out.*`, `self.exposure.url`, the availability level.
- D19. Does a workload read `self.<route>` in its env (recursion)? Fix: read the exposure record `self.exposure`.
- D20. Are a module and a package paired through a shared literal (a claim name, a class name)? Fix: DI.
- D21. Are deps wired with `deps.x = "name"`, or are custom `aliases` used to choose between candidates? Fix: `deps.x = ref.<ns>.<inst>`. An alias that names a contract (a secret dep, `storageClasses` on a CSI driver instance) is the supported way to bind it.
- D22. Does the build fail when a dep resolves to a `kix.mkImport` stand-in (an `out` field assumed present, a numeric `out.port` interpolated without `toString`, a guard on `dep.out ? authSecret` that also refuses the env-var route)? Fix: derive from `out` when present, refuse clearly otherwise.
- D23. Do consumers wait only on `root` when the service is usable only after another resource (a migration Job, a storage location)? Fix: `root.requires` on it.
- D24. Does an `out` value that names a resource lack string context (a literal, `attrNames`)? Check a consumer's `kix.run/depends-on`. Fix: derive it from `self.<part>.out.name`.
- D25. Does an `out` field exist only under a toggle, so a consumer's read fails with a missing attribute? Fix: always publish it (null when off), or state the condition in the header.
- D26. Does a package read a dependency's resource by a fixed name that nothing in the pod spec names (velero's repository Secret)? A dependency view has no `outPath`, so it cannot go in `requires`. Fix: emit a `scope.mkSecretRef` for that name and have the workloads require it.
- D27. Does a public `out.mk*` builder that creates a resource in the caller's scope derive its default name from the provider instead of the caller's `instanceName`? Fix: the caller's name. Errors it raises name the consumer resource from the arguments it receives (P9).
- D28. Does the package read `self.exposure.urlOrNull` although it cannot work without a public URL, or `url` although it can? *(lib: reading `url` without a route or scheme throws)* Fix: `url` when the URL is required; `urlOrNull` with a comment saying what the program does without one.
- D29. Does the package read a cluster field, or ask for a new one, that names one implementation of an environment-provided role (a CNI, a DNS server)? Fix: the flavour declares the implementation as a platform `kix.mkImport` claiming the role, with the facts the package needs in its `out`, and not `optional = true` (an optional dependency never activates an optional import); the package takes it as an optional dependency and refuses, at evaluation, every combination of that dependency and `cluster.roles.<role>.binding` it cannot serve (the `cilium` package and `platform-cilium`).
- D30. Does a package take `deps.database` without holding it to `kix.contracts.postgresDatabase.assertions`, or provide the `database` alias without passing `root.out` through `kix.contracts.postgresDatabase.check`? Detect: `grep -n 'deps.database\|"database"' default.nix`. Fix: the contract on both sides, so a provider swap fails at eval naming the field. A `gateway` provider likewise passes `root.out` through `kix.contracts.gateway.check`; `kix.expose` is the consumer and holds the dependency with `require`. An OTLP endpoint (tempo, otel-collector) passes `root.out` through `kix.contracts.otlpEndpoint.check`, and a package that takes `deps.otlp` holds it with `kix.contracts.otlpEndpoint.assertions`. An OpenID Connect provider (keycloak) passes `root.out` through `kix.contracts.oidcProvider.check`; a package that signs users in takes `oidcProvider ? null` and `oidcClient ? null` read only under `oidc.enabled` (`kix.options.oidc`), holds the first with `kix.contracts.oidcProvider.assertions`, and calls `requireClient` before reading either.
- D31. Does the build make a resource in a `let` binding that it never returns as a part? This usually happens with a `scope.mkSecretRef` or `scope.mkServiceRef` marker that only a pod reads. A build lists only a package's parts as its resources. Such a resource still deploys, because a workload depends on it, but it belongs to no package, so Kix stamps it `_cluster`. When `kix plan` or `kix diff` runs without the deployed build (as CI does), Kix files a `_cluster` marker as a package of its own. The marker then appears as a removed package and an added cluster-level resource on every deploy, although nothing changed. Detect: check that every `scope.mk*` call in the build sits in the returned set; or build the cluster and list the store paths in the activation's closure that no package in `kix-packages.json` lists. Fix: return the resource as a part and read it through `self.<part>`. A null part is skipped, so a part behind a toggle can stay `if … then scope.mkSecretRef { … } else null`.

### Secrets (S)

- S1. Is a credential a `str` option or a CLI arg, so it lands in the Nix store or argv? Does the package take a credential as a `foo` string option with a `fooSource` SOPS path beside it, a pair that cannot name a Secret an operator creates? Fix: one secret dependency; the site picks `packages.secret` (stringData or SOPS) or `packages.secret-ref`. Does the upstream binary take secrets as flags that `extraArgs` would pass? Fix: a secret dep with declared keys; refuse secret flags in `kix.guardArgs` and point at the dep (or the flag's env-var form). Does a `settings` or `datasources` passthrough that lands in a Kix-rendered Secret or ConfigMap accept the program's inline credential keys? Fix: refuse them with the key path and point at the program's file or reference form (alertmanager's `*_file` keys, Grafana's `$VAR` and `$__file{}`).
- S2. Is a credential passed as a Secret name string? Fix: a dep (`secret`/`secret-ref`) read through `out.keyRef`, `out.envFrom`, or `out.volume`.
- S3. Is a secret dep named `credentials` or another generic name? Fix: a purpose name (`valkeyPassword`, `encryptionKey`, `cloudCredentials`); two packages share a name only when they read the same keys.
- S4. Is a dep's key checked in `deps.<x>.assertions` or not at all? Remove a key and eval: `keyRef` throws first. Fix: bind once through `kix.checkSecretKeys { who; arg; dep; keys; }` (or `anyOf`) and read through that binding.
- S5. Does a pod read by name a key of a `keys = [ ]` ref, or does a ref used whole omit keys the deploy should wait for? *(lib: a named read of a key of a ref that lists no keys fails cross-resource check 22)* Fix: declare the keys read.
- S6. Does the package emit a `scope.mkSecret` with inline values for a credential the user should supply? *(lib: a key with no value and no `source` is refused)* Fix: `mkSecretRef` or a required dep.
- S7. Is a Secret built with `scope.mkResource { kind = "Secret"; }`? Fix: `scope.mkSecret`.
- S8. Does a required credential, when absent, still deploy? Fix: refuse at eval.
- S9. Does a package handing consumers a Secret by `secretKeyRef` omit `meta.scope = "namespace"`? Fix: add it; automatic resolution then skips it in other namespaces and an explicit `ref` across namespaces fails. Exempt: a Secret read only by a Job placed in the provider's namespace with `scope.forService` (stackgres-cluster's superuser Secret).
- S10. Does a pod read a Kix-built ConfigMap or Secret through env or `subPath` without `"checksum/<name>" = <res>.out.identityHash`? Detection: a template that calls `.out.mkEnv` or `.out.keyRef` with no `identityHash` annotation. An optional secret dep mounted by `subPath` (a CA bundle) needs it most: a `subPath` mount never updates. Fix: add it. A package that accepts `secret-ref` deps takes an optional `reloader ? null` dep and pipes builder args through `reloader.out.withReloadOn`, or its header says those Secrets do not roll pods.
- S11. Does `envFrom` a whole Secret inject variables that set flags the package owns? Fix: map only the keys read (`secretEnv`), or refuse colliding keys. A Secret key named after a flag's env var is the right way to pass a secret flag to a program that reads every flag from env (kingpin `DefaultEnvars`, viper `AutomaticEnv`).
- S12. Do docs or examples outside `clusters/test-*` fixtures show `stringData`, plaintext placeholders, or `dep.out.keyRef` in a cluster file (which cannot reach `out`)? Fix: SOPS `source` with `keys`, or `secret-ref`; credentials wired by the package. Fixtures with `stringData` carry a "test values only" comment.
- S13. Is RBAC granting cluster-wide `secrets get/list` where a namespaced Role or `resourceNames` would do? A package that parses a namespace-list flag (`--namespaces`, `--watch-namespace`) emits a Role per namespace (`scope.forNamespace`). Fix: narrow it.
- S14. Can an operator copy Kix labels or annotations from a Kix-built CR onto a child it creates? `kix gc` lists objects by the `app.kubernetes.io/managed-by=kix` label and proves ownership by the identity-hash annotation, so a child that gets both is deleted. A copied label alone adds report noise, and a copied annotation alone is never listed (rabbitmq-operator copies annotations and drops `app.kubernetes.io` labels; say so in the header). Fix: keep that kind out of `out.crds`, or pin metadata in a builder, with the reason.
- S15. Does the package render software configuration into a Secret because the program reads it from one (Alertmanager's `alertmanager.yaml`)? Fix, in order of preference and each where the program allows: deliver it through a non-Secret field of the custom resource (`configRawYaml`); accept an optional secret dependency in place of the rendered Secret, refusing the option when both are set; set `meta.classification = "configuration"` on the rendered Secret and refuse the program's inline credential keys (S1). The header says where the configuration comes from.
- S16. Does a `scope.mkSecret` put a non-credential value (a username, a host, a port) beside a credential without `plainKeys`, so `cluster.secrets.accept` without `inline` refuses the whole Secret? Fix: `plainKeys`, or move the value to `out` or a ConfigMap. A `kubernetes.io/basic-auth` username is plain by type.

### CRDs and operators (C)

- C1. Is an upstream kind a `crd.fromKind` stub? Fix: vendor with `scripts/vendor-crds.py` (`crd-vendoring` skill).
- C2. Is a CR built with `mkResource` and a raw `apiVersion`? *(lib: check 21 refuses a CR with no declaration in the closure)* Fix: `scope.mkCR dep.out.crds.<Kind>` or the owner's builder.
- C3. Does the package emit a kind with no CRD, ref, or dep in the closure? *(lib: check 21)*
- C4. Does a `mkCRDRef` state a version the CRD does not serve, or the wrong `crdScope`? *(lib: a missing `version` throws)* Fix: the real served shape.
- C5. Does any kind whose CRD has `status.conditions` lack declared readiness, or use the wrong condition (inverted, not set on this object)? This covers every such kind on `out.crds`, including request-style kinds (CertificateRequest) and kinds no package emits. Detection: `status.properties.conditions.items.properties.type.description` in the vendored JSON lists the condition types; confirm in upstream `conditions.go`. Fix: `readiness.condition = { type; status; }` with a comment for inversions.
- C6. Can a legitimate spec value make readiness hang (a halted or manual mode), or does a failed one-shot CR (Backup, Restore) leave the deploy waiting until timeout? Does a builder make a one-shot CR declarative, so the operator's TTL deletion and the next deploy re-run it? Fix: refuse at eval, default to a mode that settles, or stamp readiness per CR in a builder.
- C7. Are `out.crds` keys anything but the Kubernetes Kind? Fix: `out.crds.<Kind>`; part names stay lowerCamel plural.
- C8. Can any image of the release group (followers included) move away from the vendored CRD or RBAC release silently? Fix: throw when major.minor differs from `release`, checking `image.tag` first, with the cluster author's fix first ("Set image.tag to a v1.21.x tag"). `lib.versions.majorMinor "v0.15.1"` is `"v.0"`, so strip a `v` prefix before comparing, and test the refusal with another minor. A behaviour the package relies on that appeared in a release (a sidecar's `_FILE` support) gets a comment naming that version.
- C9. Does the operator install its own CRDs while the package vendors copies (two writers)? Fix: markers only.
- C10. Is RBAC a long copy, duplicated, or wider than the client calls (`*`, `cluster-admin`, unused verbs)? Fix: `scope.rbac` or the vendored `rbac/` bundle, least privilege; `cluster-admin` only with the grant and its reason.
- C11. Do `extraArgs` flags enable features needing RBAC the package never grants? Fix: refuse the flag at eval.
- C12. Is webhook ownership split between operator and Kix without one owner? Fix: one owner; `ownership.cede` only for fields the operator rewrites.
- C13. Are operand images hardcoded, tag-only, or absent from `out.extraImages`? Fix: `operandImages.<name>` options, each in `out.extraImages`.
- C14. Do operator-spawned pods lack published selectors (`out.operandSelectors.<operand>`) and network policy? Does a consumer copy a provider's operand labels (grep the provider's `factBehavior.podSelector` keys in consumers)? Fix: publish selectors; `kix.operandPolicy { scope; name; spec; }`.
- C15. Does a webhook have no ingress from the apiserver under default deny? Fix: the `from = "apiserver"` ingress source.
- C16. Does a CR cross-reference (a class, a storage location, a Secret) stay a raw string? Fix: take the resource, derive the name, add the edge.
- C17. Does upstream ship a singleton CR while a builder lets two consumers create two? Fix: fixed name so the duplicate check fires.
- C18. Does a chart `values` toggle render a foreign-kind CR (ServiceMonitor)? *(lib: check 21)* Fix: turn it off and use the owner's builder.
- C19. Does a webhook with `failurePolicy: Fail` match objects the program does not serve (all namespaces, other classes)? Fix: `namespaceSelector`, `objectSelector`, `matchConditions`, or a stated known limit.
- C20. Does the package write an object another controller owns (an environment's HelmChartConfig, a kube-system Namespace)? Can a second writer exist outside Kix, and does removing the instance prune an object the environment needs? Fix: document both as known limits; housekeeping when the lib cannot help.
- C21. Can a custom resource built from `out.crds` reach the API server before the operator's admission webhooks serve? A CRD reference is satisfied once the definition is Established, and an operator that installs its own definitions often writes its webhook entries seconds later; a resource created in between misses its defaults. Detection: in the operator log, the definitions are installed before the webhook entries. Fix: a check Job that proves the webhook serves (a server-side dry-run that comes back mutated; for a validating-only webhook with failurePolicy Fail, a server-side dry-run the API server admits; or the operator's own check command) and a gate on every handle that adds it to `requires` (cert-manager `apiCheck`, stackgres-operator `webhookCheck`, external-secrets `webhookCheck`), with an evaluation test that every custom resource's `kix.run/depends-on` names the Job's identity hash (`cert-manager-crd-handles-gated`, `stackgres-operator-crd-handles-gated`, `external-secrets-crd-handles-gated`); without it, a refactor that drops the gate passes every check and the race returns only on a fresh install.
- C22. Does the package describe an operator's shared Service (one that selects every instance in the namespace) with `mkServiceRef` and a narrower per-instance selector, when the CR takes a governing Service by name (`spec.serviceName` on Prometheus and Alertmanager)? Two instances in one namespace then share the Service, scrape each other, and get egress to one instance's pods only. Fix: render a Service per instance over the instance's pods with `kix.run/operand-of`, and name it in the CR.
- C23. Does a program that calls the Kubernetes API, with RBAC not vendored from upstream, lack a rule for a call it makes (a list or watch at startup, a subresource such as `pods/log` or `<kind>/status`, a `deletecollection`)? Detect: list every client call in the pinned source, at startup and in every code path, and match each to a rule; the pull request reports `kubectl auth can-i <verb> <resource> -n <ns> --as system:serviceaccount:<ns>:<sa>` for each on kind, with the program running as that ServiceAccount. Fix: one rule per call, nothing extra (C10). Vendored roles follow the crd-vendoring skill.

### Workloads and availability (W)

- W1. Is `replicas` a literal on a workload with no `none` ceiling, or is `availability` taken and unused? Fix: `kix.availability.pick availability { ... }`. A `none` singleton correctly carries literal `replicas = 1` (W4).
- W2. Does the package write `topologySpreadConstraints` or anti-affinity, or leave an operator's own hard anti-affinity unmapped (a StackGres profile pinning one pod per node)? Fix: delete; operator-placed operands use `kix.availability.spreadConstraints { level; selector; topology; }` and map the operator's profile to the level and to single-node clusters.
- W3. Is a ceiling set package-wide (`meta.availability.max`) when only one workload is limited, or when the limit depends on config? Fix: `availability.max` on that builder, with a reason. The header's limits line names the ceiling and where it is declared.
- W4. Is a singleton capped at `pod` instead of `none`? Fix: `none` with literal `replicas = 1`.
- W5. Under a ceiling, does the workload's `replicas` still come from a `pick` table whose entries above the ceiling differ from the entry at it? Those entries are never used. *(lib: a package ceiling refuses `atLeast` thresholds above it, and more than one replica under `none` throws)* Fix: collapse it.
- W6. Does `pod` map to 1 on a data plane or an edge-triggered workload? Fix: 2, or a comment saying why 1 meets the level. A leader-elected controller has no replicas option and maps `{ none = 1; pod = 1; node = 2; zone = 2; }`.
- W7. Do level-derived replicas exceed what the program supports without leader election or HA config? Fix: singleton, or configure HA.
- W8. Is a single-replica RWO workload on RollingUpdate, or a stateless workload on Recreate without a reason? Fix: Recreate for RWO singletons and for an app that migrates a shared schema on start (old pods fail against it), with a comment; RollingUpdate otherwise.
- W9. Is workload storage a raw PVC or a `storageClass` string? Fix: `storage` dep plus `kix.mount.pvc`.
- W10. Are volumes built without the helpers? Fix: `kix.mount.*` and `kix.withMounts`.
- W11. Do optional components lack securityContext, probes, or resources? Eval with every toggle on. Fix: add them.
- W12. Do security defaults break the stock image (writes to `$HOME`, cwd)? Fix: emptyDir mounts; numeric `runAsUser`. An emptyDir with no stated need is dead surface.
- W13. Does liveness depend on an external dependency? Fix: a dependency-free liveness endpoint.
- W14. Can a slow first start exceed `progressDeadlineSeconds` or the deploy timeout? Fix: derive the deadline from probe settings; document it.
- W15. Does a pod run `hostNetwork` although the program opens no port that needs the host's network (check its listeners and flags)? Fix: drop it and the `host-network` grant. Does a hostNetwork pod that resolves cluster DNS names lack `dnsPolicy = "ClusterFirstWithHostNet"`? A pod that reaches only the apiserver through `KUBERNETES_SERVICE_HOST` needs none.
- W16. Is `enableServiceLinks` left on where injected variables collide with the program's env? Trigger: the instance's Service name upper-cased with `-` to `_` prefixes a variable the program reads (`n8n` gives `N8N_PORT`, `machine-learning` gives `MACHINE_LEARNING_*`). Fix: `false`.
- W17. Does an optional dependency's presence or a toggle change the pod template of a disruptive workload (a container, an env var, a port)? A `prometheus ? null` dep can bind across namespaces (D16). Fix: gate the pod template on the option alone; gate only the Service, monitor, or route on the dep.
- W18. Are dangerous upstream defaults on (snippet annotations, local-storage eviction, audit-only policy claimed as enforcement, telemetry, debug logs)? Fix: safe default, explicit opt-in.
- W19. Does the pod fetch dependencies at runtime with floating versions? Fix: a pinned image.
- W20. Are memory caps left to the OOM killer where the program has its own cap? Fix: derive with `kix.parseQuantity` and a stated headroom.
- W21. Are Job retry or rerun semantics wrong for the task? Does a health check judge the whole history (lifetime errors == 0) instead of what changed since it started, so one past error fails every later deploy? Fix: bounded retries, `kix.keys.rerun` values from `kix.keyValues`, a baseline delta.
- W22. Are `helm.sh/hook` annotations left on native resources? Fix: Kix hook keys or delete.
- W23. Is a pod-spec field set to its Kubernetes default (`dnsPolicy = "ClusterFirst"`, `automountServiceAccountToken = true`)? Fix: delete. `terminationGracePeriodSeconds` is the exception: `reliability.gracefulShutdown` asks for it, so a workload states it, at 30 with a comment when the program needs no longer drain.

### Images and versions (I)

- I1. Does a default image lack a digest? Fix: `nix run nixpkgs#crane -- digest <ref>` for the multi-arch index.
- I2. Does `repository` omit the registry host? Fix: `docker.io/org/name`.
- I3. Is a default tag floating (`latest`, `stable`, `next`) or prerelease? Fix: pin a stable release.
- I4. Is a default image from a frozen or unmaintained registry (`bitnamilegacy/*`)? Fix: official upstream image.
- I5. Do follower images (images from the same upstream release as the main image) drift from the main tag? Fix: `config.<c>.image.tag = lib.mkDefault config.image.tag;` and `tagText`. Separately released images (CSI sidecars) keep their own tags.
- I6. Are component images named flat (`webhookImage`)? Fix: `<component>.image`.
- I7. Is `pullPolicy = "Always"` set on a pinned tag? Fix: leave the default.
- I8. Is a version label hardcoded apart from the tag? Fix: derive from `release`.
- I9. Is the same image, type, or builder copied in two sibling packages (a toleration submodule, a VolumeSnapshotClass submodule)? Fix: one shared file both import, living in the older user, whose header names both users.
- I10. Is the default version out of upstream support, or far behind sibling packages? Fix: bump.

### Network policy (N)

- N1. Does the package write a NetworkPolicy or CiliumNetworkPolicy for its own workloads? Fix: delete; derived policy plus intents. Operator-created pods go through `kix.operandPolicy`.
- N2. Is an intent wider than needed (`all-pods`, `world` with no ports)? Package intents apply to every non-host-network workload of the package (lib limit), so check what each port opens on every pod and say so in a multi-workload header. Could a build-time `kix.operandPolicy`, which can read config, replace a broad `meta.network.intents` rule? Fix: narrow ports; comment each broad rule.
- N3. Is egress to external services missing, so the package breaks under default deny? Fix: `meta.network.intents` with `to = "world"` and ports.
- N4. Does the package open its metrics port with an intent? Fix: remove; the netpol plugin derives the scrape path from the monitors a Prometheus selects (HANDBOOK §16.8). Kix derives nothing for host-network pods it did not build (the kubelet, control-plane static pods). Does a PodMonitor select its pods with `matchExpressions`? Fix: `matchLabels`, which the derivation reads. Does a monitor over operator-created pods name its port? Fix: `portNumber` (PodMonitor) or a numeric `targetPort`; both fail evaluation under default deny.
- N5. Is an enforcer-specific selector or rule written out (an `endpointSelector`, `k8s:io.kubernetes.pod.namespace`, Cilium `entities` outside a `world` egress rule)? Fix: `scope.networkPolicyEnforcer.netpol.mkEndpointSelector`, `mkCallerIngressRule`, `mkServiceEgressRule`, `mkSelfRules`.
- N6. Does a config path (config file key, URL option) bypass the dep that drives the derived edge? Detection: wire the dep, set the config key it fills, and diff the policies. Fix: lock that path with `kix.mergeGuarded`. A package that derives egress from a passthrough (alertmanager's receivers) reads only the keys the program dials, from a table taken from upstream's config source, and refuses keys it does not know; a key-suffix match picks up links that are never dialled (`icon_url`, `client_url`).
- N7. Is a Service dialled by `out.name` or short name, or handed over through an object no pod spec references (a ConfigMap a sidecar reads through the API, a CR the program reads), so no edge forms? Fix: `out.fqdn` or `out.url` in the pod spec, or an intent.
- N8. Does a safety argument rely on network policy for an unauthenticated port, or does an intent open an unauthenticated port to `all-pods`? Fix: auth in the program.
- N9. Was the policy only checked on a cluster with no enforcer? Fix: test under default deny on an enforcing CNI.
- N10. Does a policy builder copy a Service selector that may be empty, so `matchLabels = { }` selects the whole namespace? Fix: refuse an empty selector.
- N11. Do clients need egress to pods an operator creates in another namespace (egress proxies, gateways) that the graph cannot see? Fix: a builder on `out` (cdi `out.mkImporterPolicy`) or a stated limit.
- N12. Does a docs example or fixture put an instance in kube-system (or another environment namespace) with network policy on and no flavour intents, giving the namespace default deny? Fix: its own namespace, or a flavour that declares the intents.
- N13. Does a package whose controller serves a `loadBalancerClass` publish the class as a plain string or with `builtins.appendContext`? *(lib: only a class from `kix.providedLoadBalancerClass` skips the loadBalancer role check and the external-ingress supplement)* Fix: `out.loadBalancerClass = kix.providedLoadBalancerClass { class = "<class>"; by = self.<controller>; }`, plus a backend policy builder on `out`.

### Monitoring (Mo)

- Mo1. Is `metrics` declared other than `kix.options.monitor` (or that `//` an `enabled` default of false)? Fix: use it.
- Mo2. Is a ServiceMonitor or PrometheusRule built directly, or emitted without a `prometheus ? null` dep? Fix: `kix.monitor`; for a PodMonitor scrape, `prometheus.out.mkPodMonitor` plus `kix.alerts`.
- Mo3. Is a metrics-only Service rendered when `metrics.enabled` is false or `prometheus` is null? Fix: gate on both. Exception: a Service that is `root` or the target of `kix.healthCheck` renders always.
- Mo4. Do `prometheus.io` annotations stand in for a monitor? Fix: `kix.monitor` or delete.
- Mo5. Are alerts not scoped to the instance (`job=~` regex, cluster-wide expr)? Fix: `namespace="<ns>", service="<metrics Service name>"`, aggregated `by (namespace, service)`; behind a PodMonitor, `job="<ns>/<PodMonitor name>"` and `by (namespace, job)`. `kix.monitor`'s `alerts` is a static set, so one `let` binding feeds both the Service name and the selector.
- Mo6. Does the package expose metrics but ship no alerts, or miss the common outage (target absent, no leader, last success stale)? A last-success alert evaluates to nothing when the target is down, so pair it with a down alert. Fix: alerts from "Writing a package's alerts"; a package that still ships none says why in its header.
- Mo7. Does an alert depend on another component's metrics? Fix: use the package's own.
- Mo8. Do two monitors select each other's Services (same labels)? Fix: a component label per Service.
- Mo9. Is the scrape scheme wrong for an HTTPS port? Fix: `kix.monitor` `scheme` and `tlsConfig`.
- Mo10. Are secondary components' metrics dropped? Fix: another `kix.monitor` with `name`, `monitorPart`, `rulesPart`.
- Mo11. Is `/metrics` served on the public route by default? Fix: off, `kix.expose { deriveHost = false; }` so only an instance that sets `ingress.host` is routed (Grafana), or state the trade-off.
- Mo12. Does the program need a flag or setting before it serves the metrics the ServiceMonitor scrapes (ingress-nginx `--enable-metrics`)? Read upstream's flag defaults, not the chart's values.
- Mo13. When `root` is an attrset with its own `requires`, does it omit the `kix.monitor` parts (`serviceMonitor`, `prometheusRules`, filtered for null), leaving them orphaned? Detection: a package-eval fixture with a real `prometheus` provider and the orphaned-part trace.
- Mo14. Does an alert's result lose `namespace` (a bare `sum(...)`, a `by` list without it, a `without` list that includes it, or `absent()` over an expression such as `absent(up{...} == 1)`, which returns no labels)? Routing, grouping, and inhibition then span the cluster, and `$labels` templates render empty. Fix: `sum by (namespace, service) (up{sel}) == 0 or absent(up{sel})` (HANDBOOK §9.4 "Writing alerts").
- Mo15. Is a rule's severity unset (the builder's default is `warning`), `critical` for a condition that is not an outage or data at risk now, or outside `critical`, `warning`, and `info`? The one exception is an always-firing `Watchdog` heartbeat, which carries `none` as kube-prometheus's does and which the alertmanager package's default settings route by name. Fix: set it on every rule, choosing the lower level when in doubt (BEST-PRACTICES §9.6).
- Mo16. Does a rule lack `summary` or `description`, template the `summary`, put a value or other changing text in a label, or set `runbook_url` to anything but a maintained upstream runbook for the same condition? Fix: a fixed `summary`; a `description` naming the instance, the value, the meaning, and the first thing to check.
- Mo17. Is `for` missing or under `5m` without a comment saying the expression's window already spans the restart time? Is a range window under four scrape intervals, or is `rate()` applied after `sum`? Fix: HANDBOOK §9.4 "Writing alerts".
- Mo18. Is a threshold a literal tuned for one site, when the evaluated configuration knows it (memory limit, replica count, schedule) or an instance would need to change it? Fix: derive it, or add a typed option to `metrics` (velero's `maxBackupAge`) whose description says where the default comes from.
- Mo19. Does an alert restate a kube-prometheus rule from `prometheus-default-rules` (crash looping, replicas mismatch, volume filling up, Job failed, TargetDown)? Detection: `grep -h '"alert"' kix/packages/prometheus-default-rules/rules/*.json`. Fix: delete it; alert on what only the package's own metrics show.
- Mo20. Does a rule break under Prometheus or vmalert: a template function one of them lacks, such as `float64` (prometheus-operator refuses the whole PrometheusRule, the VM converter the whole group), `query_offset`, or an exact comparison of `rate()` or `increase()`? Fix: HANDBOOK §9.4 "Writing alerts".
- Mo23. Does a ratio alert (errors over requests) lack a traffic floor, so one failure at low traffic fires it? Does a down alert fire when the component runs zero replicas by design or its metrics Service is off? Does a last-success alert lack a missing-metric partner? Fix: HANDBOOK §9.4 "Writing alerts".
- Mo21. Does an alert use a metric name not found in the program's source or a scrape at the pinned version? Upstream renames metrics between releases, and a rule over a missing metric never fires. Fix: cite where each metric is defined in the pull request; recheck on version bumps.
- Mo22. Do the rules lack a unit test (renders under its name, every expression has the selector, nothing without `prometheus` or with `metrics.enabled = false`), or does the package's test cluster lack a `.rules-test.yaml` beside its cluster file (same base name) that gives each alert a failing and a healthy fixture? The `rules-cluster-<name>` check runs `promtool check rules` on every cluster and `promtool test rules` on that file. Fix: HANDBOOK §9.4 "Writing alerts", "Tests".

### Escape hatches (E)

- E1. Is there no escape hatch for what the package does not model? Fix: `values` (Helm), `extraSpec` (CR or resource spec), `settings` (program config), `extraArgs` and `env` (native workloads); `partsOverlays` and `extra` remain.
- E2. Does a program-config passthrough use a name other than `settings`? Fix: rename.
- E3. Can `extraSpec` or `settings` overwrite a path the package computes (an address with an edge, a Secret ref, a quorum, a port), or inject a newline into a line-based config (flag files, an ini file the package renders, such as grafana.ini, where a line break in a value or `]` in a section name starts a section past the locks)? Fix: `kix.mergeGuarded { who; locked; what; }`, locked paths in the description; refuse line breaks.
- E4. Is a lock list wider than the leaves the package writes? `kix.mergeGuarded`'s message always ends "Use the option that owns it"; where no option owns the path, add a local check before the merge whose message says the package sets it.
- E5. Is a passthrough merged with shallow `//`? Fix: `kix.mergeGuarded` or `lib.recursiveUpdate`.
- E6. Can `extraArgs` override an owned flag, including its other spellings (deprecated long names, an alternative short flag, Go's single-dash form, a dskit flag that overrides a locked `settings` path, port flags that Services, probes, and intents derive from)? Fix: `baseArgs ++ kix.guardArgs { who; owned."--flag" = "reason; fix"; } config.extraArgs`, listing every spelling. Each reason names only what really reads the flag, and reads after "which the package owns:"; a refused flag the package does not set needs its own wording.
- E7. Does a guard written in the package use a bare prefix match (`--ingress-class` hits `--ingress-class-by-name`)? Fix: `kix.guardArgs` (it matches the flag, `flag=`, and a one-letter flag with an attached value).
- E8. Can `env` replace a DI-owned variable, including `_FILE` twins and variables that override owned ones as a group (`DATABASE_URL`, `MB_DB_CONNECTION_URI`)? Fix: `kix.mergeEnv` `owned` (`vars` or `names`); a `names` entry the package sets only under a condition gets a message naming the condition.
- E9. Does a deep merge replace an owned list (containers) or deep-merge `valueFrom`? Fix: lock the list; use `mergeEnv` for env.
- E10. Do docs advertise `partsOverlays` for something the package refuses or the overlay cannot change? Fix: state only what works.
- E11. Do Helm-parity knobs remain (`namePrefix`, `releaseName` options, `fullnameOverride`, `labelStyle = "helm"`)? Fix: delete; names from `scope.instanceName`.
- E12. Do clusters `lib.mkForce` away a package default, or do several clusters repeat the same override? That means the default is wrong. Fix: change the default.
- E13. Do `partsOverlays` in clusters rebuild builders the package could export? Fix: export them on `out`.

### Naming and multiple instances (Na)

- Na1. Is any resource named with a literal instead of `scope.instanceName`? Read each builder's `name`; container, port, and volume names are exempt. Fix: `"${name}-<part>"`.
- Na2. Do cluster-scoped objects (ClusterRoles, webhooks) collide for same-named instances in two namespaces? Eval two. Fix: qualify with the namespace, or `conflictsWith` with a clear message. A user-facing cluster-scoped name (PriorityClass, StorageClass, IngressClass) keeps the bare instance name, relies on the duplicate-resource check, and says in the header that names are unique across namespaces. The lib's `<name>-<ns>` qualification collides for instance `a-b` in `c` and `a` in `b-c`; the duplicate check catches it, so do not re-derive it per package.
- Na3. Do two components share labels, so one Service selects the other's pods? Fix: `app.kubernetes.io/component` per component.
- Na4. Are non-standard label keys used (`component`, `role`)? Fix: `app.kubernetes.io/*`. Keys the upstream program requires (velero node-agent's `name`) stay, with a comment naming the upstream file; a chart label kept for parity does not.
- Na5. Do names change with a topology flag, orphaning StatefulSets or claims? Fix: one naming scheme.
- Na6. Is a user-keyed attrset merged into the part set or rendered into a part folder (classes, VolumeSnapshotClasses, CRs) outside `kix.storage.mkClasses`, so a key named `root` or `meta` silently vanishes? Detection: eval with a key named `root`. Fix: refuse reserved keys.
- Na7. Does a default claim a cluster-wide singleton (default StorageClass, IngressClass, or PriorityClass)? Fix: default off.
- Na8. Are names legal (RFC 1035 Services, DNS-1123, 63-character limits, CronJob 52)? Fix: shorten or derive.
- Na9. Do external names depend on the instance name without saying so? Fix: comment it.
- Na10. Do two instances that resolve to one shared dependency collide inside it (a fixed Redis DB index, key prefix, queue namespace, schema, bucket path)? Fix: derive from the instance, or say in the header that each instance needs its own dependency.

### Site leakage (L)

- L1. Do comments, defaults, examples, or tests name a private site, customer, cluster, provider region, pool, interface, or private repo? Fix: remove; a typed option with a public-safe default. Public flavour names (`ovh`, `eks`) are not leakage.
- L2. Is one site's value the default (timezone, region, bucket, CIDR, hostPath, DNS provider)? Fix: required option or cluster config.
- L3. Is `cluster.local` written outside a comment or `crds/`? *(lib: package-eval's source scan and `architecture.clusterDomainLiteral`)* Fix: `out.fqdn` or `clusterConfig.clusterDomain`; no `or "cluster.local"` fallback.
- L4. Is the package named after its delivery mechanism or a site rather than its function? Fix: rename.
- L5. Do fixtures carry values strangers will copy (large sizes on kind, plaintext placeholders)? Fix: small, honest values.
- L6. Does a native package justify a choice by "the upstream chart does"? Fix: justify from the program.

### Comments and prose (P)

These items also apply to text the change adds under `docs/`, `housekeeping/`, and `v2_discussions/`.

- P1. Does the header describe things the code does not do? Read it against the code. Fix: correct it.
- P2. Does the header miss the template: `# <package directory name>: <what it runs>`, what it installs, required deps and config, a minimal instance, the `out` contract, then escape hatches and known limits when the package has any (ceilings, untested paths, host prerequisites)? Fix: add what is missing.
- P3. Do comments carry history (`removed`, `used to`, `no longer`, `matching the live cluster`, issue numbers, dates)? A dated "checked against upstream" note is history too. Fix: state the reason or delete. Housekeeping titles are dated by rule.
- P4. Is there an em dash, or a list of three or more without the Oxford comma? Fix: comma, colon, or period; add the comma.
- P5. Does a comment claim "always", "never", "only", or "safe" beyond what is enforced, describe upstream behaviour that the pinned upstream source does not show, state a measured number with no recorded run, or describe behaviour a later change will enforce? Fix: scope it, check it, or delete it.
- P6. Is a footgun explained in a comment where an assertion would do? Fix: the assertion.
- P7. Is a non-obvious choice (an alias that clears a default, an upstream inversion, a missing limit) uncommented? Fix: one line with the upstream file. Does a comment credit the upstream binary with a constraint that is really the package's choice (a fixed name, a pinned flag)? Check the upstream flags.
- P8. Do option descriptions, code comments, or test comments cite plan numbers, review codes, or promise shapes the type refuses? Fix: describe behaviour.
- P9. Does a throw lack the prefix `<package> <ns>/<instance>: `, the constraint, and the fix? Messages from `assertions` start with the constraint (the lib adds the prefix). Pass the same `who` to `mergeEnv`, `mergeGuarded`, `guardArgs`, and `checkSecretKeys`, with the component's option path in `who` for a multi-component package. An error raised inside a provider's `out` function on a consumer's behalf names the consumer resource from its arguments.
- P10. Does an error ask a cluster author for something only a package author can do, name repo-internal tooling (agent skills, plan numbers), give a fix that does not clear it, or give the fix for one provider shape when another (`kix.mkImport`) triggers it? Evaluate the suggested fix. Does a warning keep firing after the user applies the fix it recommends?
- P11. Does a package assertion never fire because a builder forced in `build` (`mkSecret`, `mkCR`, `keyRef`) throws first with a lib message? Eval with the condition true. Fix: check before the builder, or drop the dead assertion.
- P12. Does a package-internal consistency check (vendored sources against `release`) sit in `assertions` that every cluster evaluates? Fix: a lib test or the vendoring script.
- P13. Do docs or CLI text list packages by behaviour ("packages that hash a ConfigMap")? Fix: phrase them as examples, or give the grep that finds the current set.

### Docs and tests (T)

- T1. Is the package used by no test cluster and evaluated only with defaults? Is a test cluster kept whose reason to exist was removed? Fix: a `clusters/test-<pkg>.nix` that turns on every toggle; delete or re-justify the stale one in its header.
- T2. Does a refusal lack a committed negative test, or a feature its positive one? Tests live in `kix/lib/tests/units/<topic>.nix` with names `<topic>-<what>`; probes kept in a scratch file or a pull request description do not count. `evalFails` uses `builtins.tryEval`, which drops a throw's message, so pair each `evalFails` with a positive control (the same cluster without the bad value evaluates) so it cannot pass on an unrelated failure. Check assertion and warning text by calling the package's `assertions` or `warnings` function, or a pure check function, directly. Check a throw's text with `nix eval ... 2>&1 | grep` and quote it in the review.
- T3. Could a test pass while the bug is present (feature off, level `none` only, no enforcer, a single instance, an earlier check firing first)? When two guards cover one mistake (`conflictsWith` and `annotationDomains`), test each with the other removed. Test auth and ACLs with the client libraries' discovery calls (Sentinel lookups, cluster topology commands), not only the CLI. Fix: assert the specific outcome.
- T4. Does a new package or setting miss its `kix/package-eval.nix` entry (`settings`), or carry an unjustified `knownFailures` or other exception? Fix: add settings; grant or fix.
- T5. Are header examples and docs snippets unevaluated? Fix: evaluate the exact snippet; a header example with a SOPS `source` is evaluated through its `stringData` twin in the test cluster, which the header names.
- T6. Does a new public API miss HANDBOOK, FEATURE-CATALOG, the kix-migration skill, or this skill? Fix: add rows.
- T7. Do docs, skills, examples, or lib test file names still name removed options, packages, or paths? `git grep -n -i` every spelling (`foo-bar`, `foo_bar`, `fooBar`, `foo bar`). Hits in `v2_discussions/archive/` and housekeeping history are acceptable. Fix: update them in the same change.
- T8. Are noticed, unfixed problems missing from `housekeeping/`? Is an entry kept whose problem the change resolves, deleted while the problem holds, or written as a near-duplicate of an existing entry? Fix: one entry per problem; append to the existing entry; delete resolved ones in the same change.
- T9. Are host prerequisites (kernel modules, `/dev/kvm`, architecture) undocumented? Fix: header line.
- T10. Does a how-to tell readers to deploy a test fixture, depend on test-only resources, or assert another page's Secret names or keys? Fix: self-contained steps.
- T11. Do docs or option descriptions promise that removing config deletes objects? Plain `kix deploy` only reports orphans; deletion needs `--prune`.
- T12. Does a change to a package that exists on main report no upgrade deploy: main's version on kind, then the change on the same cluster, applied with no extra flag (`--accept-migrations`, `--force-conflicts`) and ready (package-authoring "Handover", step 3)? It catches a new required input, a change of kinds in a stateful package, renamed or removed objects, and immutable-field changes. Fix: run it. A deliberate breaking change that cannot pass says in the header's `Upgrades:` paragraph what an operator does first.

## Writing a package's alerts

Research the software's failure modes before writing a rule. Keep notes with
a source for each claim; they go in the pull request description.

1. **Read upstream's monitoring material at the pinned version.** The
   project's monitoring or operations docs, its metric reference, its source
   where metrics are registered, and any rules it ships: Helm chart
   `PrometheusRule` templates, sample rule YAML, or a mixin. Note whether
   those rules are maintained, which exporter they need, and how their
   selectors are written.
2. **Read how it fails in practice.** Practitioner write-ups, postmortems,
   and Hacker News threads on running it; upstream issues about outages,
   data loss, and confusing states; and the upstream runbooks. Prefer
   personal blogs and issue threads to vendor marketing.
3. **List the failure modes.** For each, note the first metric that shows
   it, and whether a symptom would show before it is too late to act.
4. **Sort each failure mode** into one of: covered by a kube-prometheus rule
   in `prometheus-default-rules` (no package alert); a package alert, in the
   four kinds of BEST-PRACTICES §9.6; or a dashboard concern, not an alert.
5. **Decide vendor or write** (BEST-PRACTICES §9.6). To vendor, pin the file
   and its version beside the package, rewrite its selectors to the instance
   as `prometheus-default-rules` does (string substitution of the `job`
   matchers in `rebake`), and test that every expression got the selector.
6. **Write and test the rules** against HANDBOOK §9.4 "Writing alerts" and
   items Mo5 to Mo23. Test each rule with a fixture that breaks the condition
   and one that stays healthy.
7. **Say what is covered.** The package header lists the alerts and the
   failure modes left to the generic rules or to the site.

## Reviewing a deletion

A pull request that deletes a package needs these checks instead of the
checklist above:

- `git grep -n -i` every spelling of the package name and of its option names
  over tracked files (a recursive grep walks gitignored trees such as
  `docs/dist/`). Report each hit outside `v2_discussions/archive/` and
  housekeeping history.
- Its consumers in `clusters/`, `ludo/`, and the docs examples are removed or
  moved to a replacement; optional `<name> ? null` args in other packages are
  deleted, since they keep resolving to null and hide the dead edge.
- `kix/package-eval.nix` keeps no `settings` or exception entry for it
  (`strayKeys` fails on one); flake lines, the docs page, its
  `docs/how-to-coverage.json` entry, its `docs/nix/captures.nix` group, and
  docs navigation are removed.
- Lib tests named after it are renamed to the topic they test.
- Its housekeeping entries are deleted or reworded.
- Lib helpers and test clusters that lose their last user are deleted (P14).
- A functional gap the deletion leaves gets a ROADMAP item or a docs note.

## How to run a review

**Read first, narrowly.** The package's header and `default.nix`, its
`crds/sources.txt`, its `kix/package-eval.nix` entry, and the consumers:
`git grep -n 'packages\.<name>\|<defaultAlias>' kix/packages clusters ludo docs`.
Open HANDBOOK sections (§5 contract, §9 helpers, §16 netpol, §21 secrets, §22
CRDs) only for an item you are judging. Run `git add` on new files before
any Nix evaluation, and never use a `path:` flakeref.

**1. Run the automation, then skip what it proves.**

| Check | Command | Catches |
|---|---|---|
| every-package-evaluates | `nix build .#checks.x86_64-linux.every-package-evaluates --extra-experimental-features pipe-operators` | eval errors on defaults (plus the `settings` entry) in a synthetic kind cluster with a non-default cluster domain, at availability `none` and `zone`; error-severity scorecard rules; `cluster.local` in source; `meta.version` parse; the option contract (O2), once per package and availability level and first, so a violation fails in seconds; stale `knownFailures` and exceptions |
| kix-lib-tests | `nix build .#checks.x86_64-linux.kix-lib-tests --extra-experimental-features pipe-operators` | lib helpers and the tests under `kix/lib/tests/units/` |
| scorecard | part of the eval; `kix check <cluster>` | probes, resources, non-root, `latest`, placeholders, owner, description, `monitorSelectorMatchesService`, `clusterDomainLiteral`, `selectorCoherence`, `unsafeGrants`, `volumeHasSource` |
| validate and cross-resource checks | part of the eval | SA and roleRef exist, Service selectors, unique names, CR-to-CRD declarations and served versions, declared Secret keys, managed Secret keys without values, one default class, claim and class references |
| CRD vendoring | `nix shell nixpkgs#uv -c uv run --frozen scripts/vendor-crds.py --check` | stale or orphaned vendored CRDs and roles |
| smoke cluster | `nix build ludo/#cluster-ludo-kind --extra-experimental-features pipe-operators` | regressions in the full package set |

Check `df -BG --output=avail /` before a build. Redundant-requires and
orphaned-part warnings are traces, not failures, and appear only when the
toggle that creates the part is on: evaluate the test cluster that turns on
every toggle and has each optional dependency present, and read its traces.
A test cluster that depends on a package from an unmerged change builds with
a `kix.mkImport` stand-in; note the merge order.

Automation evaluates defaults, one instance, and two availability levels. It
does not judge naming, DI choices, intent width, readiness correctness, safe
defaults, dead options, site leakage, comments, or toggled paths.

**2. One combined grep pass.** Run this once from the repository root and
read only the hits. Each line is prefixed with the item it serves; a hit is a
lead, not a finding.

```bash
PKG=kix/packages/<name>
while read -r id re; do
  rg -n --no-heading -g '!**/crds/**' -g '!**/rbac/**' -e "$re" "$PKG" | sed "s|^|$id |"
done <<'EOF'
O1 types\.(anything|unspecified|attrs)\b
O3 resources = (lib\.)?mkOption
O4 // config\.env|config\.env //
O5 image = "[^$]
O18 \benable = (lib\.)?mkOption
O19 replicaCount
O20 \b(nodeSelector|tolerations|affinity|priorityClassName) = (lib\.)?mkOption
D1 svc\.cluster|\.svc\b|cluster\.local|"https?://\$\{
D2 serviceAccountName|serviceName =
D17 ClassName = "
S1 (?i)(password|token|apikey|secretkey)\w* = (lib\.)?mkOption
S3 \bcredentials( \? null)?,
S4 \.assertions = dep|deps\.\w+\.assertions
S7 kind = "Secret"
C1 fromKind
C2 apiVersion = "[a-z0-9.-]+\.[a-z]+/
C10 verbs = \[ "\*"|cluster-admin
W1 replicas = [0-9]
W2 topologySpreadConstraints|podAntiAffinity
W15 hostNetwork = true
W16 enableServiceLinks
W22 helm\.sh/hook
I3 tag = "(latest|stable|next|main|master|edge)"|:latest\b
I4 bitnami
I7 pullPolicy = "Always"
N1 kind = "\w*NetworkPolicy"
N2 all-pods|to = "world"
N5 entities =|k8s:io\.kubernetes\.pod\.namespace|endpointSelector
Mo2 kind = "(ServiceMonitor|PodMonitor|PrometheusRule)"
Mo4 prometheus\.io/
Mo5 job=~
Mo14 absent\([^)]*==|without \(|\b(sum|max|min|avg|count) *\(
Mo20 float64|query_offset
E5 config\.(values|extraSpec|settings) //|// config\.(values|extraSpec|settings)
E7 hasPrefix "-
E11 releaseName|fullnameOverride|namePrefix|labelStyle
Na4 "(component|role|app|release|tier)" =
P3 #.*(20[0-9]{2}-[0-9]{2}|kixpkgs#[0-9]|live cluster|caught live|used to|no longer|was removed|removed in)
P4 \x{2014}
EOF
rg -n 'mkForce' clusters ludo | rg '<name>'                 # E12
rg -n -i -e "$SITES" "$PKG" clusters docs/src/content/docs  # L1
```

`SITES` is a `|`-separated regex of the private site, customer, cluster,
region, pool, and interface names you know of. The maintainers keep that
list outside the public repository; ask for it when you do not have it.

**3. Read the code once, for the judgement items.** Read the package in
checklist order and judge only what the automation and the grep hits do not
settle: M2 to M15, O6 to O24, D, S, C4 to C23, W, I, N, Mo, E, Na, L, P, and
T. Skip an item marked *(lib)* unless its check failed or its path is off by
default. Evaluate the package once with every toggle on, once with each
optional dependency present, and once with two instances in two namespaces
before signing off.

**4. Report failures only.** Leave out items that pass. One line per
finding, most severe first:

```
[blocker] kix/packages/foo/default.nix:42 S4: checks key "token" in deps.apiToken.assertions; keyRef throws first. Fix: bind through kix.checkSecretKeys.
```

- **blocker**: wrong at runtime, unsafe default, credential exposure, site
  leakage, or a principle broken in public API.
- **should-fix**: convention breach, missing check, dead surface, misleading
  comment.
- **nit**: wording or style.

End with the checks you ran and their result, anything you could not verify
(real credentials, an enforcer), and the housekeeping entries you filed. If
a checklist item proved wrong or missing, add a "Checklist feedback" line,
and fix this file in the same change when you are the author.

# kix Feature Catalog

Complete inventory of kix/lib (Nix library) and CLI features. Breadth-first — every capability mentioned, none deeply explained.

---

## kix/lib — Nix Library

### Core Resource System (`k8s.nix`)

- **`mkResource`** — Content-addressed K8s resource constructor. Accepts apiVersion, kind, name, namespace, spec, data, stringData, labels, annotations, outputs, requires, extraDeps, extra, clusterDomain. Auto-derives selector from `spec.selector.matchLabels` or labels. Auto-derives outputs: name, fqdn, identityHash, selector. Stamps `kix.run/depends-on` annotation from dependency graph. Returns resource with `outPath` (Nix store path), `out`, `rawManifest`, `manifest`.
- **`mkClusterResource`** — Same as mkResource but cluster-scoped (no namespace).
- **`mkImportResource`** — Lightweight ref constructor for import mode (no store paths).
- **`clusterScoped`** — Sentinel value for cluster-scoped resources.
- **`mkPackageInstance`** — PackageInstance CR: root of per-package DAG. Carries root resource ref, requires, post-hooks, inverse deps, version.
- **`mkActivation`** — Cluster-level root CR referencing all instances via Nix string context.
- **`mkCRDBuilders`**: Generates `cr` (transformer) and `mkCR` (builder) for custom resource types. Takes the served versions and `declaredBy`; a custom resource at any other version fails the build with the served list.
- **`attachCtxDeep`** — Recursively attach Nix string context to all strings in a tree (implicit dependency tracking).
- **`extractStoreHash`** — Extract 32-char hash from `/nix/store` path.
- **`nsOf`** — Resolve resource namespace to string key.
- **`resourceId`** — Canonical ID: `"${kind}/${name}@${namespace}"`.
- **`kixCRDs`** — Built-in CRD resources (PackageInstance, Activation).
- **`mkCRDRefHandle`** / **`mkImportMarker`**: the CRD-ref handle and import marker shared by `scope.mkCRDRef` and `kix.mkImport { crds }`; they take the caller's `mkResource`.

### Cluster Evaluation (`eval.nix`, `eval/`)

- **`buildCluster`** — Top-level orchestrator. Evaluates NixOS modules, auto-instantiates packages, resolves DI, builds fixpoint, collects resources, generates activation.
- **Auto-instantiation** (`eval/auto.nix`): Transitive closure via `builtins.genericClosure` from mandatory deps. Seeds from explicit instances, discovers transitively required packages. Handles optional vs. available packages. A dependency wired with `deps.<arg>` places no demand on the shelf; a `ref` to an optional instance activates it. Only required dependencies demand; an optional dependency, role-named or not, never pulls a shelf package. A demanded name that more than one shelf package (or more than one optional instance after the managed-over-import and same-namespace preferences) answers is refused with every claimant and its claim source; select with an optional instance of that name. A demand is keyed by its requesting namespace, so each namespace activates its own optional instance or gets its own copy of a shelf package; a role-named dependency is keyed by the role, so one provider serves every namespace. A shelf package marked one per cluster (`meta.conflictsWith` naming one of its own keys with `cluster:`, or a `meta.roles` claim, and not `meta.scope = "namespace"`) that the closure would place in more than one namespace is refused (`spreadRefusals`), naming each requester and asking for one declared instance. A declared instance that claims the same `cluster:` key without answering the demanded name is refused by its own `conflictsWith`, which marks the conflicting instance as auto-instantiated and names its requesters.
- **Shared cluster-scoped objects** (`eval/cluster.nix` `sharedClusterObjectAssertions`): a cluster-scoped object (API group, kind and name) that two active instances render fails evaluation, naming the object and the instances, whether the copies are identical or not. `rawManifests` otherwise keeps one copy of identical resources (`dedupeByOutPath`).
- **Dependency injection** (`eval/resolve.nix`): DNS-like resolution: explicit override > same-namespace > cluster-wide > default. Managed instances preferred over imports. An instance whose package declares `meta.scope = "namespace"` is skipped for consumers in other namespaces. Resolution errors start with the requesting instance (`<ns>/<inst>`, marked `(auto-instantiated)` when the shelf created it).
- **`callPackagePhase1`** — Calls package with system args (scope, lib, kix).
- **`discoverBuildDeps`** — Introspects build function args for DI dependency names.
- **`resolveDeclaredDeps`** — Resolves declared deps via resolution index.
- **`resolveDepTargets`** — Phase-1 pre-pass: resolve targets without full evaluation.
- **`buildConfigInjections`** — Creates NixOS module injections from dep phase-1 results.
- **`evaluateInstanceConfig`**: Evaluates config via `lib.evalModules` over the package's `options`, the package's own `config` (an attrset or a `{ config, lib, ... }:` module function, which may also take `clusterConfig`, so one option can default from another or from a cluster fact with `lib.mkDefault`), dependency injections and the instance config. A `lib.mkDefault` in the package's `config` runs at `packageDefaultPriority` (1250): it replaces the declared default (1500) and yields to anything an instance or injection sets, `lib.mkDefault` (1000) included. An instance value replaces a default under the module system's own merge; the option contract (below), checked in package CI, refuses a default that a partial instance value would discard. Supports `mkLocked` for immutable fields. Detects conflicts with dep injections. With `namespaceName` and `instanceName` (passed by `eval/cluster.nix`, `eval/instance.nix`, and `eval/import.nix`), module errors name the option `instances.<ns>.<inst>.config.<option>` and each definition's file; an injected definition reads `config injected into <ns>/<inst> by <source>`.
- **`optionContractViolations` / `checkOptionContract`** (`eval/options.nix`): the option contract. Walks a package's raw `options` (submodule fields included; a recursive type stops at the first option that repeats a declaration on its path, with depth 12 as the bound for options without a position) and reports defaults an instance value would partly discard: Rule 1 untyped (`anything`, `unspecified`, `raw`, `attrs`, `attrsOf` of those, or no `type`) with a non-empty attrset default; Rule 2 `attrsOf`/`lazyAttrsOf` with a non-empty default; Rule 3 a submodule whose own default sets a key its field does not default to. A default wrapped in `lib.mkDefault`, `lib.mkOverride`, `lib.mkOrder`, `lib.mkMerge`, or `lib.mkIf` is checked as the value it wraps; a `coercedTo` whose source type rejects the default is checked as its final type; the default of an option whose type takes no attrset is not evaluated. A declaration it cannot read (a throwing default or submodule, a default with another `_type`, an attrset default on a type no rule covers such as `attrTag`, a non-option entry, deeper than depth 12) is reported too. Instance evaluation does not run it.
- **`checkPackageOptions` / `packageOptionViolations`** (`eval/package-options.nix`, exported on `kix`): the option contract over a package. `kix.checkPackageOptions { package; who ? "the package"; scope ? { instanceName = "check"; namespaceName = "check"; }; }` calls phase 1 at each availability level up to `meta.availability.max` (once for a package that does not take `availability`), with the ceiling-aware `kix` an instance receives, and throws with one line per violation, naming the levels of one that occurs at some levels only; null when the options pass. `packageOptionViolations` returns the violations with their `levels`. `every-package-evaluates` runs it on every kixpkgs package before any synthetic cluster (`kix/package-eval.nix` `checkOptionContract "<name>"` for one), and `mkFlake { packages.<name> = ...; }` adds the check `option-contract-<name>`.
- **`mkLocked`** — Marks a config field as immutable (blocks dep injection overrides).
- **`evaluateInstance`** (`eval/instance.nix`) — Full single-instance pipeline: normalize → discover deps → resolve → meta checks → config eval → overlays → fixpoint → closure → validation → netpol → scorecard → diagnostics → PackageView → PackageInstance CR.
- **`evaluateImportInstance`** (`eval/import.nix`): Lightweight path for imports: runs package with null-throwing proxy deps, extracts root's `out`, creates marker PI CR. A list `build` is folded entry by entry as for a managed instance, so `kix.monitor` and other helper entries work in import mode; `partsOverlays` do not apply, `availability` is `"none"` and `deps` is empty.
- **`mkImport`**: Import marker: `{ from?, out?, kind?, apiVersion?, roles?, crds? }`. `from` = optional package function for lazy out derivation. `crds` = CRD handles the environment provides, as `out.crds.<Kind>`, with markers emitted while the import is active. An optional import becomes active as an optional managed instance does, when a required dependency or a `deps` ref demands it (`eval/auto.nix`); an inactive optional import answers no dependency, so an optional dependency gets null rather than reading an `out` whose marker is never emitted. The instance's `extraDeps` adds dependencies to the import's marker: resources, or `ref.<ns>.<inst>` for that instance's PackageInstance marker (`eval/import.nix`: `checkExtraDeps` refuses, on every declared instance whether or not it is active, a malformed entry, a ref to the import itself or to a name that is not an instance, and `extraDeps` on a managed instance; `resolveExtraDep` refuses a ref to an optional instance that is not active).
- **`kix.untrackedRef`** (`core/markers.nix`): a name Kix does not render. The string form is an inert claim; the attrset form `{ kind; name; by; }` (experimental) carries the creator's context and stamps `kix.run/expects` on the referrer, which `kix deploy` waits on (`readiness.rs#wait_for_expectations`) before applying it. `by` rejects passive built-in kinds (`markers.passiveKinds`: ConfigMap, Secret, Service, RBAC and similar) and accepts any other kind. `{ name; by = "self"; }` marks an object the referring resource creates itself: no dependency, no expectation, rejected in a workload reference without `optional = true`, and not audited while exactly one resource carries it.
- **`kix.providedLoadBalancerClass`** (`core/markers.nix`): `{ class; by; }`, the load balancer class a provider publishes, with a marker and the context of `by`; a LoadBalancer Service naming it skips the `loadBalancer` role check and the external-ingress supplement.
- **`scope.mkServiceRef` / `scope.mkSecretRef`** (`scope/builders.nix`): a marker for a Service or Secret kix does not render (an operator's `prometheus-operated`, a Secret minted at runtime). `mkServiceRef { name, selector, ports, labels?, requires? }` exposes `out.{name, fqdn, port, labels}` with dependency context; the deploy engine waits for ready endpoints; netpol derives edges from the declared selector; the cross-resource checks and the monitor rule treat the marker as the Service it describes. The victoria-metrics-cluster package refs the operator's Services this way. A Service Kix renders over operator pods declares `kix.run/operand-of = "<group>/<Kind>/<name>"` instead; the prometheus and alertmanager packages render one per instance and name it in the resource's `spec.serviceName`, so the operator creates no `prometheus-operated` or `alertmanager-operated`.
- **`mkScope`** (`eval/scope.nix`): Per-instance context. Provides: mkResource (refuses workload kinds), mkClusterResource, mkDeployment, mkStatefulSet, mkDaemonSet, mkJob, forNamespace, mkCRD, mkCRDRef (required `version`; `servedVersions` defaults to `[ version ]`; the marker is `crd-ref-<instance>-<plural>-<group-with-dashes>`), mkCR, full RBAC DSL. Supports kix and helm label styles via `labelStyle`. mkCRD/mkCRDRef accept per-kind controller declarations that ride into every mkCR-built CR: `factBehavior` (netpol) and `readiness = { path; equals; }` (health convention, stamped as the `kix.run/readiness` annotation and evaluated by `kix deploy`).
- **`selectorLabelsOverride`** — Override auto-derived selector labels (for immutable selectors on existing workloads).
- **Capability checks**: Lazy checks: `checkCapability`. Guards for loadBalancer, privilegedContainers, daemonSets. `checkHorizontalPodAutoscaler` gates an HPA that reads metrics.k8s.io (autoscaling/v1, autoscaling/v2 with no `metrics`, a `Resource` or `ContainerResource` metric) on the `metricsApi` role: error when bound `absent` with no provider, warning when unbound; `scope.requireMetricsApi subject` runs the same check for a consumer that reads the API from config (descheduler `KubernetesMetrics`). `checkLoadBalancer` skips a Service whose `loadBalancerClass` comes from `kix.providedLoadBalancerClass` (a provider in the build serves it).
- **`mkNamespace`** (`eval/namespace.nix`) — Creates Namespace resource + optional ResourceQuota + NetworkPolicy resources.
- **`mkPackageView`** (`eval/view.nix`): Consumer-facing instance shape: folders (plain attrsets), autoKeys (root.out fields), system fields (_type, _packageInstance, root, out, raw, _meta). Known-folder validation (secrets, crds). A known folder whose name `root.out` also defines is left out of the view, so `out.crds.<Kind>` can sit beside a `crds.*` parts folder.
- **Helpers** (`eval/helpers.nix`) — `mergeCollide` (collision-detecting merge), `collectTypedAttrs` (recursive `_type` collector), `knownFolders`.

### Composition Helpers (`compose.nix` — the `kix` argument)

- **`port`** — Shorthand: `port "http" 8080` → `{ name, containerPort, protocol }`.
- **`keep`** — Mark a constructor-built container "never collapse to absent": renders `{}` even when every member is null, survives later merges. Backed by collapse-rule normalization (`kix/lib/core/normalize.nix`): literal empties render, all-null containers collapse.
- **`keyValues`**: the values Kix gives its own annotation keys (`core/annotations.nix` `values`): `kix.keyValues.rerunOnChange` for `kix.run/rerun` on a Job.
- **`mkEnvVars`** — Attrset → K8s `[{ name, value }]` list. Null values filtered. A value may also be a `valueFrom` source, so `{ DB_PASSWORD = creds.out.keyRef "password"; }` works and keeps the edge to the Secret; any other attrset is refused at eval time.
- **`mergeGuarded`**: `{ who; locked; what?; } base overrides`: `recursiveUpdate` that throws when `overrides` touches a locked attribute path or sets one of its ancestors to a non-attrset value such as null. The guard for `extraSpec` escape hatches (clickhouse-cluster, clickhouse-keeper, victoria-metrics-cluster) and for the `settings` of loki, tempo, clickhouse-logs, and loki-logs.
- **`operandPolicy`**: `{ scope; name; spec; }`, a network policy over operator-created pods, labelled derived and `operator-managed-workload`; drops the sections of a direction `networkPolicy.directions` does not enforce (`scope.networkPolicyEnforced`); null without an enforcer or when no section is left. `spec` is in the enforcer's format and carries the pod selector. Used by arc, arc-runner-set, cdi, clickhouse-cluster, clickhouse-keeper, kubevirt, stackgres-cluster, tailscale, and velero.
- **`mergeEnv`** / **`guardArgs`** / **`checkSecretKeys`**: refuse an instance value that would replace an env var or flag the package owns, and refuse a secret dependency that does not declare the keys the package reads, each with one message per hit. `guardArgs` matches a flag exactly or as `<flag>=...`; a one-letter flag (`-c`) also matches `-c<value>`.
- **ClickHouse packages**: `clickhouse` (single node) and `clickhouse-cluster` (Altinity operator, with `clickhouse-operator` and `clickhouse-keeper`) answer one `clickhouse` alias with the `out` contract in `kix/packages/clickhouse/contract.nix` (`httpUrl`, `nativeEndpoint`, `host`, `ports`, `username`, `authSecret`, `authPasswordKey`, `clusterName`, `version`), checked at eval on both the implementation and the consumer side. Consumers depend on `clickhouse-database` (database, user, privileges, optional `schema` SQL files; credentials in the consumer's namespace). `clickhouse-logs` ships pod logs with Vector. `loki-logs` ships pod logs to a `loki` dependency (labels namespace, pod, container, node, stream). Both Vector packages share `clickhouse-logs/vector-agent.nix` and take `settings` (guarded by `kix.mergeGuarded`), `extraArgs`, and `env`; loki-logs takes an optional `priorityClass` dependency. The pattern to copy for a service with a single-node and an operator form. `v2_discussions/148`, `149`.
- **`otel-collector`**: the OpenTelemetry Collector (contrib 0.161.0), Kix-native with no operator: `mode` `"deployment"` (a gateway, replicas from the availability level) or `"daemonset"` (a node agent behind an `internalTrafficPolicy: Local` Service). `settings` is the collector configuration, deep-merged over OTLP receivers on 4317 and 4318, `memory_limiter`, `batch`, and `health_check` on 13133 (the probes), through `kix.mergeGuarded`. An optional `otlp` dependency (an OTLP endpoint under `kix.contracts.otlpEndpoint`, such as Tempo) adds an `otlp_grpc` exporter and a `traces` pipeline, with derived egress. `events.enabled` watches Kubernetes Events (without the TTL deletions) and writes each notification as OTLP JSON to stdout for a pod log shipper, in deployment mode at one replica. `k8sattributes`, `k8s_cluster`, `k8s_events`, and `kubeletstats` are refused in `settings`, since the package renders no RBAC for them. `out.otlpGrpcUrl`, `out.otlpHttpUrl`, which fail evaluation when read from an instance whose pipelines do not use the `otlp` receiver; self metrics on 8888 through `kix.monitor`. Evaluation refuses a configuration with no pipeline.
- **`falco`**: the Falco runtime security agent (0.45.0), a Kix-native DaemonSet on the `modern_ebpf` driver (Linux 5.8 or later with BTF). The container runs as root with BPF, PERFMON, SYS_RESOURCE, and SYS_PTRACE added and AppArmor unconfined, not privileged, and mounts /proc, /etc, /sys/kernel/tracing, and the directory of each `containerRuntime.sockets` entry read-only; no host network or PID namespace. Loads the image's default rules, then `rules` (rule files keyed by name, each entry checked for one rules-file key) from a ConfigMap. Alerts go to stdout as JSON lines for a pod log shipper. `settings` deep-merges over falco.yaml with the driver, plugins, rules files, and webserver locked; the kmod driver and `http_output` are refused. Probes on `/healthz` (8765); `/metrics` through `kix.monitor`. Evaluation refuses a cluster whose capabilities set `daemonSets` or `privilegedContainers` to false (GKE Autopilot).
- **`contracts.gateway`**: the `out` of a `gateway` provider (`gatewayRef`, `listeners`, `podSelector`, `podNamespace`), in `kix/lib/vocab/gateway.nix`. `check` holds envoy-gateway and traefik to every field; `kix.expose` requires `gatewayRef` and checks the rest, and writes the backend policy from `podSelector` when it is set. `checks.gateway-swap` builds File Browser on each implementation and requires the same manifests but for the HTTPRoute's parentRef.
- **`contracts.postgresDatabase`**: the `out` of a `database` provider (`host`, `port`, `database`, `credentials`, `username`, `extensions`, `tls`), in `kix/lib/vocab/postgres-database.nix`. `check` holds a provider package to every field (`stackgres-database` and `cnpg-database` use it); `assertions` holds a consumer's `deps.database` to the connection fields and the shape of the rest (harbor, immich, keycloak, metabase, n8n, vaultwarden), so a `kix.mkImport` database needs only `host`, `port`, `database`, and `credentials`.
- **`contracts.oidcProvider`** and **`options.oidc`**: the `out` of an OpenID Connect provider (`issuerUrl` and `endpoints`, each a function of a realm name), in `kix/lib/vocab/oidc-provider.nix`. `check` holds `keycloak` to both; `assertions` holds a consumer's `deps.oidcProvider` to `issuerUrl`. `kix.options.oidc { scopes; autoLogin ? null; }` is the `oidc` option of grafana, harbor, and immich (`enabled`, `realm`, `scopes`, `autoLogin`); with it on, each reads the provider and an `oidcClient` secret (keys `clientId`, `clientSecret`) and refuses a missing one through `requireClient`. Keycloak answers no alias, so the cluster wires `deps.oidcProvider = ref.<ns>.<instance>`. `clusters/test-keycloak-oidc.nix` wires all three.
- **`contracts.otlpEndpoint`**: the `out` of an `otlp` provider (`otlpGrpcUrl`, `otlpHttpUrl`, each `scheme://host:port` with no path, and `tls`), in `kix/lib/vocab/otlp-endpoint.nix`. `check` holds a provider to every field (`tempo`, `otel-collector`); `assertions` holds a consumer's `deps.otlp` to the two URLs, so a `kix.mkImport` endpoint may omit `tls`.
- **`tempo` package**: Grafana Tempo in single-binary mode on a `storage` claim, with OTLP receivers on a `<name>-otlp` Service and the query API on `<name>` (`out.queryUrl`). Answers `tempo` only, so a sender names it with `deps.otlp = ref.<ns>.<instance>` or the cluster adds the `otlp` alias. Typed `retention` (Prometheus duration grammar); `settings`, `extraArgs`, and `env` escape hatches with locked paths and flags. Optional `objectStorage` (`bucket`, `endpointScheme`, `credentialKeys`) moves trace blocks to S3 under the prefix `<namespace>/<instance>`, with the keys from a `storageCredentials` dependency as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` and the store from an `endpointService` dependency (derived policy) or `settings.storage.trace.s3.endpoint` (a world egress rule on its port); credentials in `settings` or flags (the SSE-C key included), an endpoint with a scheme, and one whose host ends in `.svc` or is a single label are refused, as are `endpointService` without `objectStorage` and generator processors in `settings` while the generator is off. `metricsGenerator.enabled` runs the `service-graphs` and `span-metrics` processors and remote-writes to the `prometheusServer` dependency's `out.remoteWriteUrl` (victoria-metrics-cluster). Grafana's optional `tempo` dependency wires a datasource with uid `tempo`, with `loki` a span-to-logs link on the `namespace` and `pod` labels, and with `prometheusServer` a service map on the Prometheus datasource.
- **`mkEnv`** — Combine named env vars with raw K8s env entries (e.g. valueFrom.secretKeyRef).
- **`parseQuantity`**: Kubernetes quantity to millicores (cpu) or bytes, rounded down, as an integer; `null` when invalid; a value outside the signed 64-bit range throws. One grammar with `kix.types.quantity`.
- **`types.quantity`**: option type for a Kubernetes quantity (non-negative decimal or integer, optional suffix; no sign or exponent).
- **`types.storageClass { provisioner ? true, parameters ? attrsOf str, defaults ? { } }`**: StorageClass v1 fields as a typed submodule (`provisioner`, `parameters`, `reclaimPolicy`, `volumeBindingMode`, `allowVolumeExpansion`, `mountOptions`, `allowedTopologies`, `labels`, `annotations`). **`storage.mkClasses`** renders them and picks `storageClassName`, the class a consumer that names none gets (the single class annotated default, else the only class), taken from the package's own class parts (`parts = self.<part>`) so consumers depend on the class (`vocab/storage-class.nix`).
- **`options.resources`** / **`options.env`**: typed container `resources` (defaults on fields, unset fields absent) and extra env (`attrsOf (nullOr (str or valueFrom))`), rendered through `kix.mergeEnv`.
- **`service.extractPorts`** — Extract service ports from a workload's container spec.
- **`service.fromWorkload`** — Create Service attrset from a workload. Auto-derives selector, ports, outputs.
- **`ingress.fromService`** — Create Ingress attrset from a service. Auto-derives backend name/port.
- **`httpRoute.fromService`**: Create HTTPRoute (Gateway API) attrset from a service. Takes parentRef. Build it with `scope.mkCR` from a `scope.mkCRDRef` for HTTPRoute.
- **`mount.pvc`** — PVC volume mount. Auto-derives name from resource.
- **`mount.configMap`** — ConfigMap mount with optional items, defaultMode, subPath, readOnly.
- **`mount.secret`** — Secret mount with optional items, defaultMode, subPath.
- **`mount.emptyDir`** — EmptyDir mount with optional medium, sizeLimit.
- **`withMounts`** — Inject mounts into single-container pod spec (pre-seal). Errors on multi-container.
- **`withMountsOn`** — Inject mounts into a specific container by name.
- **`image.ref`** — Render a container image reference: `repository:tag`, plus `@digest` when the reference carries one. The tag is what a person reads; the digest is what the runtime pulls, and a tag can be moved after it is read.
- **`image.isPinned`** — Whether a reference names a digest.
- **`pins`** — Read a committed pin file: `kix.pins ./pins.json` returns `{ get, ref, keys, all }`. Normally the path is declared once as `mkFlake { pins = ./pins.json; ... }` and a cluster definition takes a `pins` argument instead of naming the file. `get "<key>"` shape-checks the pin and throws a message naming `kix pin set ... --init` when the key is absent, which is the state a fresh checkout hits. A pin holds `{ repository, tag, digest?, sourceRev?, promotedBy?, resolvedAt?, note? }`. JSON rather than Nix because reading a Nix file means evaluating it and writing one means hand-escaping registry strings into a programming language; the eval cache fingerprints `.json` alongside `.nix`, so nothing is lost. `note` is declared on `kix.options.image` beside the other record-keeping fields, so it passes through untouched and never reaches a manifest. Written by `kix pin` (`v2_discussions/archive/138`).
- **`options.image`**: Reusable NixOS option set for a package's image (repository, tag, digest, pullPolicy, and the promotion fields), so every package spells the digest slot the same way and `kix pin` always has somewhere to put a resolution. Kix-native packages declare their image options this way and render them with `kix.image.ref`; Helm-imported packages take images from chart values. `pullPolicy = null` leaves `imagePullPolicy` to Kubernetes, and an instance that sets some fields keeps the package's defaults for the rest. The package's digest is kept while `image.tag` equals the package's tag and dropped when the tag changes. `tagText` names the expression the option reference shows as the tag's default when the package's `config` sets the tag from another option (cert-manager's components follow `image.tag`). The follower's declared `tag` must equal the main tag's, bound once in the package's `let`; the kix/lib test t128 checks every shipped package's `config` leaves its declared images unchanged. A package that runs the user's image calls `kix.options.image { }`: a null `repository` or `tag` leaves that field without a default, so the instance must set it and evaluation names the missing option otherwise.
- **`options.ingress`** — Reusable NixOS option set for ingress (host, annotations).
- **`options.monitor`** — Reusable NixOS option set for monitoring (enabled, interval).
- **`expose`**: Build entry: auto-creates Ingress or HTTPRoute based on which DI dep is present (gateway vs ingressNginx); `paths` gives several backends behind one host in either mode (`httpRoute.fromPaths`, one rule per path). Derives the host `<instance>.<cluster.domain>` when `config.ingress.host` is null, unless `deriveHost = false`, which routes the instance only when `ingress.host` is set. TLS via clusterIssuer. Errors if both gateway and ingressNginx are wired; an instance merely named `gateway` that publishes no `out.gatewayRef` and does not answer the `gateway` alias counts as no gateway (`kix.contracts.gateway.claims`). With network policy on, also emits one policy per backing Service opening its pod port to the router's pods, read from the ingress controller's or the gateway's `out.podSelector` / `out.podNamespace`: `<svc>-from-ingress-controller` or `<svc>-from-gateway`. A router that publishes no selector gets a warning and no policy (envoy-gateway publishes null). Returns parts `route` (Ingress/HTTPRoute, `partName`) and `exposure` (`{ via; host; scheme; url; }`, `exposurePart`); in Gateway mode the scheme and port come from the listener the route attaches to, and the route is built from the CRD ref part `<partName>Crd`.
- **`monitor`**: Build entry: auto-creates ServiceMonitor + optional PrometheusRule when prometheus DI dep is present. Configurable port, path, scheme, tlsConfig and params (primary endpoint), scrapeInterval, alert rules (expr, for, keep_firing_for, severity, description, summary, runbook_url, labels, annotations; other keys are ignored), extraEndpoints (each defaults to http, /metrics, and the instance's interval), extraLabels; `name`, `monitorPart`, `rulesPart` let one package call it once per metrics Service (harbor).
- **`alerts`**: Build entry: the PrometheusRule `<name>-alerts` alone, same alert fields and conditions as `monitor`, for packages scraped through a PodMonitor or an operator; `name`, `extraLabels`, `rulesPart`.
- **`types.promDuration`**, **`durations.toSeconds`**, **`durations.fromSeconds`**: A Prometheus duration option type ("90s", "1h30m", units ms to y), its value in whole seconds (throws on anything else), and seconds back to a duration in whole hours, else minutes, else seconds ("50h", "90m"), for alert thresholds.
- **`schedules.period`**, **`schedules.staleAfter`**: The longest gap between two runs of a cron line in seconds (descriptors, `@every`, five or six fields, an optional `CRON_TZ=`/`TZ=` prefix; null for a line that restricts the day of the month or the month), and two periods plus two hours as a duration, the default threshold of a last-success alert (cnpg-cluster, velero).
- **`healthCheck`**: build entry, a post-deploy probe Job in the package's namespace running a script (Python by default, `runtimes.python` pinned by digest; `runtimes.shell` on curl) from a stable-name ConfigMap against addresses passed as env vars from `out.*` values and `deps`. Addresses carry the edges (ordering, netpol egress); the Job always waits for the package root too. The helper owns the time budget: `RETRY_FOR` in the env, `activeDeadlineSeconds` sized from it (`roundBudget` 90 s), a shorter given deadline fails the build. Callbacks all take `{ self, config, deps }`; `when`/`retryFor` default to the package's `kix.options.healthCheck` fields (`enabled`, `retryFor`). Stamped `kix.run/rerun: on-change`: `kix deploy` and `kix rollback` recreate the Job when its identity hash changed or the live Job failed; the operator only on a change (and after the TTL reaped it, since it diffs against live objects). Failure output is shown in the deploy. Own pod labels, non-root, read-only root, no token.

### RBAC DSL (`rbac.nix`)

- **`group(apiGroup, resources)`** — Named resource refs with `__functor` fallback.
- **`core`** — Pre-populated group for core API ("") with: configmaps, pods, secrets, serviceaccounts, services, endpoints, namespaces, nodes, persistentvolumeclaims, events, etc.
- **Ref modifiers:** `restrictTo(names)`, `sub(suffix)`.
- **Intents (Ref → [Rule]):** `watch`, `reconcile`, `finalize`, `own`, `readWrite`, `full`, `emit`, `watchAndFinalize`, `allow(verbs)`.
- **`grant`** — Flatten and merge rules by apiGroups+verbs+resourceNames.
- **`mkClusterRoleSet`** — Creates ClusterRole + ClusterRoleBinding pairs.
- **`mkRoleSet`** — Creates Role + RoleBinding pairs.
- **Vendored operator roles**: a package may keep upstream ClusterRoles/Roles under `<pkg>/rbac/*.json` (`scripts/vendor-crds.py`, `rbac/sources.txt` with `Kind/name` selectors) and pass their `rules` to the role sets (kubevirt, cdi).

### Helm Bridge (`helm.nix`)

- **`fetchHelmChart`** — Fixed-output derivation: fetch chart from OCI or HTTP registry. Params: repo, name, version, hash.
- **`helmTemplateDerivation`** — IFD derivation: `helm template` → JSON array. Params: chart, releaseName, namespace, values, includeCrds, includeHooks, extraFlags.
- **`wrapHelmResource`** — Wrap single parsed JSON resource into kix resource via scope. Strips Helm annotations/labels, handles foreign namespaces, injects Secret type "Opaque" default, cleans default strategy/updateStrategy.
- **`helmChart`**: Main entry: import Helm chart as kix package: `{ repo, name, version, hash, releaseName?, root?, includeCrds?, strip?, patchResources?, metaExtra? }`. Returns `{ meta, options, build }`. Config-level `values` deep-merged with package-level `values`. Root: `root = { kind; name; }` when given, else the only Service, else the only Deployment/StatefulSet/DaemonSet; anything else fails evaluation with the candidates (`helm-dag.nix` `pickRoot`). Supports `patchResources` (pre-wrap transform), filters test hooks, expands List resources.
- **Chart CRDs**: `helm-dag` adds an `instance-of` edge from a chart custom resource to the chart's own CRD of its group and kind.
- **`isClusterScopedKind`** — Check against the built-in cluster-scoped kinds (`builtInClusterScopedKinds` in `eval/helpers.nix`, 19 kinds).

### CRD Builders (`crd.nix`)

Pipeable CRD spec construction:
- **`fromKind`** — Auto-derives plural, singular, listKind. Defaults: Namespaced, v1, permissive schema, status subresource.
- **`clusterScoped`**, **`withVersion`**, **`withShortNames`**, **`withCategories`**, **`withPrinterColumns`**, **`withSchema`**, **`withLabels`**.

### Network Policy Generation (`plugins/netpol/`)

Internal helpers: `mkServiceRegistry` (service discovery index), `extractServiceEdgesFromJson`, `portsToCilium`, `dnsEgressRule`, `apiServerEgressRule`.

Auto-derives CiliumNetworkPolicy from the DI graph:
- **Auto-detected egress:** API server access (precise — only workloads whose SA is subject of a RoleBinding/ClusterRoleBinding), DNS, cross-package service egress, self-communication (StatefulSet).
- **Auto-detected ingress:** Emitted caller-side at `scope.mkDeployment` time — paired ingress CNP in the callee's namespace via `scope.forNamespace` (v2_discussions/83 Phase C). No cluster-level inverted-ingress pass.
- **Default deny:** Per-namespace, configurable directions (ingress/egress/both). One empty rule per direction, which is the form cilium 1.19 accepts.
- **Package intents:** `meta.network.intents.<name>.{ingress,egress}` for edges the graph cannot see; sources `world`/`all-pods`/`apiserver`, targets `world`/`all-pods`/`apiserver`/`dns` (HANDBOOK §16.5). An egress rule to `world` may name `entities` (Cilium entity names; default `[ "world" ]`). A package's intents apply to every workload it renders.
- **Ingress-controller edge:** derived by `kix.expose`, not by the netpol plugin — it is the one place that holds both the backing Service and the controller dep. One policy per backend, the Service's pod port only.
- **Provider load-balancer classes:** a provider publishes its class as `kix.providedLoadBalancerClass { class; by; }` (`core/markers.nix`; tailscale's `out.loadBalancerClass`): the class string with a marker and the context of `by`, the resource that serves it. A LoadBalancer Service whose `loadBalancerClass` carries the marker and equals the class it records skips the `loadBalancer` role check and gets no external-ingress supplement; the provider's builder (`out.mkBackendPolicy`) opens the backend instead. Any other class, with or without string context, gets both.
- **Operand policies:** pods an operator creates from a custom resource get their policies from the package that writes the CR (`kix.operandPolicy`), selected by the operator's `out.operandSelectors`. The derived `cr-operand` egress and caller-ingress policies of a terminate-declared CR do not require the CR, because the CR's readiness can need the connection they open.
- **Scrape policies:** the netpol cluster processor joins each Prometheus CR with the ServiceMonitors, PodMonitors, and Alertmanagers it selects and emits `<name>-scrape-egress` for the server pods plus `<ns>-<name>-scrape-<target>-<hash>` ingress at each target (`kix/lib/plugins/netpol/scrape.nix`, HANDBOOK §16.8). Egress rules carry numeric ports only (host-network targets through the enforcer's `mkHostNetworkEgressRule`); a port name no Kix workload declares stays on the ingress rule and gets no egress. Without default deny, target ingress lands only where another policy (a Kubernetes NetworkPolicy too) already isolates every pod behind the target, matched against the pods' own labels, or implied by the target selector for pods Kix did not build. A port name two Kix workloads declare with different numbers gives rules on both. A target port name no Kix container declares, a PodMonitor with `matchExpressions`, and a Prometheus CRD without `factBehavior.podSelector` fail evaluation under default deny and are warnings without it. The prometheus package opens DNS and the API server for its pods.
- **Numeric ports:** `kix.service.fromWorkload` resolves a named `targetPort` to the container port number, and `portsToCilium` warns on a name, because cilium drops egress on a named port. `mkCallerIngressRule` passes a name through, since cilium resolves names on ingress.
- Warnings for hostNetwork and Helm opacity (intra-package edges may be missing).

### Fragment Composition (`fragments.nix`)

- **`mergeFragments`** — Merge multiple fragments with collision detection. Instance collision = error. Namespace configs deep-merged (leaf conflicts = error). Platform-owned policies applied on top.
- **`deepMergeNs`** — Recursive namespace config merge.

### Scorecard / Policy Engine (`scorecard.nix`, `rules/`)

- **Rule levels:** manifest, package, namespace, cluster.
- **Severities:** error, warning, info.
- **Override chain:** per-rule > per-owner > per-namespace > rule default > cluster default.
- **`buildScorecardReport`** — Aggregate findings into structured report.
- **`scorecardToWarnings`** — Convert findings to kix diagnostics (errors → assertions, warnings/info → traces).

#### Built-in Rules

**Security:**
- `nonRoot` — Containers must run as non-root (error, CIS).
- `noPrivileged` — No privileged containers (error, CIS).
- `readOnlyRootfs` — Read-only root recommended (warning).
- `noHostNetwork` — No hostNetwork/hostPID/hostIPC (error, CIS).
- `noClusterAdmin`: no ClusterRoleBinding to `cluster-admin` and no all-wildcard ClusterRole (error, CIS 5.1.1); the `cluster-admin` grant exempts a package.
- `noLatestTag` — No `:latest` or untagged images (warning).
- `noUnresolvedPlaceholder` — Image references must not carry `REPLACE_ME`, `CHANGEME`, `PLACEHOLDER`, `TODO`, `FIXME`, `XXX` or an unexpanded `${...}` (warning; promote to error in a cluster that deploys something you care about). A ratchet, not the fix: a predicate over spelling cannot tell you `sha-typo12` is wrong. What closes the class is a resolved digest checked against a registry (`kix.pins` plus `kix pin check`). Its one job is to make the known placeholders unwriteable again (`v2_discussions/archive/138`).
- `hasNetworkPolicy` — Workload namespaces need at least one network policy: a NetworkPolicy or any kind the network-policy-enforcer provider lists in `out.netpol.policyKinds` (warning).

**Reliability:**
- `hasResourceLimits` — Every container needs limits (warning).
- `hasResourceRequests` — Every container needs requests (warning).
- `hasProbes` — Liveness + readiness probes (warning).
- `gracefulShutdown` — terminationGracePeriodSeconds set (info).

**Governance:**
- `hasOwner` — meta.owner required (warning). Every package in `kix/packages/` declares one (`platform` or `app-team`).
- `hasDescription` — meta.description recommended (info).
- `labelStandards` — Standard K8s labels on workloads (info).

**Architecture** (v2_discussions/128):
- `annotationDomainOwnership` — annotations under an operator-declared domain (`meta.annotationDomains`) require a dependency on the declarer, direct or transitive; undeclared domains warn as dead annotations (warning).
- `distinctWorkloadSelectors` — one workload's selector must not also match another workload's pods (error).
- `consistentPortNames` — one port name must mean one number across an instance's workloads (warning). A vendored chart can carry the clash, so it reports rather than fails.
- **Cluster DNS under `always` enforcement**: the cilium package emits one CiliumClusterwideNetworkPolicy allowing every pod in the cluster egress to kube-dns, because `policyEnforcementMode = "always"` puts pods Kix never renders into default deny too. `config.clusterDnsEgress = false` to write it yourself. Emitted only when the effective `policyEnforcementMode` is `always` (the default when `networkPolicy.enable`) and the instance installs or configures Cilium. Under the same condition the package also emits CCNP `cilium-health-probes`, which lets Cilium's health endpoint reach and be reached from the `health` and `remote-node` entities, so inter-node health probes keep working.
- `unsafeGrants` — audit listing every `meta.unsafe` grant (info).
- `untrackedReferences`: audit listing every name declared external with `kix.untrackedRef` that does not name its creator, with `kind` and `by` or with `by = "self"` (info). A bare untracked reference claims something else creates the object; nothing checks that anything does, so the claims are collected where a reviewer sees them together. A name is left out only when every reference to it in that namespace names its creator: a `kind` and `by` reference is ordered after the creator and awaited at deploy, and a `by = "self"` reference is made by the resource that holds it, provided no other resource in the cluster carries a self reference to the same name.
- `selectorCoherence` — Service selectors must carry store-path context (warning).
- `fqdnWithoutContext` — `*.svc` FQDNs in workloads must carry store-path context (warning).
- `clusterDomainLiteral`: on a cluster whose `clusterDomain` is not `cluster.local`, rendered strings (outside CRDs) must not name `cluster.local` (cluster-level, error).
- `monitorSelectorMatchesService` — ServiceMonitor/VMServiceScrape selectors must match some Service's metadata labels (cluster-level, error). Opt-out for operator-created targets: `kix.run/monitors-external-service` annotation.
- `externalMonitorTargets` — audit listing every monitors-external-service claim (info).

### Package Metadata & Diagnostics (`meta.nix`)

- **Version system** (`core/version.nix`, internal): `isVersion`, `tryParse`, `parse`, `compare`, tri-state `atLeast`/`atMost` (constraint precision, null for unknown). Grammar `[v]N(.N)*[-suffix][+build]`; a suffix is a prerelease only for Kubernetes's tags (`alpha`, `beta`, `rc`, `pre`, `dev`, `preview`). A `meta.k8s` or `meta.compatibleWith` constraint that does not parse fails; an unknown or less precise version warns and skips the check.
- **`peekPackageMeta`** — Extract meta without full evaluation (function, inline, import).
- **`peekPackageAliases`** — Get resolution aliases from available entry.
- **`effectiveAliases`** — Instance aliases override package defaults.
- **`checkMetaStatic`** — Pre-build assertions: K8s version compat, dependency version compat, conflicts, unknown `meta.unsafe` grants.
- **Unsafe grants** (`unsafe.nix`): closed vocabulary of structural-rule escapes: `raw-pvc`, `host-network`, `privileged`, `run-as-root`, `cluster-admin`. Raw PVCs outside a granted package are an eval error (`scope/validators.nix#checkRawPvc`); the other four suppress `security.noHostNetwork`, `security.noPrivileged`, `security.nonRoot`, and `security.noClusterAdmin` for the declaring package, so a CNI or node agent declares what it is instead of the cluster downgrading the rule for its whole namespace.
- **Object-name validation** (`scope/validators.nix#checkResourceName`): Checks names during evaluation because the Kubernetes OpenAPI schema leaves `metadata.name` unconstrained. Services require an RFC 1035 label, Namespaces require a DNS-1123 label, CronJobs require a DNS-1123 subdomain of at most 52 characters (the controller appends an 11-character suffix to Job names), and other resources require a DNS-1123 subdomain. RBAC resources are exempt because the API server validates their names as path segments.
- **Ceded fields** — `ownership.cede = [ "spec.versions" ]` on any resource (and `scope.mkCRD`) names fields another controller takes over after creation; stamped as `kix.run/cede-fields`, and `kix deploy` retries an apply that conflicts only on those paths without them (`cli/kix/src/cluster/apply.rs#without_ceded_conflicts`).
- **Pod Security level** — `meta.podSecurity = "privileged" | "baseline" | "restricted"` is what a package's pods need; the namespace carries `pod-security.kubernetes.io/enforce` at the most permissive level its instances need, `namespaces.<ns>.podSecurity` sets it by hand, and a hand-set level stricter than an instance needs is an eval error (`eval/cluster.nix#namespacePodSecurity`).
- **Annotation domains** — `meta.annotationDomains` declares operator-owned annotation prefixes; duplicate declarers are an eager eval error (`eval/hooks.nix#buildAnnotationDomainIndex`).
- **Derived pod spread and PDBs**: `hooks.workloadInterceptors.availability` patches `topologySpreadConstraints` into every multi-replica Deployment/StatefulSet pre-seal (the `podSpec` hook channel, author wins per field); `hooks.instanceProcessors.availability` emits a PDB unless the package wrote one over the same pods, and warns when a workload that placed itself has no PDB over its pods. `validators.checkSpreadFeasible` refuses hard hand-written placement rules on `multiNode = false`. `availability.max` on a workload builder call (`scope.mkDeployment { availability.max = "none"; }`) caps that workload alone, where `meta.availability.max` caps the instance; the sealed workload carries `_availability` so the processors judge it at its own level. `_availability` also carries the effective ceiling (the lower of builder and package) and its source; more than one replica of a Deployment or StatefulSet under an effective ceiling of `none` is an evaluation error. Builder `availability` takes only `max`, a level, and is refused on `mkDaemonSet`. Under `meta.availability.max`, `kix.availability.atLeast` refuses a threshold above the ceiling; `meta.availability` keys other than `max` are an error.
- **Conflict detection:** `conflictsWith = [ "alt-pkg" "cluster:alt-cni" ]`; a plain entry excludes the package in the same namespace, a `cluster:` prefix cluster-wide. A `cluster:` entry naming one of the package's own keys marks it one per cluster, which auto-instantiation also reads.
- **`evaluatePackageDiagnostics`** — Call package-declared warnings/assertions functions.
- **`combineDiagnostics`** / **`collectClusterDiagnostics`** — Merge and enforce diagnostics.

### Environment Stamping (`env.nix`)

- **`mkEnv`** — Stamp instance sets into env-prefixed namespaces (dev/staging/prod). Namespaces become `"${envName}-${setName}"`. Per-instance overrides via `overrides.${setName}.${instName}`. The namespace prefix is the only isolation: auto-instantiated plain deps follow the requesting namespace, while role providers and packages pinned via `namespace`/`autoNamespace` are shared across environments.

### Cluster Module Options (`modules.nix`)

- `clusterLabels` — Labels injected into every resource.
- `clusterDomain` — DNS domain for FQDNs (default: "cluster.local").
- `instances` — Nested attrset: package, aliases, config (deferredModule), deps, partsOverlays, version, labelStyle, selectorLabels, optional.
- `availablePackages` — Package registry for auto-instantiation.
- `autoNamespace` — Default namespace for auto-instantiated packages.
- `namespaces` — Per-namespace: labels, annotations, resourceQuota, networkPolicies.
- `globalPartsOverlays` — Parts overlays applied to ALL instances.
- `k8sVersion` — Target K8s version for meta compatibility.
- `cluster.provider` — Distribution identifier.
- `cluster.capabilities` — 8 three-valued substrate axioms: multiNode, availabilityZones, nodeAutoscaling, managedControlPlane, gpu, privilegedContainers, podSecurityEnforcement, daemonSets.
- `cluster.roles` — environment binding modes per registry role (`kix/lib/eval/roles.nix`): absent | shadowable | exclusive.
- `cluster.network`: podCidr (the cilium chart's cluster-pool IPAM pool; kind, k3s, and rke2 flavours default it), serviceCidr, dnsUpstream (read by the coredns forward plugin; empty means /etc/resolv.conf). An environment-installed Cilium is the `platform-cilium` import (the rke2 flavour declares it), which the `cilium` package takes as a dependency.
- `cluster.containerd`: the nodes' containerd `socket`, `registryConfigPath` (CRI `config_path`), `contentPath`, and `discardUnpackedLayers` (null = unknown). Defaults are containerd's paths; the Talos and GKE flavours move `registryConfigPath`, k3s and RKE2 set all three paths, and kind, Talos, EKS, and GKE set `discardUnpackedLayers = true` (AKS, Scaleway, k3s, and RKE2 false). Read by `spegel`.
- `cluster.flavor.rke2.cni`: the `cni` list of RKE2's server config (default `[ "canal" ]`); binds the `cni` role (canal, calico, and flannel exclusive; cilium shadowable, with the `kube-system/platform-cilium` import naming HelmChartConfig kube-system/rke2-cilium; none absent). The rke2 flavour also defaults `cluster.network.podCidr` to RKE2's cluster-cidr, 10.42.0.0/16.
- `cluster.nodes` — Static node inventory (roles, cpu, memory, labels, taints).
- `cluster.availability.default`: The largest failure a workload must survive: `none` | `pod` | `node` | `zone`, derived from the capabilities when unset and capped by them. `instances.<ns>.<inst>.availability` overrides per instance; `meta.availability.max` is the warned package ceiling (validated; `none` means one pod at a time and refuses more than one replica; the package's `pick` and `atLeast` refuse mappings above it); `cluster.availability.substrate` is the read-only derived maximum. Packages receive the level as their `availability` argument and map it with `kix.availability.pick` / `atLeast`; `kix.availability.spreadConstraints` gives operator-placed operands the derived spread rule. Spread strictness and PDBs derive from it. (`kix/lib/plugins/availability/module.nix`, v2_discussions/145)
- `cluster.topology.zoneKey`, `cluster.topology.hostKey` — The node labels that name a zone and a node. Default to the well-known `topology.kubernetes.io/zone` and `kubernetes.io/hostname`; a hand-labelled substrate sets its own, a flavor may `mkDefault` them.
- `cluster.topology.failureDomainKeys` — Read-only: the topology keys pods spread across, computed from `capabilities.availabilityZones`, `multiNode` and the two keys above. Operator-CR packages read it through `clusterConfig`.
- `scorecard`: enable (default on), rules (default `kix.rules`), maxSeverity (default `warning`: findings are capped there, so nothing fails until a cluster raises it to `error`), ruleDefaults, ruleOverrides, knownAnnotationDomains. `mkFlake { clusterModules = [ ... ]; }` prepends modules to every cluster in a flake; this repository's flakes raise the cap with it. Packages read a rule's resolved severity with `kix.scorecard.effectiveSeverity { clusterConfig; rule; namespaceName; owner ? null; }` (null when the rule does not run), to fail with option-specific advice (`initChownData` in vaultwarden and immich). (`kix/lib/vocab/default.nix`)
- `networkPolicy` — enable, defaultDeny, directions.

### Cluster Flavors (`flavors/`)

12 distribution profiles, each sets provider, capabilities, and platform imports:

| Flavor | Provider | Key traits |
|---|---|---|
| `k3s` | k3s | loadBalancer (servicelb), flannel CNI, traefik ingress, local-path storage, `metricsApi` exclusive (packaged metrics-server) |
| `kind` | kind | Single-node, no loadBalancer, ephemeral storage, kindnet CNI, `metricsApi` absent |
| `kubeadm` | kubeadm | Vanilla upstream, minimal defaults, CNI null |
| `eks` | eks | Managed control plane, aws-vpc-cni; no storage import (the EBS CSI driver is an add-on, `storageClasses` is absent) |
| `gke` | gke | Managed, Cilium-based CNI (k8s-only policies), gce ingress, volume snapshots |
| `gke-autopilot` | gke-autopilot | Fully managed, no privileged containers, no daemonSets, nodeAutoscaling |
| `aks` | aks | Managed, azure-cni, managed-csi storage, volume snapshots |
| `openshift` | openshift | SCC restricted-v2, no privileged, ovn-kubernetes CNI, HAProxy router |
| `rke2` | rke2 | Canal CNI by default (`cluster.flavor.rke2.cni` selects canal, calico, cilium, flannel, or none; cilium adds the `platform-cilium` import); platform intents for RKE2's kube-system pods under network policy; `snapshotController` exclusive with a platform import; `metricsApi` exclusive (rke2-metrics-server) |
| `scaleway` | scaleway | Kapsule: managed, Cilium CNI (environment-owned), Scaleway block storage (`sbs-default` import), paid load balancer |
| `ovh` | ovh | Managed Kubernetes: Canal CNI (environment-owned), Cinder block storage (`csi-cinder-high-speed` import), paid load balancer |
| `talos` | talos | Immutable OS, no SSH/shell, flannel (often replaced with Cilium) |

### Monitoring Module (`modules/monitoring.nix`)

Declarative native Prometheus stack. Options under `monitoring`:
- `enabled`, `namespace` (default: "monitoring-system")
- `operator.enabled`
- `prometheus`: enabled, retention, retentionSize, scrapeInterval, storage.size (the class comes from the instance's `storageClasses` dependency)
- `alertmanager`: enabled, settings (alertmanager.yaml; its receivers decide the Alertmanager pods' world egress ports, and an inline credential is refused in favour of its `_file` form)
- `nodeExporter.enabled`, `kubeStateMetrics.enabled`
- `defaultRules.enabled` (rule groups and monitors are toggled on the `default-rules` instance's config)
- `grafana`: enabled, persistence (enabled, size, storageClassName), datasources. Grafana needs a `grafanaAdmin` secret (keys `admin-user`, `admin-password`) in the namespace; its route and `root_url` come from `kix.expose`, and it has a route only when the `grafana` instance sets `ingress.host` (its unauthenticated `/metrics` is on the same route)
- `loki.enabled`, `loki.storageSize` (Kix-native single-binary Loki in the monitoring namespace on the claim instance `loki-storage`; tune it through `instances.<ns>.loki.config.settings`; Grafana gets the datasource by DI)
- `lokiLogs.enabled` (loki-logs, a Kix-native Vector agent at the monitoring-log-shipper PriorityClass; defaults to loki.enabled)

### VictoriaMetrics packages (`kix/packages/victoria-metrics-*`)

Four native packages, an alternative backend for the same monitoring surface
rather than a second one.

- **`victoria-metrics-operator`** — the operator plus its complete CRD bundle
  (all 25 kinds from the upstream chart; the operator crashes at startup on a
  missing indexed kind, so an eval-time throw guards the floor). Ships the
  ServiceMonitor and PrometheusRule CRDs and claims the `prometheus` DI
  alias, so every existing `kix.monitor` consumer
  works unchanged and the operator converts the results to VMServiceScrape
  and VMRule. Exposes the same `out.mkServiceMonitor` builders as
  `prometheus-operator`. On a cluster that already runs prometheus-operator,
  those four CRDs already exist and applying a second version of them fails on
  a field-ownership conflict; `prometheusOperatorCRDs = "reference"` emits
  import markers that wait for the real ones instead, leaving the builders
  unchanged. `convert.<kind>` turns each of the six
  converters on or off, for the case where the VM side has no consumer for the
  result. The compat CRD set is derived from it, so a converter can never run
  without its CRD (which is a crashloop, not a config error); the four kinds
  with an `out.mk*` builder keep their CRD either way, and `scrapeConfigs` and
  `alertmanagerConfigs` default off because enabling one installs a CRD. The kinds with a consumer surface carry the real
  upstream spec schema, vendored under the package's `crds/` by
  `scripts/vendor-crds.py` from `crds/sources.txt`, so a mistyped field is refused at apply
  time; the kinds that exist only to satisfy the operator's startup indexers
  keep the slim stub.
- **`victoria-metrics-cluster`** — the VMCluster CR. HA defaults live in the
  package because the scorecard cannot lint operator-created pods:
  replicationFactor 2, three vmstorage, PodDisruptionBudgets, preferred
  hostname anti-affinity, `useStrictSecurity`, and `-dedup.minScrapeInterval` pinned to the scrape
  interval (the operator's 1 ms fallback covers replication twins, not an HA
  vmagent pair). `out.remoteWriteUrl` (the full Prometheus remote-write URL,
  read by `victoria-metrics-agent` and by Tempo's metrics generator),
  `out.insertBaseUrl`, `out.serviceUrl`, and `out.scrapeInterval` carry the
  wiring.
- **`victoria-metrics-agent`** — the VMAgent CR, remote-writing to the
  cluster's insert URL and defaulting its scrape interval from
  `vmCluster.out.scrapeInterval`.
- **`victoria-metrics-alert`** — the VMAlert and VMAlertmanager CRs. The
  notifier is operator-side discovery: VMAlert selects the VMAlertmanager CR
  by label and the operator expands it to every replica's pod FQDN, so this
  is alertmanager HA fan-out rather than a load-balanced Service.

Readiness is declared, not hardcoded: the operand CRDs carry
`readiness = { path; equals; }` (`status.updateStatus == operational`), and
the configuration CRDs (scrapes, VMRule, VMAlertmanagerConfig, VMUser), whose
status only a selecting VMAgent, VMAlert, VMAlertmanager or VMAuth writes,
carry `readiness = { path; notEquals = "failed"; }`, which the CLI evaluates
generically. Controllers that report a condition instead
declare `readiness = { condition = { type; status; }; }`; a boolean or
number status field compares by its JSON text (`readiness = { path = "/status/applied"; equals =
"true"; }` for CloudNativePG's Database). StackGres clusters
(`Bootstrapped=True`), Gateway API (`Accepted=True` for a GatewayClass,
`Programmed=True` for a Gateway) and Cilium policies (`Valid=True`) all use
this form, so the CLI holds no per-operator condition list.

### Operator and platform packages (`kix/packages/*`)

Kix-native packages whose `out` other packages build on. Each vendors its upstream CRDs (`scripts/vendor-crds.py`, `crds/sources.txt`) and exposes `out.crds.<Kind>` for `scope.mkCR`; operand pod labels are published as `out.operandSelectors.<operand>`.

- **`cert-manager`**: vendors all six CRDs and gates its CRD handles on the API-check Job, so every custom resource built with `scope.mkCR certManager.out.crds.<Kind>` waits for the webhook; the handles also declare each kind's readiness. `out.operandSelectors.acmesolver` (the HTTP-01 solver pods), `out.clusterIssuerSpecSchema` (the vendored ClusterIssuer `spec` schema). No `out.mk<Kind>` builders.
- **`cluster-issuer`**: one ClusterIssuer per instance, named after the instance, with one option `spec` checked against `certManager.out.clusterIssuerSpecSchema`. Deps `certManager` and `issuerCredentials ? null`; Secret key selectors without `name` are filled from `issuerCredentials.out.keyRef key`. `out.{name, withCert}`.
- **`external-secrets`**: External Secrets Operator (v2.11.0) with its 25 CRDs vendored, and the controller, webhook, and cert-controller Deployments. `out.mkSecretStore` refuses a Secret selector named by a literal string, so provider credentials come from a secret dependency's `keyRef`. `out.mkExternalSecret` sets empty `spec.target.template.metadata` so the controller does not copy Kix's annotations onto the Secret it writes, refuses generic targets (`spec.target.manifest`), and returns `out.secretRef { keys; type ? null; }` (a `mkSecretRef` ordered after the ExternalSecret, refusing creationPolicy None and keys the ExternalSecret does not write when they are known). `out.crds.<Kind>` covers ClusterSecretStore, ClusterExternalSecret, PushSecret, ClusterPushSecret, ClusterGenerator, and the generator kinds. Every custom resource built from `out` requires the webhook check Job, a server-side dry-run create that the API server admits only once the cert-controller has injected the webhook's CA.
- **`openbao`**: OpenBao 2.7 (the MPL fork of Vault), Kix-native: a StatefulSet on integrated Raft, one pod at `none` and three from `pod` up, TLS from a cert-manager CA the package creates. The default `seal.type = "static"` unseals from an `unsealKey` secret and self-initializes Kubernetes auth with a `kix-reconcile` role bound only to the reconcile Job, which writes the typed `policies`, `kubernetesAuth.roles`, and `secretsEngines` on every change and lists undeclared policies and roles in its log; `seal.type = "shamir"` is manual init and refuses those options. `out.{url, fqdn, port, caSecret}` and `out.externalSecretsProvider scope { serviceAccount; role; mount; }`, the `vault` provider of a ClusterSecretStore with Kubernetes auth, which refuses an undeclared role, a role that does not bind the ServiceAccount or its namespace, and a mount that is not a declared kv engine (HANDBOOK §21.10).
- **`infisical-operator`**: the Infisical operator (v0.11.10) with its seven CRDs vendored. `out.mkInfisicalSecret` and `out.mkInfisicalStaticSecret` pin the managed Secret's metadata so Kix's annotations stay off it, and return `out.secretRef` (a `mkSecretRef` ordered after the custom resource); `out.mkInfisicalAuth` defaults `infisicalConnectionRef` to the package's InfisicalConnection `default`, which the deploy waits on, so the first deploy proves the operator reaches Infisical. `out.crds.<Kind>` for ClusterGenerator, InfisicalConnection, and InfisicalPushSecret only: the operator would copy Kix's annotations from an InfisicalSecret or InfisicalStaticSecret built any other way onto the Secret it creates, and `kix gc` would delete that Secret. Under egress enforcement the build refuses an `address` its world:443 intent does not cover until a `networkPolicy.platformIntents` entry for the operator's pods reaches it.
- **`stackgres-operator`** `out`: `crds.<Kind>` (every stackgres.io kind but SGConfig, for `scope.mkCR`; each handle makes the custom resource wait for the webhook-check Job, which proves the operator's admission webhooks serve), `operandSelectors.sgCluster crName` (an SGCluster's pod labels), `podSelector`, `release`, `resolvePostgres { who; version; }` (`{ major; minor; images }`, throwing on `latest` or a release the table does not ship), and `kubectlImages` (the kubectl image the backup Jobs run, picked from the cluster's `k8sVersion`). The SGConfig is the `sgConfig` option, passed as SGCONFIG; the REST API, web console, and collector are off and refused. `webhookCheck.image` is the check Job's kubectl image, from the operator's registry prefix.
- **`stackgres-cluster`** `out`: `name`/`fqdn`/`port` (primary Service reference), `selector` (operand pod labels), `superuserSecret`, `extensions` (names), `tls` (`spec.postgres.ssl.enabled`), `extraImages` (operand images from `resolvePostgres`, and kubectl with backups). Backups: `backups` plus a `stackgres-object-storage` (`sgObjectStorage` alias, namespace-scoped) with a `storageCredentials` secret dependency and an optional `endpointService` dependency for an S3 store inside the cluster.
- **`cnpg-operator`** `out`: `crds.<Kind>` (Cluster, Database, DatabaseRole, ImageCatalog, ClusterImageCatalog, Publication, Subscription, ScheduledBackup, Pooler; each handle makes the custom resource wait for the webhook-check Job, a server-side dry-run create of a Cluster), `operandSelectors.cluster crName` (a Cluster's pod labels), `podSelector`, `release`. CloudNativePG 1.30 with its definitions and ClusterRole vendored from the release manifest; the operator writes `caBundle` into the webhook configurations Kix renders. One per cluster.
- **`cnpg-cluster`** `out`: `name`/`fqdn`/`port` (the `-rw` Service reference), `clusterName`, `selector` (instance pod labels), `tls` (always true), `extraImages` (the PostgreSQL image). The CloudNativePG alternative to `stackgres-cluster` for the `postgres` alias; replicas from the availability level, spread from `kix.availability.spreadConstraints` with the operator's anti-affinity off. Optional `backup` (`destinationPath`, `serverName` (the archive folder, `<namespace>-<instance>` by default), a six-field or descriptor `schedule`, `retention`, `credentialKeys`, `endpointScheme`, `extraSpec` over the ObjectStore) builds an ObjectStore through a `barmanCloud` dependency with credentials from `storageCredentials`, enables the plugin as the Cluster's WAL archiver, and adds a ScheduledBackup; an in-cluster store wired as `endpointService` gets network policy from the graph, an external one a world egress rule on its endpoint's port. A five-field crontab, an unknown `@` descriptor, an `endpointURL` naming a Service in the cluster, and `extraSpec.backup.barmanObjectStore` are refused.
- **`cnpg-database`**: the CloudNativePG alternative to `stackgres-database` for the `database` alias, with the same `out` (`host`, `port`, `database`, `username`, `extensions`, `credentials`, `tls`) and credentials Secret keys. A DatabaseRole, its basic-auth password Secret, and a Database in the cluster's namespace replace the bootstrap Job; `out.host` carries the Database, which is ready when `status.applied` is true. The `postgres-swap` flake check builds Metabase on each provider and compares its manifests. With a `cnpg-pooler` as its `postgres` dependency, the role and database go on the pooler's Cluster and `out.host` is the pooler's Service.
- **`cnpg-barman-cloud`** `out`: `mkObjectStore scope { name; spec; }` (refuses a Secret selector named by a literal string), `pluginName` (carries the plugin Deployment, so a Cluster or backup naming it waits for the plugin), `extraImages` (the sidecar). plugin-barman-cloud v0.15 with its ObjectStore definition and roles vendored from the release manifest, in the operator's namespace, where CloudNativePG discovers it by its Service; cert-manager issues the mutual-TLS certificates. One per cluster.
- **`cnpg-pooler`** `out`: `name`/`fqdn`/`port` (the pooler's Service reference), `clusterName`, `selector`, `tls`, `extraImages`: the fields `cnpg-database` reads from its `postgres` dependency. One PgBouncer Pooler of type `rw` in the cluster's namespace, session pooling by default, instances from the availability level, and network policy from the pooler pods to the instance pods derived from the `postgres` dependency.
- **`rabbitmq-operator`** `out`: `crds.RabbitmqCluster` (the handle makes the custom resource wait for the webhook-check Job, a server-side dry-run create of a RabbitmqCluster, and declares readiness on `AllReplicasReady`), `operandSelectors.cluster crName` (a RabbitmqCluster's pod labels), `podSelector`, `release`. RabbitMQ Cluster Operator 2.23 with its definition, ClusterRole, and leader-election Role vendored from the release manifest; a `certManager` dependency issues the webhook certificate and cainjector writes `caBundle` into the webhook configurations Kix renders. Optional `prometheus` dependency for the operator's metrics. One per cluster.
- **`rabbitmq-cluster`** `out`: `host`/`port` (the client Service reference, AMQP 5672), `vhost` (`settings.default_vhost`, or `/`), `credentials` (a reference to the operator's `<instance>-default-user` Secret, keys `username` and `password`), `extraImages`. One RabbitmqCluster with `replicas` from the availability level (odd only), typed `resources` and `storage`, spread from `kix.availability.spreadConstraints` with the operator's own spread off, a PodDisruptionBudget above one node, a PodMonitor on 15692, and operand network policy for epmd and Erlang distribution between its pods and the operator's management API calls. `settings` renders rabbitmq.conf lines into `additionalConfig` and refuses the listener, peer-discovery, and default-user keys and keys holding a password; `extraSpec` is merged over the spec. Namespace-scoped, because consumers read the Secret by `secretKeyRef`.
- **`velero`**: Kix-native Velero 1.18: typed location, snapshot location, schedules, and global volume policies; `cloudCredentials` and `repositoryPassword` secret deps with checked keys; `server.env`/`nodeAgent.env` through `kix.mergeEnv`; `out.crds.<Kind>` (CRs built in Velero's namespace with `scope.forService`), `out.mkBackup`, `out.mkSchedule`; network policies for the pods Velero launches and, without an `objectStorage` dependency, egress outside the cluster on the store's port; alerts for failed, missing (per schedule, `metrics.maxBackupAge` or `kix.schedules.staleAfter`; schedules built through `out.mkSchedule` share `metrics.otherSchedulesMaxAge`), and unscraped backups. Holds the `cluster-admin` unsafe grant.
- **`envoy-gateway`**: typed Gateway API `listeners` (an HTTPS listener without `tls.certificateRefs` is not rendered); `out.listeners` is what `kix.expose` reads to pick each application's URL scheme and port.
- **`traefik`**: Traefik v3.7 as a Gateway API implementation for the `gateway` alias, with the same `out` as `envoy-gateway` plus the Traefik pods' selector, so `kix.expose` opens each backend to them under network policy. Renders the Deployment, RBAC, Service (LoadBalancer, or NodePort when the loadBalancer role is absent), a GatewayClass that only this instance serves, and the Gateway; each listener port becomes an entrypoint and a Service port. Only the Gateway provider is on; `extraArgs` refuses the entrypoint, ping, metrics, and Gateway-provider flags it derives and the other Kubernetes providers, and `env` refuses `TRAEFIK_*`.
- **`priority-class`**: one PriorityClass per instance, named after the instance (`value` required, bounded to the user range; the `system-` prefix is refused). Workloads take it as an optional `priorityClass` dependency and read `priorityClass.out.name`, which orders them after the class. At most one default PriorityClass per cluster (cross-resource check 23).
- **`spegel`**: Spegel v0.7.4, a peer-to-peer registry mirror DaemonSet. Claims the `registryMirror` role (a k3s or RKE2 cluster that turns on its embedded Spegel binds it exclusive). Runs at system-node-critical priority. Reads `cluster.containerd` for the socket, content store, and registry config directory, and refuses `cluster.containerd.discardUnpackedLayers = true` and `cluster.capabilities.multiNode = false`. Intents admit the nodes (`host`, `remote-node`) to the registry port; peer traffic derives from the bootstrap Service.
- **`metrics-server`**: metrics-server v0.9.0, Kix-native: the resource metrics API (metrics.k8s.io) behind APIService `v1beta1.metrics.k8s.io`. Claims the `metricsApi` role, one per cluster; replicas from the availability level; intents for API server ingress and kubelet egress on 10250; `extraArgs` (port, certificate directory, bind address, and kubelet port flags refused) and `env`. Kind and Talos kubelets need `extraArgs = [ "--kubelet-insecure-tls" ]`.

### GitHub Actions runners (`kix/packages/arc`, `kix/packages/arc-runner-set`)

- **`arc`**: the gha-runner-scale-set-controller, Kix-native: vendored CRDs, leader election (replicas from availability: 1 up to `pod`, 2 from `node`), metrics Service, ServiceMonitor, and listener PodMonitor behind the optional `prometheus` dependency, and a `listenerEgress` operand policy for the listener pods. One instance per cluster (`conflictsWith = [ "cluster:arc" ]`, alias `arc`; a second instance fails first on the `actions.github.com` annotation domain, naming both). The controller is started with `--exclude-label-propagation-prefix` for Kix's three instance labels, so the listeners and runners it creates do not carry them. `image.tag` must parse as the controller's semver (no `v` prefix) and match the vendored CRDs' major.minor.
- **`arc.out.mkAutoscalingRunnerSet consumerScope { name; spec; }`**: returns the AutoscalingRunnerSet plus its runner ServiceAccount, manager Role, and RoleBinding. It sets the `app.kubernetes.io/version` label from the controller's image tag (the controller deletes a runner set whose major.minor differs), the `actions.github.com/cleanup-*` annotations, and the `cleanup-protection` finalizer on the supporting objects, and refuses a caller-set `serviceAccountName`, a name over 45 characters (the listener `<name>-<hash>-listener` must fit 63), a `githubConfigUrl` that is not `http(s)://<host>/<org>[/<repo>]` or `enterprises/<name>`, and `minRunners > maxRunners`. AutoscalingRunnerSet readiness is declared as `/status/phase == Running`.
- **`arc.out.operandSelectors`**: `runner <runner set name>` and `listener`, the labels the controller puts on runner and listener pods.
- **`arc-runner-set`**: one runner scale set on that builder. Deps `arc`, `githubConfigSecret` (keys checked with `kix.checkSecretKeys`: `github_token` or the three GitHub App keys) and optional `priorityClass`. `rules` gives the runner ServiceAccount a Role and mounts its token; `extraSpec` merges into the spec, with `template.spec.containers` merged by name. The runner image (`meta.version` is its release) is in `out.extraImages`; the runner egress policy selects `arc.out.operandSelectors.runner`.

### Virtualization (`kix/packages/kubevirt`, `kix/packages/cdi`)

- `kubevirt.out.mkVirtualMachine scope { name; spec; ... }`: waits for printableStatus Running (`runStrategy = "Always"`, `running = true`) or Stopped (`"Halted"`, `running = false`), refuses other strategies; `dataVolumeTemplates` adds the cdi instance's DataVolume CRD to `requires` and fails without a cdi instance.
- `kubevirt.out.crds.VirtualMachine`, `kubevirt.out.operandSelectors.virtLauncher`. kubevirt gives virt-exportproxy an operand policy when `extraSpec` turns on the VMExport feature gate.
- `cdi.out.mkDataVolume scope { ... }`: immediate binding annotation, waits for phase Succeeded.
- `cdi.out.mkImporterPolicy scope { name ? "<instance>-cdi-importer"; egress; }`: importer pod policy in the consumer's namespace (DNS, the given egress intents, ingress from cdi-deployment on 8443); the default name carries the calling instance's name, so two callers in one namespace do not collide.
- cdi takes an optional `priorityClass` dependency (`packages.priority-class`) for the CDI resource's `spec.priorityClass`.
- `cdi.out.crds.DataVolume`, `cdi.out.operandSelectors.{importer, deployment, uploadProxy}`.
- Both: operator roles vendored under `rbac/`; `operandImages.*` following `image`, digest-pinned, in `out.extraImages`; `extraSpec` guarded deep merge into the CR; one instance per cluster (`conflictsWith`).

### Storage packages

- **`storage-classes`**: StorageClasses for CSI drivers already running; `config.classes` (a required map of `kix.types.storageClass`, rendered by `kix.storage.mkClasses`), `out.storageClassName` (the single annotated or only class). Claims the `storageClasses` role.
- **`persistent-volume-claim`**: `size` required (`kix.types.quantity`), typed `accessModes`, `extraSpec` merged into `spec` through `kix.mergeGuarded` (`storageClassName`, `accessModes`, and the storage request are locked).
- **`snapshot-controller`**: the VolumeSnapshot CRDs and controller (external-snapshotter v8.6.0); provides the `snapshotController` role, whose out contract is `crds`.
- **`volsync`**: VolSync 0.16.0, Kix-native, one per cluster: the ReplicationSource and ReplicationDestination CRDs (readiness on `status.latestMoverStatus.result == Successful`, mover pods selected by `batch.kubernetes.io/job-name`), the vendored ClusterRole, and the operator, which needs the `snapshotController` role. `out.mkReplicationSource scope { name; claim; schedule; copyMethod; restic = { repository; endpointService ? null; storePort ? null; }; extraSpec ? { }; }` returns `{ replicationSource; egress; }`: a restic backup to S3 whose repository Secret's keys are checked, with mover network policy derived to an in-cluster `endpointService` or opened to `storePort` outside the cluster.
- **`zfs-localpv`**: OpenEBS ZFS LocalPV 2.11.1; StorageClasses through `kix.storage.mkClasses`, VolumeSnapshotClasses through an optional `snapshotController` dependency; `out.storageClassName`. Does not claim `storageClasses`: wire it with `deps.storageClasses = ref.<ns>.<instance>`, or give the instance `aliases = [ "storageClasses" "zfsLocalPv" ]`.
- **`mayastor`**: OpenEBS Mayastor 2.12.1, Kix-native: control plane, etcd on a DI StorageClass, node agents, CSIDriver, typed StorageClasses, VolumeSnapshotClasses, and DiskPools, per-component RBAC, io-engine metrics, and DiskPool alerts behind `prometheus`. `kix deploy` reports io-engine's OnDelete pods pending a restart.

### Flake Generation (`mkFlake.nix`)

- Auto-resolves cluster definitions (path → import → callPackage).
- Auto-detects package args (kix, packages, pins).
- `packages.<name> = ./path;` lists packages the flake defines; each gets the check `option-contract-<name>` (`kix.checkPackageOptions`), because cluster evaluation does not check the option contract.
- `pins = ./pins.json;` names the flake's pin file once. A cluster that takes a `pins` argument gets it already loaded, so no cluster definition repeats the path; one that asks for it when the flake declares none gets an error naming the fix.
- Generates: `packages.cluster-${name}`, `packages.cluster-${name}-activation`, `checks` (schema, PI wiring, option contract of `packages`), `legacyPackages` (kixClusters, kixPackages).

---

## CLI — `kix` binary

### Global Flags

| Flag | Description |
|---|---|
| `-o, --output <FORMAT>` | Output format: text, json, yaml |
| `-v, --verbose` | Increase verbosity (stackable: -v, -vv, -vvv) |
| `-q, --quiet` | Suppress non-essential output |
| `--no-color` | Disable colors (also respects `NO_COLOR` env var) |
| `--context <CTX>` | Kubeconfig context |
| `--flake <PATH>` | Flake reference (default: `.`) |

**Env vars:** `KIX_LOG` overrides verbose-derived log filter (RUST_LOG syntax). `KIX_RETRY_ATTEMPTS`, `KIX_REQUEST_TIMEOUT`, `KIX_CONNECT_TIMEOUT` tune the shared apiserver transport policy (retries with backoff, deadlines) and `KIX_PREFLIGHT=0` skips the first-contact probe; `KIX_SWEEP_CONCURRENCY` bounds the managed-resource sweep; `KIX_STALL_TIMEOUT` is the deploy progress watchdog's abort bound (default 600s, `0` never); see HANDBOOK § CLI.

### Commands

#### `kix build <CLUSTER>`
Render all manifests to stdout. Default format: YAML multi-document. JSON outputs array of manifests.

#### `kix diff <CLUSTER>`
Read-only comparison of the build with the live cluster, or with a directory. Needs only `get` and `list`, or no cluster at all with `--from <build>`. It cannot see what only shows on the write path (admission webhooks, field ownership conflicts, and what the deploy itself refuses); `kix plan` checks those. Every mode is one comparison of two store graphs: the live side (and a snapshot or export) is the kix-owned view of each object, lifted into a graph by its package annotations, so the output is the same package-grouped plan `kix deploy` shows, with cluster-level resources and the activation rotation as their own sections.
- `--from <DIR>` — Compare against a directory instead of the cluster: a previous build result (has `kix-packages.json`), or a manifest directory from `kix snapshot save` or `kix export`.
- `-o json|yaml` prints the `Plan` document `kix plan` also prints (`made_by: live_read` or `builds`; the write-path checks read `not_checked`). Schema: `cli/kix-cli/schema/plan.schema.json`.
- With the deployed build on this machine, each field change is labelled `intended` (the commit changes it), `reverts_drift` (live differs from the deployed build and the deploy puts it back), or `drift_kept` (live differs, and the deploy leaves the object alone because its identity hash did not change). The drift section names the field manager that made each drift. `--from <build>` labels every change `intended`.
- Exit code 2 = differences found, 0 = identical.
- Package-grouped output with resource-level diffs.
- Warns on PVC modifications.
- A converged cluster prints no differences. A live object that `kix drift` finds in sync with the manifest it was applied from, and that holds every field of that manifest unchanged, compares as that manifest, so fields the server or an operator's webhook added never show. A field the CRD schema pruned, a value a webhook overwrote, and a changed `kix.run/*` stamp still show. Otherwise the server's spellings count as equal: `null` or `[]` for an absent field, documented defaults such as `fieldRef.apiVersion: v1` or a probe's `failureThreshold: 3`, and quantities with the same amount. A Secret's literal `data` or `stringData` is compared with the decoded live `data`; a changed value shows as changed without printing what the cluster holds, and a SOPS Secret's decrypted values are never compared or printed. No live Secret value reaches `kix diff`, `kix snapshot save` or a deploy plan built from live objects. A Job its TTL removed after the deployed build ran it is not listed as added. The old activation is the cluster's current record.

#### `kix plan <CLUSTER>`
Preview a deploy as a server-side dry run. Runs the deploy pipeline with every write sent as `dryRun=All`, so the apiserver answers for each object. `kix deploy` prints the same plan before it asks; `kix deploy --dry-run` runs `kix plan`.
- Each field change is the live object compared with the object the apiserver says the apply would produce, labelled as the commit's or as drift when the deployed build is on this machine.
- Lists the writes the deploy would stop on: field ownership conflicts (with the manager that owns each field), admission webhook and ValidatingAdmissionPolicy denials, validation errors, immutable fields, RBAC refusals, and SOPS Secrets that do not decrypt. Every refusal shows, not only the first.
- Lists what the prune deletes or keeps, stateful migrations, and the objects the dry run could not check: kinds whose CRD the deploy installs, objects in a namespace it creates, and webhooks without dry-run support.
- Takes the deploy's planning flags: `--prune`, `--prune-mode`, `--reconcile`, `--force-conflicts`, `--accept-migrations`, `--current-activation` (compares with the cached build offline and checks nothing with the apiserver).
- `-o json|yaml|markdown`. The JSON and YAML are the `Plan` document (`made_by`, `packages`, and `migrations`, `conflicts`, `admission`, `drift`, `prune`, `readiness`, each `checked` with items or `not_checked` with a reason); progress goes to stderr.
- Needs the permissions of the deploy it previews: a dry run is authorised like the write.
- Exit code 0 = nothing to change, 2 = changes, 3 = the deploy would stop.

#### `kix check <CLUSTER>`
Two steps: eval correctness, then the scorecard report. No schema or deprecated-API tool runs over the rendered manifests.
- The eval step is where every build-time check lives: constructor validators, error-level scorecard findings, and the cross-resource checks (`kix/lib/eval/validate.nix`: ServiceAccount, Role, ConfigMap, Service selector, HPA, StatefulSet headless Service, duplicate identity, managed-by label, selector consistency, Ingress backend, Namespace, NetworkPolicy selector, named targetPort, PodDisruptionBudget selector, Job pods behind a Service, `kix.run/rerun`, PriorityClass, namespaced kind without `metadata.namespace`, PersistentVolumeClaim mounts, StorageClass names, custom resources depending on a declaration of their kind that serves their version, Secret and ConfigMap keys read by name, one default PriorityClass/StorageClass/IngressClass). Since 2026-09 those run inside `buildCluster`, so `nix build` and every `kix` command that evaluates a cluster run them; before that they ran only under `nix flake check`. Exemptions and the failure shape are in HANDBOOK §17.4.
- `--sarif` — SARIF 2.1.0 JSON output (GitHub Code Scanning compatible).
- Text output: TOOL | RESULT | DETAILS table.

#### `kix deploy <CLUSTER>` (alias: `kix apply`)
Wave-based deployment with confirmation.
- `-y, --yes` — Skip confirmation.
- `--dry-run` — Run `kix plan` with the same flags; nothing is applied.
- `--plan <FILE>` — Deploy only if the plan made now matches a reviewed `kix plan` or `kix diff` JSON document: same cluster, same new and deployed identity hashes, the plan's planning flags, and no new refusal, reverted drift, or prune delete. Exits 4 and applies nothing otherwise; with `--dry-run`, only checks. A different Kix binary is a note, not a refusal (`plan/saved.rs`).
- Before it asks, the deploy runs the plan as a server-side dry run and prints it. Under `--on-error stop` (the default) a plan with a refused write stops the deploy before anything is applied.
- `--reconcile` — Re-apply all resources (heal drift).
- `--prune`: Delete orphaned resources. Without it the plan still lists every orphan by name and says they are kept, and the new Activation lists the builds they came from under `status.orphansKeptFrom`, so a later `kix deploy --prune` or soft `kix gc` still deletes them. The previous deploy record (Activation) is never an orphan.
- `--prune-mode <MODE>` — default (after apply), no (skip).
- `--on-error <MODE>` — stop (default) or continue. Any failed resource exits 1 under both.
- `--timeout <DURATION>` — Readiness timeout (default: 180s).
- `--skip-import-checks` — Skip pre-deploy import verification.
- `--current-activation` — Use local cache instead of fetching from cluster. Refused before applying when the cached build is not the Active build of the cluster in the current context.
- An `OnDelete` DaemonSet is ready when its pods are; pods on a previous template are reported as pending a manual restart (`NodeDetail::PendingRestart`). A CRD import whose live CRD does not serve a declared version stops the deploy with `ImportMismatch`.
- `--operator` — Delegate to kix-operator (creates/patches Activation CR, waits for operator reconcile).

Pipeline: build activation → load store graph → resolve old activation → DAG diff → compute waves → display plan → validate imports → confirm → apply wave-by-wave with readiness checks → prune → record activation.

#### `kix status <CLUSTER>`
Resource health table.
- Default (flat): NAME | NAMESPACE | KIND | READY | STATUS | AGE. Lists only this Kix cluster's objects.
- `--operator` — Package-grouped view with Activation CR metadata, phase-based coloring (Active=green, Deploying=yellow, Failed=red).

#### `kix list clusters`
List all available clusters in the flake.

#### `kix list packages`
List available packages.
- `--cluster <NAME>` — Show per-cluster installation status: installed, installed (auto), import [namespace], available.

#### `kix graph <CLUSTER>`
Dependency DAG visualization.
- `--format <FORMAT>` — tree (ASCII, default), dot (Graphviz), json (nodes/edges).

#### `kix inspect <CLUSTER>`
Cluster structure analysis: total resources, namespaces with counts, resource kinds by frequency, detailed listing.

#### `kix gc <CLUSTER>`
Garbage-collect stale kix-managed resources.
- `-y, --yes` — Skip confirmation.
- **Soft GC** (default) — Diffs old vs new activation store graphs. Fast, no cluster scan.
- **Hard GC** (`--hard`): Full cluster-wide scan, matches identity-hashes against expected set. Judges only the named Kix cluster's objects, attributed through the Activation record hashes in `kix.run/activations`; objects another Kix cluster's current build contains are kept.
- `--include-unattributed`: With `--hard`, also judge objects that name no Activation record while another Kix cluster has records on the Kubernetes cluster. Without it they are listed and kept.
- `--operator`: Deletes retired Activation CRs under the retention policy. They are all Superseded, so the operator only removes its finalizer and deletes no resources.
- Record retention, in every mode — Superseded Activation records are rollback history, but each one still on the cluster keeps one entry in `kix.run/activations` on every managed resource, and that annotation is capped at 256 KiB, so they cannot be kept forever. `--keep N` (default 10) always keeps the N newest whatever their age; `--keep-max N` (default 50) never keeps more; `--keep-for 30d` (default) retires anything older beyond the floor (`0` or `off` disables the age rule). Deletes are conditional on the record being unchanged since it was listed. The next deploy drops the retired entries.
- Deletes in reverse dependency order (dependents first).
- Never deletes a Namespace or CustomResourceDefinition, the same kinds `deploy --prune` keeps: they are listed under "Kept" for removal with kubectl.

#### `kix migrate domain <CLUSTER>`

- One-off. Moves a cluster's Kix records off the retired `kix.dev` API group to `kix.run`. Copies every Activation record with spec, status and history intact, verifies the count, clears the operator finalizer from the old records, deletes the old CRDs. PackageInstance records are not copied: the next deploy re-creates them from the build.
- Always dry-runs first and prints the plan. `--dry-run` stops there; `--yes` skips the prompt.
- Rerunning after an interruption skips what it already copied.
- Until it has run, every command that reads a Kix record refuses the cluster and names it. On a cluster running the operator, upgrade the operator image after the migration and before the deploy.
- The first deploy after it re-applies every resource once, because every identity hash changed. Almost nothing restarts; packages that hash a ConfigMap or Secret into a pod-template annotation (for example `valkey` and `coredns`) roll their pods once. HANDBOOK §24.1.

#### `kix rollback <CLUSTER>`
Rollback to a previous activation.
- `-y, --yes` — Auto-select most recent superseded activation.
- `--dry-run` — Preview only.
- `--prune` — Delete resources only in current activation.
- `--operator` — Patches Activation CR to target's source path.
- Interactive selection: lists superseded activations with metadata, checks store path availability.
- History is bounded by `kix gc` retention (at least the 10 newest, at most 50, and nothing older than 30 days beyond the floor, by default): retired records can no longer be rolled back to.

#### `kix health <CLUSTER>`
Drift detection: compare intended state vs live cluster.
- Walks dependency graph from Activation root.
- Resource states: Healthy, External (import), Missing, AtRisk (depends on unhealthy).
- Package states: healthy, external, DEGRADED, AT RISK.
- Exit code 1 if issues found.

#### `kix snapshot save <CLUSTER> <DIR>`
Save one Kix cluster's live state to a directory. Discovers all API resources, fetches the Kix-managed resources whose `kix.run/activations` names one of the cluster's Activation records (other Kix clusters on the same Kubernetes cluster are skipped), writes by namespace. Each object is written as the fields Kix owns (the live value projected onto Kix's server-side-apply fieldset), so a snapshot compares to a build exactly the way the live cluster does: server defaults and Kix's bookkeeping annotations never appear. Path traversal protection. Compare with `kix diff <CLUSTER> --from <DIR>`.

#### `kix pin set <KEY>` / `kix pin check` / `kix pin list`
Resolve image references and record them in a committed pin file (`v2_discussions/archive/138`). Needs no flake and evaluates no cluster.
- `set <KEY> --tag <TAG>` — Ask the registry for the tag's manifest digest and write the pin. Refuses a tag the registry does not have.
- `--repository <REPO>` — Required for a new pin; otherwise the existing repository is kept.
- `--init` — Create the pin file, or add a key that is not in it yet. Without it an unknown key exits 1.
- `--no-resolve` / `--digest <D>` — Write a pin with no digest, or with one you already have. Both warn or validate rather than guess.
- `--source-rev <REV>` / `--promoted-by <WHO>` — What the image was built from, and who promoted it. `promoted-by` defaults to the CI run, or to user@host.
- `--force` — Rewrite a pin file `kix pin` did not write, discarding its comments.
- `check` — Verify every recorded digest is still in its registry, **by digest rather than by tag**. A moved or deleted tag whose digest still runs is a warning; a missing digest is a failure. Exit code 1 on any failure.
- `check --source-rev <REV>` — Fail unless every pin that records a source revision records this one. Catches a promotion step that silently did not run, which is otherwise invisible: the deploy succeeds, every rule passes, and the cluster runs old code.
- `check --offline` / `--allow-unresolved` — Shape only, no registry; and treat a missing digest as a warning.
- `list` — Show what a pin file holds.
- `--pins-file <PATH>` — Optional. Kix looks in the working directory, then next to `--flake`, then for the only pin file in the repository, and refuses with a list when there is more than one. The flake cannot declare the path, because a path literal in a flake is a store path, and reading it back would make a command that needs neither Nix nor a flake depend on both.

Credentials come from `KIX_REGISTRY_USERNAME`/`KIX_REGISTRY_PASSWORD`, then `credHelpers`, then `credsStore`, then a literal `auths` entry in the Docker config. Anonymous access is a valid outcome.

#### `kix completions <SHELL>`
Generate shell completions (bash, zsh, fish).

### Deploy Receipt (Activation `status`)

Every `kix deploy` writes what it deployed into the Activation's `status.receipt` (`v2_discussions/archive/138` §5.2). Status rather than spec, because the status subresource is untouched by an apply of the main resource, so a later rollback cannot erase it, and because a receipt is an observation rather than an intent.

The receipt holds the schema id, cluster name, activation identity hash, deploy time, the source (flake ref, git commit, **whether the tree was dirty**, `flake.lock` digest), the builder (kix and Nix versions, arch, os), every flake input's rev and narHash, and every container image the build renders. Superseded activations keep their own receipts, so the cluster carries a per-deploy history of what ran.

Not in the receipt: the manifests. Built manifests carry secret values inline, so storing them would make every deploy record a readable credential archive.

`kix compliance attest --from-cluster` reads a receipt and emits the SLSA statement from it, so a deploy can be attested from a machine that never built it. A dirty tree is stated on the statement rather than left to be inferred.

### Manifest Stamping (Annotations & Labels)

All kix-managed resources receive:
- `kix.run/identity-hash` — Blake3 content hash (change detection).
- `kix.run/depends-on` — Comma-separated dependency identity-hashes.
- `kix.run/package` — Package instance name.
- `kix.run/package-namespace` — Package namespace.
- `kix.run/mode` — "import" for external resources.
- `kix.run/crd-kind`, `kix.run/crd-version`, `kix.run/crd-served-versions`, `kix.run/crd-scope`: on CRD ref markers, the kind, default version, served versions (comma separated), and scope the declaration names.
- `app.kubernetes.io/managed-by: kix` label.
- `kix.run/cluster` label.

Activation CR extras: `kix.run/built-via` (store path).

---

## kix-operator

Long-lived K8s controller watching Activation CRs.

- **Activation lifecycle:** Queued → Deploying → Active → Superseded.
- **Reconcile loop prevention:** Stream-level generation filter (ignores status-only updates).
- **Requirements:** `nix-store` binary on host, read access to `/nix/store/`.
- **Finalizer-based cleanup:** Deleting an Active, Deploying or Degraded Activation CR makes the operator delete that activation's resources, dependants first. It keeps every Namespace and CustomResourceDefinition (`lifecycle::never_pruned`), which also keeps the CRD its own Activation records live in. Deleting a Superseded CR only removes the finalizer.

---

## Library Internals (kix Rust crate)

### eval module
- `KixEvaluator` — Main entry point. `NixBackend` trait for pluggable backends.
- `ClusterOutput` — Evaluation result (manifests, store graph, scorecard).
- `StoreGraph` — Package/resource DAG from Nix store.
- SQLite-based eval caching.
- Mock backend for testing.
- `ffi` feature flag for direct Nix FFI backend.

### manifest module
- **Structural diff engine:** path-based differences, keyed-list array diffing, rename/move detection (fuzzy similarity), configurable ignore rules, field labels.
- **Serialization:** YAML/JSON I/O, `load_manifests_from_dir`.
- **Stamping:** Annotation injection (identity-hash, depends-on, package metadata).

### cluster module
- **Activation:** find_active, list_superseded_activations, retire_plan (`gc --keep`), Activation CR lifecycle management.
- **Apply:** `detect_changes` → ChangeAction (Apply, Skip, Orphan). ApplyAction (Created, Configured, Unchanged, Skipped).
- **Fetch:** API resource discovery, fetch all kix-managed resources, normalize for diff (strip server-side fields).
- **Graph:** ResourceGraph with tree/dot/json output.
- **Imports:** collect import markers, validate against live cluster.
- **Readiness:** Per-kind checks (Deployment, StatefulSet, Job, DaemonSet, etc.), configurable timeout.
- **Reconcile engine:** Wave-based apply with `ReconcileObserver` trait for progress callbacks. `ReconcileEvent` types: WaveStart, ResourceApplied, ReadinessWaiting, etc. OnErrorPolicy (Stop, Continue), PrunePolicy (Skip, WarnOnly, Delete).
- **Waves:** Topological sort into parallel-safe deployment waves.

---

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Error / validation failure / failed resources |
| 2 | Differences detected (diff) |

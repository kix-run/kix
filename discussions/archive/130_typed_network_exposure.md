# 130: Typed Network Exposure

**Status:** Implemented (S1 core + operand termination) — generalized by the typed-facts channel (PR #31, `kix/lib/core/facts.nix`). Remainders carried to 131.
**Related:** `96_netpol_autogeneration_blindspots.md`, `97_service_contract_primitives.md`, `92_declarative_network_policy_intents.md`, `95_netpol_build_time_validation.md`, `121_netpol_as_plugin.md`, `119_core_surface_audit.md`, `120_compiler_theory_mapping.md`, `107_overlay_edge_exposure.md`, `127_compiler_target_model.md` (role registry), `126_compiler_core_rewrite_plan.md` (empty-diff invariant)
**Supersedes (design-space of):** `96` — its problem statement stands; its unresolved §Design-space A/B/C is replaced by this direction. Archive 96 when this is Accepted.
**Revision note:** hardened against an 18-agent adversarial pressure-test (2026-07). The taxonomy-first framing and the §1 diagnosis survived; the §5 safety claim, the §3.1 API surface, and the taxonomy's axes did not, and are rewritten below. Where the pressure-test found a genuinely open design choice (not just an error), it is flagged in §9 rather than silently resolved.

## 0. Taxonomy — every edge that needs a netpol

Before proposing a mechanism, enumerate what it must serve. Most edges that need a policy are **not** consumer-to-Service. A rule is a `(peer, direction, ports, effect)` tuple over **four** axes; a mechanism can only carry an edge if it can name all four.

### 0.1 Peer descriptor (the `to`/`from`)

| | Peer | Enforcer support (`cilium-external/netpol-rules.nix`) |
|---|---|---|
| **P1** | In-cluster pod set (selector + namespace) — Service pods, workload pods, operator-managed pods, **kube-dns** (matched by pod selector, not an entity), self/peer (selector = own) | ✔ `toEndpoints`/`fromEndpoints` |
| **P2** | Reserved entity / node identity — `kube-apiserver`, `host`, `remote-node`, `health`. **hostNetwork pods resolve here, not to P1** | ✔ egress `toEntities`; ✗ **no `fromEntities` builder for host/remote-node ingress** (only world + all-pods→cluster) |
| **P3** | World (any off-cluster) | ✔ `world` |
| **P4** | External fixed IP / CIDR — managed DB, partner API, on-prem, node CIDR, cross-cluster tailnet | ✗ **no `toCIDR`** |
| **P5** | External FQDN — a specific host, DNS-aware | ✗ **no `toFQDN`** |
| **P7** | In-mesh remote-cluster endpoint (Cilium ClusterMesh / MCS `ServiceImport`) — selector-shaped with a `cluster` label, **not** a CIDR | ✗ not modeled |

(P6 "self/peer" from the prior draft was folded into P1 — `selector = own` is a selector value, not a peer kind. What makes self-replication distinct is its *channel* (S3, auto-from-kind), moved there.)

### 0.2 Source channel (who declares the edge)

- **S1 Consumer-read** — the source reads the target's address (egress). *The typed marker (§3) carries only this.*
- **S2 Producer-accepts** — the target declares/ships "I accept X"; the source reads nothing (ingress fan-in).
- **S3 Auto-from-shape** — inferred from resource structure (RBAC, probes, LoadBalancer, StatefulSet kind).
- **S4 External-declared** — the far end is not a kix object; declared as cidr/fqdn/entity.
- **S5 Platform** — flavor/system-owned (CNI, mesh, health).
- ~~**S6 Derived-from-kix-relation**~~ — **RULED (2026-07): not a separate channel.** A role/capability-mediated read (role registry, `eval/roles.nix`) is a **proven S1 sub-case**: role resolution must forward the provider's `out.fqdn`/`out.url` *with the endpoint marker intact*, so the edge is an ordinary consumer-read. Requirement, not assumption — a test must lock "role-resolved `out.fqdn` preserves the marker" so a future refactor can't silently drop it (§9).

### 0.3 Direction and effect (the two axes the prior draft omitted)

- **Direction** — one logical edge (A calls B) is almost always **two rules**: an egress on A and an ingress on B, and the two can come from *different channels* (A's egress is S1 consumer-read; B's ingress is S2 producer-accepts). The matrix below is per-rule, not per-logical-edge.
- **Effect** — `allow | deny | allow-except`. Cilium **unions** allow rules, so a restriction is an explicit deny with precedence, not the absence of an allow. The current envelope has **zero deny builders** beyond namespace default-deny. Containment (IMDS-block, DNS-exfil lockdown, tenant isolation) is inexpressible today and orthogonal to the peer×channel grid.
- **Enforceability** — some edges are **netpol-inapplicable**: hostNetwork pods get no CNP by design (`derive.nix:29` short-circuit + "no effect" warning); Multus/secondary-CNI interfaces never traverse the primary enforcement point. These need a predicate that suppresses both derivation *and* §5 validation.

### 0.4 The matrix — every case, placed, with today's coverage

**S1 Consumer-read (P1) — the only quadrant the store-path signal serves:**
1. Workload → another package's Service (ClusterIP) — ✔
2. Caller-ingress on those target pods (reverse of 1) — ✔
3. Direct headless-pod addressing (`pod-0.hs.ns.svc`) — ✔ *iff the headless Service's `out` is read; §3 caveat for `$(POD_NAME)`-substituted forms*

**S3 Auto-from-shape:**
4. StatefulSet peer replication (patroni/raft) — P1 selector=own, ✔ (`mkSelfRules`, gated purely on `workloadKind=="StatefulSet"` — **S3, not S1**; the prior draft misfiled this)
9. DNS, every pod — P1 kube-dns pod-set — ✔
10. Kubernetes API (client-go/operators) — P2 — ✔ but detection is an *RBAC-presence heuristic*; under-approximates any pod calling the apiserver with a token but no RoleBinding
11. **Kubelet liveness/readiness probes** (node → pod) — P2 host/remote-node. ✗ not derived; needs a `fromEntities` ingress builder that doesn't exist
12. External ingress via **LoadBalancer only** (world → edge) — P3. ⚠ `needsExternalIngress` checks only `type=="LoadBalancer"` (**NodePort silently dropped**), and fans world-ingress to **every workload in the instance**, not the LB's backing pods — a live over-approximation

**S2 Producer-accepts — the biggest blind channel (no consumer read exists):**
5. **Admission/conversion webhooks** (apiserver → webhook pod) — P2 (or off-cluster control-plane CIDR = P4 on managed clusters). ✗ not derived. *Only cert-manager & stackgres-operator ship the webhook config+Service; kubevirt/cdi install theirs at runtime* → §6.1 has nothing to read for the latter
6. **Prometheus scrape** — split: in-cluster app pods = P1 fan-in (derivable); **control-plane/node targets (etcd, kubelet, kube-proxy…) = P2/P4 hostNetwork/static-endpoint** and *not* pod-selectable. Today a hand-rolled blanket (`network-policies/default.nix:273`). ServiceMonitor names the target + a *named* port, **not** the scraper identity (the Prometheus CR selects monitors) → `from` must come from the monitoring package
7. Ingress-controller / gateway → backend — split: **7a static controller** (ingress-nginx, derivable) vs **7b dynamic data-plane** (Gateway-API Envoy, tailscale/firezone proxies with operator-minted runtime labels — source selector absent at compile time). ⚠
8. Operator → operand reconcile connection — P1 runtime labels. ⚠ hand-rolled per operator
20. **APIService aggregation** (apiserver → extension apiserver: kubevirt virt-api, cdi, metrics-server, prometheus-adapter) — P2. ✗ webhook-shaped but declared via `APIService`+Service, omitted from §6.1's derive list; runtime-installed for kubevirt/cdi
21. **Host→pod exec/attach/portforward/log** (kubelet → pod, operator reconcile path) — P2. ✗ no probe field to signal; §6.2's probe detector misses it

**S4 External-declared (no kix object on the far end):**
13. Workload → generic internet — P3 — ⚠ blanket `world`, unscoped
14. Workload → external fixed service (managed DB/partner at IP) — P4. ✗ **not expressible** (no toCIDR)
15. Workload → specific external FQDN — P5. ✗ **not expressible** (no toFQDN)
16. Backup engine → object storage — often declared in a **CR/Secret read by the operator** (Velero `BackupStorageLocation`, stackgres `SGObjectStorage`), not the pod closure → `connect` on a kix workload can't attach. ✗
17. Cross-cluster / multi-site — **P4 CIDR for plain tailnet/VPN**, but **P7 selector for ClusterMesh/MCS**. `connect{cidr}` is the wrong shape for the mesh case (doc 127/129)
18. Alertmanager → Slack/PagerDuty/SMTP — P3/P5 — ⚠ blanket world (doc 110)
19. **IMDS containment** (deny 169.254.169.254 even under a broad world allow) — **effect=deny**. ✗ requires Cilium `egressDeny` (deny-precedence); allow-side `toCIDRSet.except` cannot deny under a unioned `world` allow — the prior draft's stated mechanism was wrong

**S2/none — operator-managed operands & runtime data-planes (largest coverage hole):**
22. **Operator-created operand pods** (stackgres SGCluster Patroni, kubevirt virt-*, cdi, prometheus-operator Prometheus/Alertmanager STS) — created at runtime from a CR; **no Deployment/Service/ServiceMonitor/pod-spec exists at eval time**, so S1 (no `out.fqdn`), S2 (no shipped config), S3 (no pod spec) all fail. Only `stackgres-cluster`'s hand-rolled CNPs on `sgPodSelector` exist today
23. **Storage data-plane node↔node** (mayastor NVMe-oF, Ceph OSD/mon, iSCSI, NFS) — hostNetwork both ends, target+port runtime-negotiated by the CSI control plane. No consumer read, no shipped ingress, no kix workload
24. **CSI reverse-gRPC callback** (register-then-dial-back to node agent) — P2, implicit container listenPort, hostNetwork

**S5 Platform:** CNI/kube-proxy/node components, mesh sidecar↔control-plane, cilium-health — flavor-owned platform intents (doc 92). Mostly outside app-author scope.

### 0.5 Reading of the matrix

The store-path signal serves **S1 × P1, cases 1–3** — ~3 of ~24 — and per §1 gets even those wrong both ways. "Getting netpol right" = serving all peer types across all channels, in both directions, with a deny effect. §3 fixes the S1 quadrant; §5 adds the missing producer-side guard; §6 homes S2/S3/S4, the operator-operand hole, and the deny axis. The channels are structurally distinct: S1 is a consumer read, S2 is producer-shipped ingress a consumer read can never carry, S4 has no kix object at all, and case 22/23 has no eval-time resource of any kind.

## 1. Problem — one untyped signal, wrong both ways (S1)

Edge detection has one mechanism (`kix/lib/eval/edges.nix:63-102`): an edge exists **iff a Service's Nix store path appears in the workload input's string context.** Store-path context means "derived from that resource *for any reason*," so it proxies a typed relation (reachability) with an untyped one. It fails both ways.

**Over-approximation → opens holes.** `edgesFor` runs `builtins.toJSON` over `workloadInput` (`instance.nix:119-124`), which includes `requires`; `toJSON` coerces each `requires` resource to its store-path string, which lands in the JSON's context where `edges.nix:70-74` matches it. So `requires = [ svc ]` for *wave ordering*, or `labels.app = svc.out.name`, mint a spurious egress rule + caller-ingress hole. (The over-approximation is real; the prior draft mis-cited it to the `depContexts` fold at `resource.nix:238-241`, which only affects the resource's *own* identity file and is downstream-invisible.)

**Under-approximation → blocks legit traffic on a green build.** Context is one-hop into the workload's own input, stripped at every indirection boundary (doc 96's ConfigMap/Helm/hand-FQDN blindspots), blind to same-instance references (`serviceRegistry` is dep-instances only, `eval/instance.nix:115`), and blind to **bare short-name references** (`--store=${name}-etcd:2379`, `nats://${name}-nats:4222`) — the dominant operator/storage addressing style — which carry no marker *and* are not `*.svc` (so the promoted `fqdnWithoutContext` error never fires either).

Neither libv1 nor v2 addressed this — the matcher is functionally identical across both. Pre-existing limitation, not a regression.

## 2. This is not doc 97 relitigated

97 §1.5 rejected typing **service semantics** (`kind`/`protocol`/`provides`) — the DAG already proves "immich talks to postgres." That stands. This doc types a **different axis**: the *access relation* — "this read is a network read" vs a name/ordering/label read. The marker carries only `{selector, ports, namespace}` (exactly what `mkServiceRef` markers already carry), never protocol or kind. Orthogonal to 97, consistent with it; 97 §5–§6 even concede the two error classes its untyped mechanism can't fix. In doc 120's terms this is a down-payment on "link-time typing of DI `out`"; in doc 119's terms, store-path-as-edge stays ring-0 for ordering/wave/DNS (coarse channel, over-approximation harmless), and netpol gets a **typed sub-channel**.

## 3. Mechanism — the S1 channel: typed network exposure

### 3.1 Type the autoOut — a synthetic endpoint token, not an emitted marker

**RULED (2026-07): the endpoint type is minted inside `autoOut`, not as a separate emitted resource.** There is **no `mkService`** in `kix/lib`; Services are minted via generic `scope.mkResource { kind = "Service"; }` at ~29 sites, but `autoOut` (`core/resource.nix:265-289`) *already* branches on `kind == "Service"` to build `{ name, fqdn, identityHash, selector, ports (a LIST), url }` — **no `host`, no scalar `port`**. Today all of those are `attachCtx`-stamped with the *same* resource identity context, which is why `out.name` in a label is indistinguishable from `out.fqdn` in an env var. The fix is one more thing that same `autoOut` branch produces: a **distinct store-path token** on the network fields.

**The token is a pure function of the Service — no CR emitted.** In the `kind == "Service"` branch, gated on the `isService` predicate (`edges.nix:23-27`, which already excludes selector-less and ExternalName Services):

```nix
endpointToken = builtins.toFile "netpol-endpoint-${name}-${ns}"
  (builtins.toJSON { inherit selector ports; namespace = ns; });

out.name = attachCtx name                    identityCtx;                        # Service path only  → NO edge
out.fqdn = attachCtx fqdn (identityCtx // getContext "${endpointToken}");        # Service path (ordering) + token (netpol)
out.url  = attachCtx url  (identityCtx // getContext "${endpointToken}");        # url must NOT be omitted — it is the canonical connection string
```

`out.fqdn`/`out.url` now carry **two** kinds of context: the real Service path (wave/DNS/readiness, exactly as today) **and** the synthetic endpoint token (the netpol type tag). `out.name` and ordinary `requires` carry only the Service path.

**The registry recomputes the token — collectibility problem gone.** `toFile` is content-addressed, so the consumer computes the *identical* token from the Service it already collects. `mkServiceRegistry` keys on `endpointToken svc` (recomputed) instead of `svc.outPath`; the matcher is unchanged in shape:

```nix
matched = filter (p: hasAttr p endpointRegistry) (attrNames ctx);   # token paths
```

Because the consumer already iterates the dep instance's Services (`_depResourcesForEdges` → `collectTypedAttrs` → `filter isService`), it recomputes each `endpointToken` locally. **Nothing needs to be emitted or collected as a side-marker** — this dissolves the cross-instance "invisible side-marker" hole entirely (it was the pressure-test's #2 critical finding).

**One wrinkle — filter the token from `depends-on`.** The token is a real store path, so it lands in the workload's manifest context and `implicitCtxPaths` (`core/resource.nix:215-218`) would stamp it into `kix.dev/depends-on`, where the CLI can't resolve it to a manifest. Fix: exclude paths whose name embeds `-netpol-endpoint-` from the `depends-on` stamp. Deploy ordering still rides the **real Service path** (which stays in the context) via the normal requires-traversal — the token is netpol-only.

**Cost vs doc 126 — near-zero.** No emitted CR per Service → **no `+N` NetworkEndpoint resources** in the ludo-kind manifest output. The only output delta is the `depends-on` filter (which *removes* the token hashes, not adds resources), so the empty-diff surface is minimal rather than a full re-baseline.

**mkServiceRef — RULED: replace it (Phase 2), don't patch it.** A `mkServiceRef` has only **one** store path; all `out.*` share it (`builders.nix:670-684`), so a naive split is undefined there and packages route wave-ordering through `out.name` (`stackgres-database`: `clusterName = postgres.out.name`). One conceptual model unifies both cases — **`out.fqdn` always carries an endpoint token**; for a kix-managed Service it is the synthetic `toFile` above, for an externally-backed Service it is the **import marker the ref already emits** (which is genuinely a resolvable node, since there is no kix Service to order on). The Phase-2 service DSL builds `.out` through this one path for both, finishing doc 97 §4 and deleting the `unsafeDiscardStringContext` dance. **Phase 1 interim:** `mkServiceRef` untouched — the "out.name → no netpol" guarantee holds only for kix-managed Services until Phase 2.

**Result — over-approximation dies (native refs):** `env.DB_HOST = db.out.fqdn` → edge; `requires = [ job ]` → wave edge, no netpol; `labels.app = db.out.name` → no netpol.

## 4. Indirection — the ConfigMap/Secret boundary (S1)

A workload writes `db.out.fqdn` into a ConfigMap, then mounts it **by name** — the marker rides the ConfigMap's closure, not the workload's.

**Chosen: mount helper attributes pre-seal + chase reused as a lint.** (There is no `scope.mkConfigMap`; the precondition is being kix-*mounted* via the doc 32 mount DSL, not built by a dedicated builder.)

- **Mount helper = attribution — new plumbing, not `augmentEdge`.** `augmentEdge` forwards the passenger's *own identity path*; the marker paths embedded in the CM's manifest *data* are swallowed by `toFile` (which is exactly why `resource.nix` must re-read `getContext` over the pre-`toFile` `manifestJson` to recover implicit deps). So the helper must, **at mount time, `getContext` over `toJSON` of the CM's `rawManifest`, filter to `endpointRegistry`, and `appendContext` those markers onto a workload-bound string in `_injectMounts`.** Edge lands in the workload's own closure pre-seal → gates readiness.
- **Chase = validator.** A mount-walk → error if a workload names a carrier holding a marker with no matching edge. It must be **symmetric**: ConfigMap *and* Secret, `configMapKeyRef` *and* `secretKeyRef`, `envFrom` both, iterate `containers ++ initContainers ++ ephemeralContainers`, recurse `projected.sources[]`.
- **Scope of "nothing slips."** Only **compile-time-addressed** carriers. **Runtime-populated carriers carry no marker and are out of scope → route to explicit `connect`:** `mkSecretRef` (import PI, no data), external-secrets/`ExternalSecret`, operator-populated ConfigMaps, Vault-agent files, and Helm-templated ConfigMaps (context erased by `unsafeDiscardStringContext` at IFD).

**Cost:** the chase forces nothing not already forced — `getContext` over a CM manifest is computed at seal time (`core/resource.nix:216`). Same order as the RBAC scan (`derive.nix:190-217`) that precedes the supplement emission (`223-253`). O(resources), no extra evaluation.

### 4.1 Alternative to explore — full auto-attribution

Kept for evaluation, not chosen. Assembly-time chase **auto-attributes** every marker behind a mount instead of erroring. **Pro:** magical, even hand-rolled volumes get their edge. **Con:** indirect edges become **post-seal supplement policies** → cannot gate readiness, and leans hardest on the assembly-time pass (closest to 121's "post-pass impossible under content addressing"). Compatible: could later demote the lint's errors to "auto-added supplement + warning."

## 5. Validation posture — refuse, immediately (but only where it can see)

**Headline correction from the pressure-test.** The prior draft claimed error-immediately "kills the audit's silent green build." It does — **for the S1 consumer-read egress quadrant only.** `referenced-but-unpermitted` fires exclusively when a *workload reads a marker*. It is structurally blind to S2 ingress fan-in (webhook/scrape/APIService — no consumer read exists), S3 detector-misses (probes/apiserver), and S4 missing-`connect`. The doc's own "biggest gap" — webhook ingress, where cert-manager's pod receives **zero** ingress CNP today — is exactly what the consumer-side error cannot see.

Posture, corrected:

- **S1 consumer-read egress** — workload reaches a marker with no covering egress → **hard error.** Eliminates the silent green build *for this quadrant only*. Say so explicitly.
- **Symmetric producer-side check (new, the S2 backstop)** — a package that **ships an ingress-shaped resource** (Validating/MutatingWebhookConfiguration, ServiceMonitor/PodMonitor, Ingress, APIService) whose target has **no covering ingress rule** → **hard error**, mirroring `referenced-but-unpermitted`. This is the only thing that makes error-immediately protect S2. It cannot cover runtime-installed configs (kubevirt/cdi) — those need §6's operator-operand declaration.
- **permitted-but-unreferenced** — derived rule, no backing typed reference → warning.
- **Precision constraint (new)** — under a no-grace hard error, the path of least resistance is the *widest* covering edge (`connect entity=world`), silently re-introducing the over-permissioning §3 removed. So: **warn when a covering egress is broader than the marker it silences** (peer/port must match the marker's selector/ports), or document the coarse-allow escape as a known pressure.
- **hostNetwork / netpol-inapplicable** — a hostNetwork pod reading `db.out.fqdn` must **not** trip the error (the CNP can never apply — `derive.nix:29` already skips it). A `netpol-inapplicable` predicate suppresses **both** derivation and §5 validation, degrading to the existing "no effect" warning.
- **`fqdnWithoutContext` → error** — but note it only fires on `*.svc` literals (`looksLikeSvcFqdn` needs the `.svc` infix); **bare short-names escape it entirely**, so it is not the broad safety net it appears.

**Migration prerequisites, corrected (the prior draft was internally contradictory).**
- **Required before the flip** (or day-one errors fail existing packages): S1 typed-output migration (use `out.fqdn`/`out.url`, no hand-rolled FQDNs/short-names), mount-helper/chase for CM indirection.
- **Needed for coverage but NOT enforced by the flip**: S2 `accepts`, S4 `connect`. Omitting them does **not** error — so an undeclared webhook/external dep still builds green. State this plainly rather than implying the flip forces them.

## 6. The other channels

### 6.1 S2 — producer-accepts

Derive the edge from the ingress-shaped resource the package already ships — but the derivation is multi-hop and the source identity is not always in the shipped resource:

- **Webhook** (cert-manager, stackgres-operator ship the config+Service; **kubevirt/cdi install at runtime** → nothing to read, route to §6.2 operator-operand). Source = **`[kube-apiserver, remote-node, host]`** (single-entity reproduces the exact host-resolution bug the *egress* rule already fixed, `netpol-rules.nix:61-74`), flavor-parameterized to an **off-cluster control-plane CIDR** on managed/GKE-private clusters. Port = resolve `clientConfig` (defaults to Service port 443) → `Service.spec.ports[name|443].targetPort` → containerPort (cert-manager 10250, stackgres 8443), **excluding** the metrics port on multi-port webhook Services.
- **Scrape** — split in-cluster app pods (P1, derivable) from control-plane/host targets (P2/P4, not pod-selectable). The **scraper `from` identity is not in the ServiceMonitor** (the Prometheus CR selects monitors) — the monitoring package must supply it. Port = named Service port resolved through `targetPort`.
- **APIService aggregation** (case 20) — same shape as webhook, source `[kube-apiserver,…]`, declared via `APIService`+Service.
- **Ingress-backend** — 7a static controller derivable from the Ingress; 7b dynamic data-plane (Gateway-API Envoy, tailscale/firezone) has no compile-time source selector → coarse `fromEndpoints` on the controller namespace or an operator-owned label convention carried on the package's out-contract.

**Enforcer envelope work S2 needs** (not in §8 of the prior draft): a `fromEntities=[kube-apiserver,remote-node,host]` **ingress** rule builder **and** an ingress supplement-emit path mirroring the egress-only `apiServerSupplementPolicies`.

Open: pure derivation vs an explicit `meta.network.accepts` escape — likely both (derive default + escape for runtime-installed cases).

### 6.2 S3 — auto-from-shape

- DNS (9), external-ingress (12, **extend to NodePort**; scope the world-ingress to the LB's backing pods, not every workload) — keep/fix.
- apiserver (10) — broaden past RBAC-presence conservatively.
- **probes (11) — NEW:** derive host/remote-node ingress for any workload with a `livenessProbe`/`readinessProbe`/`startupProbe` — **needs the `fromEntities` ingress builder above.** Also covers host→pod exec/attach/portforward (case 21) which has no probe field — likely a blanket host-ingress opt-in for pods the operator manages.

### 6.3 S4 — external-declared + enforcer envelope extension

One `connect` primitive with a typed descriptor, **two shapes**:

```nix
connect = [
  loki.out                                        # IN-CLUSTER (S1) marker form — feeds the edge registry
  { fqdn = "api.stripe.com"; ports = [443]; }     # P5
  { cidr = "10.9.0.0/24"; ports = [5432]; }       # P4
  { entity = "world"; ports = [443]; }            # P3
];
```

- **In-cluster form** (`connect = [loki.out]`) is what replaces the Helm `networkDeps`/`deps` path (§8.3) — **not** a hand-rolled `{fqdn="loki-gateway"}`, which §5 would now *error*. Behind IFD the edge is carried by the `deps`/`_helmNetworkDeps` side-channel (which survives context-discard); the marker does **not** ride the sealed Helm workload's own closure, so netpol and dependency closure are already decoupled there — state this.
- **Envelope extension (breaking):** add `mkCidrEgressRule`/`mkFqdnEgressRule` (Cilium `toCIDR`/`toCIDRSet`/`toFQDNs`) — allow-side only.
- **Deny / effect axis — RULED (2026-07): skip for now.** Containment (IMDS-block, DNS-exfil lockdown, tenant isolation) needs `egressDeny`/`ingressDeny` deny-precedence *and* a policy call about who may declare a deny at what scope (a genuine departure from derive-don't-declare). Deferred to `interesting_thoughts/` — not in this doc's scope. Until then the model is allow-only; `connect{entity=world}` is deliberately coarse and there is no carve-out.
- **P7 (ClusterMesh/MCS):** a selector shape with `io.cilium.k8s.policy.cluster`, not `connect{cidr}` — near-term for doc 129.

### 6.4 Operator-managed operands — RULED (2026-07): one general operator→operand primitive

Cases 22/23/24 have **no eval-time resource of any kind** — the operator creates the data-path pods from a CR at runtime, so S1/S2/S3 all silently assume a kix object that isn't there. **Decision: a single general `operator → operand` CNP surface for now**, not per-operator hand-rolls and not a full operand-connectivity model that would drift from operator internals across versions.

Shape: the operator package declares the label selector its operands will carry (it knows this by construction) — e.g. `scope.operatorOperand { operatorSelector; operandSelector; ports; }` — and kix emits the baseline general case:
- operator → operand egress + operand ingress-from-operator (reconcile/connect),
- operand ↔ operand self-rules (replication/gossip),
- DNS + apiserver for the operand (the operand is a workload kix can't see, but the operator names it).

This is the `stackgres-cluster` `sgPodSelector` hand-roll **generalized to one primitive**. Deliberately *minimal*: it does **not** attempt to model operand→external egress (backup, extension registries) — that stays an explicit per-operator declaration, because the operator's runtime reconcile logic is the real source of truth and a declared full spec would rot. Consumer→operand ingress is already served by `mkServiceRef`/the Phase-2 service DSL (§3.1); this primitive covers the operator-internal fabric `mkServiceRef` doesn't.

### 6.5 S5 — platform

Unchanged: doc 92 platform intents own system pods (CoreDNS, CNI, mesh, health).

## 7. Relationship to essence (119), link-time typing (120), plugin (121)

- **119 store-path-as-edge stays ring-0** — scoped to the coarse channel (wave/DNS/ordering); netpol moves to the typed sub-channel. The marker is still a store path, still graph-proved.
- **120 link-time `out` typing** — first concrete instance: type one relation (reachability), structurally keyed, no new vocabulary.
- **121 netpol-as-plugin** — edge detection + endpoint-token registry + chase-lint stay core (DNS shares them); derived policies, `connect`, `meta.network.accepts`, the producer-side check, and the operator-operand surface are plugin-side. Attribution is pre-seal; only the lint runs at assembly time. No new emitted resources, so **126's empty-diff invariant** is barely touched (the only delta is the `depends-on` token filter).

## 8. Breaking changes

1. Edge registry keys on the synthetic **endpoint token** (`toFile` over the Service's `{selector, ports, namespace}`, recomputed by the consumer), not raw Service paths (`edges.nix` `mkServiceRegistry`).
2. Token minted inside the `kind=="Service"` branch of `autoOut` (`core/resource.nix`), gated on `isService`. **No emitted CR, no `mkService` builder, no cross-instance collection plumbing** — the consumer recomputes the token from the Services it already collects.
3. `out.fqdn`/`out.url` carry the token *plus* the Service path; `out.name` and `requires` carry only the Service path. `depends-on` stamping filters `-netpol-endpoint-` paths (`core/resource.nix:215-218`) so deploy ordering rides the real Service. No `out.host`/scalar `out.port` introduced (they don't exist). mkServiceRef caveat: §3/§9.
4. Enforcer envelope grows: `toCIDR`/`toFQDN` egress (allow-side) + `fromEntities` **ingress** builder + an ingress supplement-emit path. (Deny builders deferred — §6.3/§9.)
5. New producer-side ingress check (S2 backstop); probe-derived ingress (S3); operator-operand runtime-selector surface (§6.4).
6. `networkDeps`/`deps` Helm path → `connect` in-cluster marker form; NodePort external-ingress detection; LB ingress scoped to backing pods.
7. `fqdnWithoutContext` warning → error (with the short-name caveat). New `referenced-but-unpermitted` (S1) + producer-side ingress error (S2).
8. hostNetwork/netpol-inapplicable behavior **preserved** (skip-and-warn), now also suppressing §5 validation.
9. Package-tree migration to typed outputs (`out.fqdn`/`out.url`, no hand-rolled FQDNs/short-names) is a prerequisite phase. No CR re-baseline needed — the token is never emitted; only the `depends-on` filter changes stamps.

## 9. Decisions (2026-07) and remaining open questions

**Ruled this round:**
- **Marker hook — core branch, no `mkService` builder.** Mint the marker inside `mkResource`, in the same `kind=="Service"`/`isService` branch that already builds `autoOut`. Zero migration; one code path. A `mkService` builder may arrive later for unrelated typed-constructor reasons (docs 100/119) but does not gate this.
- **mkServiceRef — replace, don't patch (Phase 2).** A proper service-contract DSL builds `.out` through the same `autoOut`+marker machinery as a kix-managed Service (finishing doc 97 §4). The single-path hack, the `out.name`/`out.fqdn` ambiguity, and `unsafeDiscardStringContext` all disappear. Phase 1 leaves `mkServiceRef` untouched as interim.
- **Role registry — S1 sub-case, no S6 channel.** Role-resolved reads must preserve the marker end-to-end; lock it with a test rather than adding a channel.
- **Deny / effect axis — skip for now.** Defer to `interesting_thoughts/`; model stays allow-only.
- **Operator→operand — one general primitive** (§6.4), minimal (no operand→external model).
- **Marker granularity — per-Service** to start; tighten to per-port only if egress precision is measured to matter.

**Still open:**
- **Role-marker preservation** — verify `out.fqdn`/`out.url` survive `eval/roles.nix` resolution with context intact; write the locking test. (Blocks the S1-sub-case claim.)
- **Phase-2 service DSL shape** — the exact surface that unifies kix-managed and externally-backed Service `.out` (its own follow-up doc).
- **operatorOperand API** — exact argument shape and how it composes with the operator's CRD schema.
- **Chase depth** — one hop; cap and lint deeper chains.
- **Auto-attribution flip (§4.1)** — revisit once helper+lint is in-tree and lint-fire rate on un-helperable mounts is measurable.
- **Follow-up docs** — §6.1 (S2 + ingress envelope), §6.4 (operator operands), and the deferred deny axis are each large enough to spin out.

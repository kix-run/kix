# 181: Network policy on managed clouds

**Status:** Draft (2026-11-25). Proposed design; implementation has not started. Section 10 lists the seven decisions needed from the maintainer.
**Related:** `181a_network_policy_on_clouds_build_plan.md`, `181b_network_policy_platform_facts.md`, `181c_network_policy_identity_egress_and_dns.md` (decisions 3 and 4 in full), `121_netpol_as_plugin.md` (section 5, the envelope repair scheduled here), `95_netpol_build_time_validation.md`, `177_workload_cloud_identity.md`, `180_cloud_identity_across_packages.md`, `housekeeping/2026-11-24-only-cilium-enforces-generated-network-policy.md`, `kix/lib/plugins/netpol/`, `kix/packages/experimental/cilium/netpol-rules.nix`

## 1. Context

We tested Kix on live GKE and EKS clusters for the first time on 2026-11-25.
Today, `networkPolicy.enable = true` emits only `CiliumNetworkPolicy`
resources. GKE Dataplane V2 and the Amazon VPC CNI enforce standard
`networking.k8s.io/v1` `NetworkPolicy` resources instead and do not serve
`CiliumNetworkPolicy`. On GKE, `kix check` passed, and `kix deploy` timed out
waiting for a `CiliumNetworkPolicy` CustomResourceDefinition that nothing in
the cluster installs.

Every platform claim below is marked with its evidence:

- **V (Fn):** verified on a live cluster. `Fn` cites a finding in the
  2026-11-25 GKE test report, and `N1`, `N2`, `N3`, `N4`, and `N5` cite the
  "Network policy facts for the design" section of that report. `AWS Fn` cites a
  finding in the EKS test report from the same day, and `AWS Q1` to `AWS Q8`
  cite the numbered answers in the "Network policy facts for the design" section
  of the EKS test report.
- **D [ref]:** documented by the vendor as of 2026-11-25 (links in `181b_network_policy_platform_facts.md`).
- **A:** unverified assumption.

The EKS network policy tests (AWS F16 to F18, and AWS Q1 to Q8) verified DNS,
cloud identity, classic load balancers, Service address translation, `ipBlock`
matching against pod and node IPs, the API server address a rule must name, the
source of webhook calls, and the pod startup window. Load balancers with IP
targets and Kix-built policy on EKS remain untested (`181b` lists what remains
open).

## 2. How managed cloud platforms enforce policy

The table in `181b_network_policy_platform_facts.md` (section 1) compares
network policy behavior across GKE Dataplane V2, EKS with the Amazon VPC CNI,
and AKS, marking each claim **V**, **D**, or **A**. The decisions below rely on
that table, and the platform behavior flags in decision 2 correspond to its
`ipBlock` and Service address translation rows.

## 3. Decision 1: one set of rule builders, two renderers

**Decision.** Keep a single set of policy rule builders and add a second
renderer that emits standard `NetworkPolicy` resources. The instance providing
the `network-policy-enforcer` role selects the cluster's renderer, so each
cluster uses one renderer. The standard renderer lives in the Kix library
because platforms with built-in `NetworkPolicy` enforcement need nothing extra
installed in the cluster.

**Mechanism.** The enforcer contract (`out.netpol`) already exposes rule
builders named after traffic intent, including `mkServiceEgressRule`,
`mkCallerIngressRule`, `dnsEgressRule`, `apiServerEgressRule`,
`mkExternalIngressRule`, and `translateIntentRules`. The netpol plugin,
`kix.expose`, and roughly 20 packages already construct their policies through
these builders. Today, three Cilium-specific details still leak through that
contract; build step 3 removes them:

1. Callers currently pass the policy target as
   `spec.endpointSelector.matchLabels`. Instead, callers pass `selector`, and
   the renderer writes `endpointSelector` or `podSelector`.
2. `clickhouse-cluster` and `clickhouse-keeper` currently write `toEndpoints`
   and `fromEndpoints` directly. Both move to `mkSelfRules` and
   `mkCallerIngressRule`.
3. `entities` on `meta.network.intents` currently accepts any Cilium entity
   name. Instead, the plugin accepts a fixed list (`world`, `host`,
   `remote-node`, `kube-apiserver`, `cluster`, and `all`), and each renderer
   maps those values to its own format.

A package author then writes:

```nix
kix.operandPolicy {
  inherit scope;
  name = "pg-operand";
  selector = operandSelector;
  egress = [ netpol.dnsEgressRule netpol.apiServerEgressRule ];
}
```

On a Cilium cluster, that call emits the exact `CiliumNetworkPolicy` Kix
produces today. On GKE, it emits a standard `NetworkPolicy`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: pg-operand, namespace: data }
spec:
  podSelector: { matchLabels: { cnpg.io/cluster: pg } }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: node-local-dns } }
      ports: [ { protocol: UDP, port: 53 }, { protocol: TCP, port: 53 } ]
    - to: [ { ipBlock: { cidr: 10.0.0.2/32 } } ]
      ports: [ { protocol: TCP, port: 443 } ]
```

The standard renderer always sets `policyTypes`. When `policyTypes` is omitted,
Kubernetes automatically isolates `Ingress` as well, which would block all
inbound traffic to pods covered by an egress-only policy (D [k-np]).

**Where `NetworkPolicy` differs from Cilium.** Translating a rule to standard
`NetworkPolicy` typically produces one of three outcomes:

- *Same:* allows the same traffic as Cilium.
- *Wider:* allows more traffic than Cilium; Kix reports every widened policy.
- *Refused:* `kix check` fails and names the instance, the rule, and the
  cluster setting needed to express it.

| Rule intent | Cilium output | Standard output | Outcome |
|---|---|---|---|
| Pods by label (in one namespace or all namespaces) | `toEndpoints`, `fromEndpoints` | `podSelector` with `namespaceSelector` | Same |
| Default deny for a namespace | Empty rule per direction | `podSelector: {}` with `policyTypes` | Same |
| DNS egress | Pod peers from `meta.dnsPeers` (`cidr` peers refused) | Pod and `cidr` peers from `meta.dnsPeers` (decision 4) | Same |
| API server egress | `kube-apiserver`, `host`, and `remote-node` | `ipBlock` from `cluster.network.apiServer` (decision 6) | Same when set; refused when unset |
| API server ingress (webhooks) | `kube-apiserver`, `host`, and `remote-node` | Peers from `cluster.network.apiServer.sources` | Same when set; refused when unset |
| `world` egress | `world` entity | `0.0.0.0/0` and `::/0`, always excluding `169.254.0.0/16` and `fe80::/10`, and excluding `cluster.network.podCidr` (where `ipBlockSelectsPods` is `true`), `nodeCidrs` (where `nodeRangeHoldsOnlyNodes` is `true`), and `serviceCidr` (where `ipBlockSeesServiceAddress` is `true`), each only when set | Wider where `0.0.0.0/0` matches pods, nodes, or Services and any matching range stays unexcluded; same once every matching range is excluded. On GKE, `0.0.0.0/0` reaches nodes (V, N2, N4), an `except` entry for the node range removes them (V, N4), and the rule needs no pod range entry because `0.0.0.0/0` never reaches pods (V, N4). `0.0.0.0/0` also reaches the metadata server (V, N4), which would give a pod with a `world` rule on port 80 a path to credentials. To close that path, the standard renderer always excludes the link-local ranges `169.254.0.0/16` and `fe80::/10` from `world` rules, with no setting. A workload that needs a link-local address gets it from its cloud identity mechanism or its DNS peers. On GKE, a `world` egress rule is the same as Cilium's once `cluster.network.nodeCidrs` is set, and wider (nodes admitted) while it is unset. On EKS, `0.0.0.0/0` admits pods and nodes (V, AWS Q3). Where `ipBlockSeesServiceAddress` is `true`, it also admits every Service on that Service port, including the API server on 443 (V, AWS Q1). A `world` rule on EKS still excludes `cluster.network.podCidr` and `serviceCidr` when they are set. The EKS node range is the VPC subnets, which also hold VPC endpoints such as STS, load balancers, and databases, so excluding `cluster.network.nodeCidrs` would cut traffic the workload needs (`nodeRangeHoldsOnlyNodes = false`). Because the platform shares those subnets, the rule stays wider toward the node subnets on EKS, reported under the cause `world-egress-node-subnets` |
| `world` ingress | `world` entity | `0.0.0.0/0` and `::/0`, always excluding `169.254.0.0/16` and `fe80::/10` | On Dataplane V2, never admits pods (V, N1), and whether it admits nodes on ingress is **A**. Wider elsewhere because in-cluster sources also match (required when nodes forward load balancer traffic) |
| `host` and `remote-node` | Entities | `ipBlock` over `cluster.network.nodeCidrs` | Same where `ipBlock` matches nodes, including GKE over `cluster.network.nodeCidrs` (V, N2); refused only when `nodeCidrs` is unset, or on a platform where an `ipBlock` cannot match nodes (AKS with Cilium, D [z-cil]) |
| `all-pods` | `cluster` entity (pods, nodes, and API server) | `namespaceSelector: {}` (pods only) | Narrower (see below) |
| Named port on egress | Cilium drops the traffic (warns today) | Supported | Better |
| `ingressDeny`, `egressDeny` | Passed through | None | Refused |
| Cluster-wide platform intent | `CiliumClusterwideNetworkPolicy` | None | Refused |
| Other entities (`health`, `ingress`) | Entities | None | Refused |
| Readiness wait until policy takes effect | `Valid` condition | No `status` field | Unavailable; Kix applies the policy before the workload and cannot wait for enforcement |

Kix does not generate FQDN or layer 7 rules anywhere today, so the standard
renderer loses neither.

Validation check 12 refuses any `NetworkPolicy` whose `podSelector` matches no
pod template in the build (AWS F17). Policies for operator-created pods and
platform-intent policies target pods that have no template in the build, so
check 12 skips generated policies of those types. When a package defines a
`NetworkPolicy` directly, check 12 honors the `kix.run/operand-of` annotation,
just as check 14 does for a `PodDisruptionBudget`. Honoring
`kix.run/operand-of` needs no renderer and ships first in build step 1 because
defining policies directly is the only way to have network policy on GKE and
EKS today. The skip for generated policies ships with the standard renderer in
step 6.

`all-pods` is the one narrower translation. In the standard renderer, it
matches every pod in every namespace, excluding nodes and the API server. Nine
packages and two flavors currently use `all-pods`. Build step 4 audits those 11
uses and updates any that actually need node or API server access to declare
that explicitly, so the standard renderer either expresses or refuses them.

**Surfacing widened policies.** A new cluster scorecard rule,
`security.networkPolicyWidened`, groups widened policies by cause, reports each
cause once with a policy count, and lists the individual policies under
`kix check -v`. It defaults to a warning; as with any scorecard rule, a cluster
can promote it to an error or accept it with a reason.

**Cost.** Updating roughly 20 packages mechanically, maintaining both renderers
whenever a new rule builder is added, and asking cluster authors on standard
`NetworkPolicy` platforms to configure up to two cluster network facts.

**Rejected.**

- *Add an intermediate rule data model beneath both renderers.* The rule
  builders in `out.netpol` already serve as that interface; adding a separate
  data structure would rewrite every caller for no new capability.
- *Emit standard `NetworkPolicy` on every cluster.* Cilium clusters would lose
  the `kube-apiserver` and `host` entities and the `Valid` readiness condition,
  and would have to declare cluster IP ranges they do not need today.
- *Choose the output format with `cluster.capabilities.networkPolicyAPI`* (the
  earlier `ROADMAP.md` idea). The `network-policy-enforcer` role provider
  already determines the renderer, and a separate switch could contradict it.
- *Derive the renderer from the `cni` role.* Pod networking and network policy
  enforcement are independent settings on EKS, AKS, and k3s.

## 4. Decision 2: flavors declare the platform's enforcer, and Kix refuses a second one

**Decision.** Each flavor declares what enforces network policy by adding a
platform import that claims `network-policy-enforcer` and supplies the renderer
configured with that platform's behavior. Where the platform owns the pod
network, the flavor sets `cluster.roles.network-policy-enforcer.binding =
"exclusive"`. Evaluation then rejects any `cilium` instance up front, keeping
Cilium CRs out of the build (F3, F29).

A flavor module declares:

```nix
cluster.roles.network-policy-enforcer = {
  binding = lib.mkDefault "exclusive";
  provider = lib.mkDefault "GKE Dataplane V2";
};
instances.kube-system.platform-network-policy = platformNetworkPolicy {
  ipBlockSelectsPods = false;
  ipBlockSelectsNodes = true;
  ipBlockSeesServiceAddress = false;
  nodeRangeHoldsOnlyNodes = true;
};
networkPolicy.platformNamespaces = lib.mkDefault [ "kube-system" ];
```

`platform-network-policy` declares five platform facts, corresponding to the
`ipBlock`, Service translation, and pod startup window rows in `181b`, that
determine whether each rule is *same*, *wider*, or *refused* and what widenings
the scorecard rule reports. `ipBlockSelectsPods` and `ipBlockSelectsNodes`
record whether an `ipBlock` matches pod and node addresses. Kix's Service egress
rules use pod selectors, which every tested platform matches on the pod and its
port (V: F21, AWS Q1), so they need no extra port. `ipBlockSeesServiceAddress`
describes `ipBlock` peers instead: `true` means an `ipBlock` is matched against
the Service address and Service port (EKS: V, AWS Q1), and `false` means against
the endpoint address (GKE: V, F21). Kix uses an `ipBlock` toward a Service in
one place only: the API server rule.

`nodeRangeHoldsOnlyNodes` is `true` on `gke` and `gke-autopilot` and `false` on
`eks`. A `world` egress rule excludes `cluster.network.nodeCidrs` only where it
is `true`, because on EKS the node range is the VPC subnets, which also hold VPC
endpoints such as STS, load balancers, and databases. `podStartsBeforePolicy`
declares that a new pod starts before its policies take effect, so the scorecard
rule can report that startup window. The `platformNetworkPolicy` helper defaults
`podStartsBeforePolicy` to `false`, and the `gke` and `gke-autopilot` flavors do
not set it, so Kix reports no startup window on GKE. No live test has measured
whether a new pod on GKE Dataplane V2 has a window before its policies take
effect (**A**), so the value stays `false` until GKE test 11 in `181a` measures
it. On `eks`, the flavor sets `ipBlockSelectsPods = true` (V, AWS Q3),
`ipBlockSelectsNodes = true` (V, AWS Q3 and AWS F18),
`ipBlockSeesServiceAddress = true` (V, AWS Q1),
`nodeRangeHoldsOnlyNodes = false`, and `podStartsBeforePolicy = true` (about
one second of unrestricted egress in the add-on's `standard` mode, V, AWS Q8).

With the flavor in place, a GKE cluster author enables network policy in two
lines:

```nix
networkPolicy.enable = true;
cluster.network.apiServer.cidrs = [ "10.0.0.2/32" ];
```

Behavior per flavor:

| Flavor | Enforcer declaration | Rationale |
|---|---|---|
| `gke`, `gke-autopilot` | Standard renderer, `exclusive` binding | Dataplane V2 enforcement is always on. D [g-dpv2] |
| `eks` | New option `cluster.flavor.eks.networkPolicy`: `"none"` (default) or `"vpc-cni"` | VPC CNI enforcement is off until enabled on the add-on, and Kix cannot read add-on settings at build time (V, AWS F18; D [a-bp]). When `networkPolicy.enable = true` and this option is `"none"`, the flavor fails evaluation and names both the add-on setting and `cluster.flavor.eks.networkPolicy`. |
| `aks` | New option `cluster.flavor.aks.networkPolicy`: `"none"`, `"cilium"`, `"calico"`, or `"azure"` | `"cilium"` uses the Cilium renderer via a `platform-cilium` import because Azure CNI Powered by Cilium serves `CiliumNetworkPolicy` (D [z-cil]). `"calico"` and `"azure"` use the standard renderer. All AKS behavior is **A** until tested on a live AKS cluster. |
| `k3s` | Standard renderer, `shadowable` binding | Stock k3s embeds a policy controller (D [k3s]); `shadowable` still lets clusters replace Flannel with Cilium. |
| `kind` | Standard renderer, `shadowable` binding (once verified on stock kind) | **A:** kind 0.24 and later enforce `NetworkPolicy` by default, letting tests run the standard renderer locally without a cloud cluster. |

Three additional safeguards prevent unserved policy kinds from reaching or
stalling a deploy:

- When `networkPolicy.enable = true` has no enforcer and
  `cluster.roles.cni.binding` is `"exclusive"`, the evaluation error stops
  telling the user to declare a `cilium` instance (the misleading hint behind
  F3).
- A build-time validation check rejects any policy resource whose `kind` is
  neither `NetworkPolicy` nor listed in the enforcer's `policyKinds`.
- Because a cluster author can still override role bindings and assert that the
  cluster serves Cilium kinds, `kix plan` fails immediately when a resource's
  kind is unserved on the live cluster and the build contains only a CRD
  reference with no CRD manifest (F5). Likewise, prune treats resources of an
  unserved kind as already absent (F29).

**Cost.** One new option each on `eks` and `aks` that the user must keep in
sync with the cluster, just like `cluster.flavor.rke2.cni` today. Because the
Kubernetes API server accepts `NetworkPolicy` objects even when nothing
enforces them, Kix cannot verify from API discovery alone that enforcement is
active; section 10 proposes a post-deploy probe.

**Rejected.**

- *Detect the enforcer from the live cluster during evaluation.* Builds must
  stay pure and independent of a live cluster.
- *Enable the standard renderer by default on EKS.* `kix check` would pass on
  clusters where nothing enforces the generated policies.

**Out of scope.** Legacy GKE Calico clusters, EKS Auto Mode (which runs no
CoreDNS pods and serves DNS by IP address; D [a-auto]), and alpha cluster-wide
policy kinds (`ClusterNetworkPolicy` on GKE and EKS).

## 5. Decision 3: cloud identity mechanisms declare their own egress

Each cloud identity mechanism declares the egress rules a pod needs to fetch
credentials. Binding an identity to a `ServiceAccount` adds those rules to the
workload's egress policy. See `181c_network_policy_identity_egress_and_dns.md`
(section 1) for how this works, the rule and evidence for each mechanism, the
cost, and the rejected alternatives.

## 6. Decision 4: the DNS provider publishes its peers

The provider for the `dns` role declares the destinations for DNS queries in
metadata as `meta.dnsPeers`. Both renderers build the DNS rule from that list:
the standard renderer accepts pod and `cidr` peers, and the Cilium renderer
refuses `cidr` peers until a platform that runs Cilium needs one. See
`181c_network_policy_identity_egress_and_dns.md` (section 2) for how this
works, the peers listed in the GKE flavors and the evidence for each, the cost,
and the rejected alternatives.

## 7. Decision 5: Kix writes policy only over pods it deploys

**Decision.** Kix writes policy only over pods it deploys (and over targets in
namespaces isolated by default deny), with default deny, scrape ingress, and
caller ingress all reading one fact per target: whether Kix deploys it. The
netpol module computes the list of default-deny namespaces once: the namespaces
that hold an active instance Kix deploys, plus the namespaces declared under
`namespaces`, minus `networkPolicy.platformNamespaces`. Imports
(`kix.mkImport`) and inactive optional instances do not count as active
instances Kix deploys. A connection target that comes from an import is marked
as imported, so each connection knows whether Kix deploys its target. Default
deny, scrape ingress, and caller ingress read the same list and mark. Kix
writes `<namespace>-default-deny` for each default-deny namespace, and writes a
caller-ingress or scrape-ingress policy over a target only when Kix deploys the
target or the target is in a default-deny namespace.

Cloud flavors default `networkPolicy.platformNamespaces` to
`[ "kube-system" ]`. Any workload Kix deploys into `kube-system` still gets its
own pod-selecting policies (which isolate the selected pods in Kubernetes),
while cloud-managed `kube-system` pods remain untouched. Self-managed and local
flavors (`kind`, `k3s`, `rke2`, and `talos`) leave `platformNamespaces` empty,
so their behavior does not change. `kind` and `rke2` continue describing their
`kube-system` pods with `networkPolicy.platformIntents`, while `k3s` and
`talos` declare none.

Because caller ingress and scrape ingress check both the imported mark and the
default-deny namespace list, a workload's connection to an import outside the
default-deny namespaces (for example, `kube-dns` in `kube-system` on a cloud
flavor) gets no caller-ingress or scrape-ingress policy over the platform's
pods. Kix still writes the caller's own egress rule. When an imported target is
in a default-deny namespace, default deny isolates that namespace, so Kix still
writes caller-ingress and scrape-ingress policies for it. The `service-ref`
package is an instance Kix manages, so its target counts as deployed, as
before. Outside default-deny namespaces, explicit
`networkPolicy.platformIntents` entries remain the way to write policy over
pods that Kix does not deploy.

**Cost.** On upgrade, a namespace containing only imports loses its
default-deny policy without a build error. That requires a `silent`
breaking-change record and a minor version bump; declaring the namespace under
`namespaces` preserves the previous default-deny policy.

**Rejected.** *Describe each cloud provider's `kube-system` pods with
`platformIntents`.* Cloud providers change `kube-system` pods across cluster
versions, so static rules could break cluster DNS or the metrics API during
routine control-plane upgrades.

## 8. Decision 6: declare API server addresses explicitly, and allow `0.0.0.0/0` for load balancers

**API server egress.** Standard `NetworkPolicy` has no built-in entity for the
API server, so the cluster author declares how pods reach it:

```nix
cluster.network.apiServer = {
  cidrs = [ "10.0.0.2/32" ];   # what policy sees when a pod calls the API
  port = 443;                  # default
  sources = [ ];               # where webhook calls come from
};
```

Workloads bound to a `Role` or `ClusterRole` get egress to `cidrs` on `port`.
Which address `cidrs` holds depends on `ipBlockSeesServiceAddress`. On GKE
(`false`), it is the control-plane endpoint address (V, F21). On EKS (`true`),
`cluster.network.apiServer.cidrs` holds the cluster IP of the `kubernetes`
`Service`, which is the first address of the Service range and does not change
(V, AWS Q2). Where `ipBlockSeesServiceAddress` is `true` and
`cluster.network.serviceCidr` is set, Kix derives `cidrs` from it, so the
cluster author sets one of the two. When a policy needs API server egress and
`cidrs` is empty, `kix check` fails and prints the platform-specific command to
look up the address. Before applying resources, `kix deploy` compares `cidrs`
with the live `kubernetes` `Service` address where `ipBlockSeesServiceAddress`
is `true` and with the `EndpointSlice` addresses where it is `false`, stopping
and reporting the live address if `cidrs` does not cover it (for example, after
a control-plane IP rotation).

**API server ingress.** Eleven packages expose admission webhooks or aggregated
APIs (`from = "apiserver"`), which generate ingress rules from `sources`. On
GKE, the source can only be a pod selector for the `konnectivity-agent` pods
(`k8s-app: konnectivity-agent` in `kube-system`), because no `ipBlock` admitted
the calls (V, N1); the `gke` and `gke-autopilot` flavors default
`cluster.network.apiServer.sources` to those pods. A private GKE cluster or one
without konnectivity is untested (**A**). On EKS, webhook calls come from the
control plane's network interfaces in the cluster subnets, and their addresses
change (V, AWS Q6; D [a-net]), so the cluster author sets
`cluster.network.apiServer.sources` to the range of the cluster subnets (or
`kix check` fails when a package needs it). The `eks` flavor cannot default
`sources` because it does not know the VPC range. That range also holds nodes
and pods, so the rule admits them too (V, AWS Q3), and `networkPolicyWidened`
reports it.

**Load balancer ingress.** Backend pods for `LoadBalancer` Services allow
ingress from `0.0.0.0/0`. That worked on GKE behind a passthrough Network Load
Balancer (V, F21). On EKS behind a classic load balancer, `0.0.0.0/0` allowed
the traffic; the pod saw a node address with `externalTrafficPolicy: Cluster`
and the load balancer's own VPC address with `Local` (V, AWS F18 and AWS Q7).
Load balancers with IP targets remain untested (**A**). `0.0.0.0/0` is the only
CIDR rule that works across every AWS target mode, since traffic can arrive from
a node IP, a load balancer IP, or the client IP (D [a-lb]). Where `ipBlock`
matches pod IPs, `0.0.0.0/0` is wider than Cilium's `world` entity, and
`networkPolicyWidened` reports it.

**Cost.** One API server address per cluster to look up and update after GKE IP
rotations (D [g-iprot]).

**Rejected.**

- *Read the API server IP from the live cluster during `kix deploy` and fill it
  in.* Applied policies would diverge from built manifests, and nothing would
  update the policy if the IP rotated between deploys.
- *Allow outbound TCP 443 to `0.0.0.0/0` for API server access.* Every workload
  with a `RoleBinding` or `ClusterRoleBinding` would gain outbound HTTPS access
  to the internet.

On GKE, a rule to `host` or `remote-node` needs `cluster.network.nodeCidrs` to
cover the whole node range (V, N2), and `kix check` refuses the rule when
`nodeCidrs` is unset. Prometheus scraping kubelets on GKE therefore works once
`nodeCidrs` is set.

## 9. Build plan

`181a_network_policy_on_clouds_build_plan.md` lists the eleven implementation
steps, their dependency order, each step's change record kind, and the live GKE
and EKS test plans. Only two steps are breaking changes: the default-deny
namespace rule in decision 5 (`silent`) and, one minor release later, removing
the legacy `spec` argument (`error`). No other step changes what existing
clusters build.

## 10. Decisions for the maintainer

1. **Remove `kix.operandPolicy { spec }` one minor release after shipping
   `selector`, `ingress`, and `egress`?** Recommended: yes. Keeping `spec`
   leaves Cilium's `endpointSelector` shape in Kix's public package API and
   would force the standard renderer to parse Cilium specs.
2. **Require `cluster.network.apiServer.cidrs` as an explicit cluster option?**
   Recommended: yes. It adds one line per cluster, keeps builds deterministic,
   and fails fast at `kix deploy` when stale. The only zero-line alternative is
   rewriting policies at deploy time.
3. **Default `networkPolicyWidened` to a warning?** Recommended: yes. An
   `ipBlock` matches pod IPs on the VPC CNI (V, AWS Q3), so every EKS cluster
   with a `world` rule triggers at least one widened policy; defaulting to an
   error would block EKS clusters out of the box.
4. **Apply the default-deny namespace rule of decision 5 across all flavors
   (`silent` breaking change)?** Recommended: yes, so every flavor follows one
   rule. The alternative is keeping the old rule and adding only
   `networkPolicy.platformNamespaces`, which leaves F4's root cause in place
   for namespaces holding only imports.
5. **Add a post-deploy enforcement probe as a follow-up step?** Recommended:
   yes. After `kix deploy`, a short `Job` in a Kix-managed namespace attempts a
   connection that default-deny must block, failing the deploy if it connects.
   Without a probe, a cluster whose declared enforcer is turned off passes
   every check.
6. **Default `cluster.flavor.eks.networkPolicy` to `"none"`?** Recommended:
   yes, because AWS disables enforcement by default on new EKS clusters.
7. **Report the EKS startup window as a widening?** Recommended: yes. On EKS, a
   new pod runs for about one second with no policy applied in `standard` mode
   (V, AWS F18 and AWS Q8). The `eks` flavor declares that window with
   `podStartsBeforePolicy = true` under `"vpc-cni"`, and `networkPolicyWidened`
   reports it once per cluster. The add-on's `strict` mode closes the window,
   but it also blocks every pod that has no policy, including the `kube-system`
   pods that decision 5 leaves untouched. Kix should not require `strict` mode
   until a flavor can describe those pods.

## 11. Evidence

`181b_network_policy_platform_facts.md` records the platform evidence for this
design: the comparison table in section 1, the verified EKS test findings
(**V**) and open EKS assumptions (**A**) in section 2, and the documentation
links in section 3 for every **D** mark.

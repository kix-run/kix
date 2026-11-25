# 181: Network policy on managed clouds

**Status:** Draft (2026-11-25). Proposed design; implementation has not started. Section 10 lists the decisions needed from the maintainer.
**Related:** `121_netpol_as_plugin.md` (section 5, the envelope repair scheduled here), `95_netpol_build_time_validation.md`, `177_workload_cloud_identity.md`, `180_cloud_identity_across_packages.md`, `housekeeping/2026-11-24-only-cilium-enforces-generated-network-policy.md`, `kix/lib/plugins/netpol/`, `kix/packages/experimental/cilium/netpol-rules.nix`

## 1. Context

We tested Kix on live GKE and EKS clusters for the first time on 2026-11-25.
Today, `networkPolicy.enable = true` emits only `CiliumNetworkPolicy`
resources. GKE Dataplane V2 and the Amazon VPC CNI enforce standard
`networking.k8s.io/v1` `NetworkPolicy` resources instead and do not serve
`CiliumNetworkPolicy`. On GKE, `kix check` passed, and `kix deploy` timed out
waiting for a `CiliumNetworkPolicy` CustomResourceDefinition that nothing in
the cluster installs.

Every platform claim below is marked with its evidence:

- **V (Fn):** verified on a live cluster (`Fn` cites the finding in the
  2026-11-25 GKE test report).
- **D [ref]:** documented by the vendor as of 2026-11-25 (links in section 12).
- **A:** unverified assumption.

The live EKS network policy test ("test C") had not been written when this doc
was drafted, so every EKS claim is marked **D** or **A**. Section 11 lists what
those test results could change.

## 2. How managed cloud platforms enforce policy

| Behavior | GKE Dataplane V2 | EKS with Amazon VPC CNI | AKS |
|---|---|---|---|
| Enforces standard `NetworkPolicy` | Always on, with no toggle. V (F19), D [g-dpv2] | Off on new clusters; requires setting `enableNetworkPolicy` on the add-on. D [a-bp] | Depends on the chosen policy engine: none, Azure NPM, Calico, or Cilium. D [z-np] |
| Serves `CiliumNetworkPolicy` | No. V (F3) | No. A | Yes (layers 3 and 4) on Azure CNI Powered by Cilium. D [z-cil] |
| `ipBlock` matches pod IPs | Never. D [g-np] | Unknown (A: yes) | Never on Cilium. D [z-cil] |
| `ipBlock` or selector matches nodes and host-network pods | No field can match them. D [g-np] | Unknown (A: `ipBlock` can) | Never on Cilium. D [z-cil] |
| When policy evaluates Service calls | After Service address translation; rules must match the endpoint IP. V (F21) | A: before translation. AWS docs require the Service port to match the container port. D [a-np] | Unknown |
| Where cluster DNS answers from | `kube-dns` pods, or `node-local-dns` pods when NodeLocal DNSCache is enabled (default from 1.34). V (F20), D [g-nldns]. With Cloud DNS (Autopilot default): `169.254.169.254` or `169.254.20.10`. D [g-clouddns] | CoreDNS pods labeled `k8s-app: kube-dns`. D [a-bp] | CoreDNS pods, or LocalDNS at `169.254.10.10` and `169.254.10.11`. D [z-ldns] |
| How pods reach the API server | Control-plane internal IP on TCP 443; changes during IP rotation. V (F21), D [g-iprot] | Network interfaces in the cluster subnets; changes on cluster version upgrades. D [a-net] | Varies by cluster type. D [z-wi] |
| Outbound traffic needed for cloud identity | `169.254.169.254/32` on TCP 80 (V, F19) and TCP 8080 (D [g-np]) | IRSA: STS endpoint on TCP 443. D [a-sts]. Pod Identity: host-network agent at `169.254.170.23` on TCP 80. D [a-pi] | `login.microsoftonline.com` on TCP 443; no metadata IP. D [z-wi] |
| Pod startup window | Unknown | In the default `standard` mode, all traffic is allowed until the pod's policies load. D [a-npcfg] | Unknown |

Kubernetes leaves it up to each network plugin how `ipBlock` handles in-cluster
pods, nodes, and Service address translation (D [k-np]). Because of that, each
platform flavor must declare those behaviors explicitly for Kix.

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
| DNS egress | Pods from the DNS provider | Peers from `out.dnsPeers` (decision 4) | Same |
| API server egress | `kube-apiserver`, `host`, and `remote-node` | `ipBlock` from `cluster.network.apiServer` (decision 6) | Same when set; refused when unset |
| API server ingress (webhooks) | `kube-apiserver`, `host`, and `remote-node` | Peers from `cluster.network.apiServer.sources` | Same when set; refused when unset |
| `world` egress | `world` entity | `0.0.0.0/0` and `::/0`, excluding `cluster.network.podCidr` and `nodeCidrs` when set | Same where `ipBlock` never matches pods; wider where it does and those CIDRs are unset |
| `world` ingress | `world` entity | `0.0.0.0/0` and `::/0` | Same on Dataplane V2. Wider elsewhere because in-cluster sources also match (required when nodes forward load balancer traffic) |
| `host` and `remote-node` | Entities | `ipBlock` over `cluster.network.nodeCidrs` | Same where `ipBlock` can match nodes; refused where it cannot (such as GKE) or when `nodeCidrs` is unset |
| `all-pods` | `cluster` entity (pods, nodes, and API server) | `namespaceSelector: {}` (pods only) | Narrower (see below) |
| Named port on egress | Cilium drops the traffic (warns today) | Supported | Better |
| `ingressDeny`, `egressDeny` | Passed through | None | Refused |
| Cluster-wide platform intent | `CiliumClusterwideNetworkPolicy` | None | Refused |
| Other entities (`health`, `ingress`) | Entities | None | Refused |
| Readiness wait until policy takes effect | `Valid` condition | No `status` field | Unavailable; Kix applies the policy before the workload and cannot wait for enforcement |

Kix does not generate FQDN or layer 7 rules anywhere today, so the standard
renderer loses neither.

`all-pods` is the one narrower translation. In the standard renderer, it
matches every pod in every namespace, excluding nodes and the API server. Nine
packages and two flavors currently use `all-pods`. Build step 4 audits those 11
uses and updates any that actually need node or API server access to declare
that explicitly, so the standard renderer either expresses or refuses them.

**Surfacing widened policies.** A new cluster scorecard rule,
`networkPolicyWidened`, groups widened policies by cause, reports each cause
once with a policy count, and lists the individual policies under
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

## 4. Decision 2: flavors declare the platform enforcer and block conflicting CNIs

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
  ipBlockSelectsNodes = false;
  egressBeforeServiceTranslation = false;
};
networkPolicy.platformNamespaces = lib.mkDefault [ "kube-system" ];
```

Those three flags correspond to the `ipBlock` and Service translation rows in
section 2 and determine whether each rule is *same*, *wider*, or *refused*.
When `egressBeforeServiceTranslation = true`, a Service egress rule allows both
the Service port and the pod port.

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
| `eks` | New option `cluster.flavor.eks.networkPolicy`: `"none"` (default) or `"vpc-cni"` | VPC CNI enforcement is off until enabled on the add-on, and Kix cannot read add-on settings at build time (D [a-bp]). When `networkPolicy.enable = true` and this option is `"none"`, the flavor fails evaluation and names both the add-on setting and `cluster.flavor.eks.networkPolicy`. |
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

**Decision.** Each cloud identity mechanism declares the outbound traffic a pod
needs to fetch credentials. Binding an identity to a `ServiceAccount`
automatically adds those rules to the egress policy of every workload running as
that `ServiceAccount`. Package authors write nothing extra.

`kix/lib/vocab/cloud-identity-mechanisms.nix` adds an `egress` field to each
mechanism, using the existing intent vocabulary plus a new `"node-local"`
target for link-local addresses on the pod's own node:

```nix
gke = mkMechanism {
  # ...
  egress = [ { to = "node-local"; cidr = "169.254.169.254/32"; ports = [ (tcp 80) (tcp 8080) ]; } ];
};
```

| Mechanism | Required egress | Standard renderer | Cilium renderer | Evidence |
|---|---|---|---|---|
| `gke` | `169.254.169.254/32` TCP 80, 8080 | `ipBlock` | Unused (GKE serves no Cilium kind) | Port 80: V (F19). Port 8080: D [g-np] |
| `irsa` | `world` TCP 443 (STS) | `0.0.0.0/0` | `world` entity | Endpoint: D [a-sts]. **A** that nothing else is needed |
| `eks-pod-identity` | `169.254.170.23/32` and `fd00:ec2::23/128` TCP 80 | `ipBlock` | Both `toCIDR` and `host` entity on TCP 80 | Addresses: D [a-pi]. **A** whether VPC CNI needs an explicit rule (it always allows traffic to the pod's own node; D [a-bp]), and **A** on Cilium |
| `azure-workload-id` | `world` TCP 443 | `0.0.0.0/0` | `world` entity | D [z-wi] |

For `"node-local"` targets, the Cilium renderer writes both `toCIDR` and the
`host` entity because Microsoft documents that node-bound link-local addresses
matched `toCIDR` through Cilium 1.16 and switched to the `host` entity in
Cilium 1.17 (D [z-ldns]). Allowing `host` on that port also admits any other
host-network listener using the same port on the node, so
`networkPolicyWidened` reports that widening on Cilium.

The workload builder already passes bound identity metadata into the pod
template for `checksum/cloud-identity`; it passes `egress` along the same path
so the netpol workload hook can append the rules. For operator-created pods
(such as `cnpg-cluster`), the identity dependency exposes `networkIntents`,
which the package passes into its `kix.operandPolicy` call.

On GKE, even a pod with no linked Google service account still queries the
metadata server to call Google Cloud APIs (F12). Packages request that egress
rule by binding `kix.cloudIdentity.gcp { }`.

**Cost.** IRSA and Microsoft Entra Workload ID open outbound TCP 443 to any
external IP because Kix generates no hostname-based rules. Most workloads with
a cloud identity already hold that rule to reach the cloud APIs themselves.

**Rejected.**

- *Declare credential egress in each package's `meta.network.intents`.* A
  package does not know which cloud identity mechanism the cluster uses.
- *Open credential endpoints for every pod in the cluster.* Pods that do not
  use cloud credentials would gain network access to the credential endpoint.

## 6. Decision 4: the DNS provider publishes its peers

**Decision.** The instance claiming the `dns` role exports its DNS endpoints as
`out.dnsPeers`, and both renderers build `dnsEgressRule` from that list instead
of hard-coding `k8s-app: kube-dns`.

```nix
# kix/lib/flavors/gke.nix
platform-dns = platformDns {
  name = "kube-dns";
  namespace = "kube-system";
  peers = [
    { namespace = "kube-system"; podSelector = { k8s-app = "kube-dns"; }; }
    { namespace = "kube-system"; podSelector = { k8s-app = "node-local-dns"; }; }
    { cidr = "169.254.169.254/32"; }
    { cidr = "169.254.20.10/32"; }
  ];
};
```

`peers` defaults to `k8s-app: kube-dns` in `kube-system`, so existing clusters
produce identical manifests. The `coredns` package exports its own pod
selector, and the `cilium` package's cluster-wide DNS policy reads the same
`out.dnsPeers` value.

The GKE flavors list all four documented GKE DNS destinations. Any single GKE
cluster uses only one or two of them, and rules for absent peers open nothing
beyond port 53 on `169.254.169.254/32`, avoiding a separate per-cluster DNS
mode setting.

| DNS peer | Evidence |
|---|---|
| `kube-dns` pods (without NodeLocal DNSCache) | **A:** the `kube-dns` Service uses these labels (F20), though this path was not tested live |
| `node-local-dns` pods | V (F20) |
| `169.254.169.254` and `169.254.20.10` (Cloud DNS) | D [g-clouddns]. **A** that `ipBlock` rules reach them; requires testing on GKE Autopilot |
| EKS CoreDNS pods | D [a-bp] |

**Cost.** One additional field (`out.dnsPeers`) on the `dns` role's `out`.

**Rejected.** *Allow outbound port 53 to any IP address.* Unrestricted DNS
egress is a well-known data exfiltration channel.

## 7. Decision 5: generate default-deny only for Kix-managed namespaces

**Decision.** Kix writes `<namespace>-default-deny` only when a namespace holds
at least one active instance that Kix deploys, or when the cluster definition
explicitly declares that namespace under `namespaces`. Imports (`kix.mkImport`)
and inactive optional instances do not count. In addition, Kix never writes a
default-deny policy in any namespace listed in
`networkPolicy.platformNamespaces`.

Cloud flavors default `networkPolicy.platformNamespaces` to
`[ "kube-system" ]`. Any workload Kix deploys into `kube-system` still gets its
own pod-selecting policies (which isolate the selected pods in Kubernetes),
while cloud-managed `kube-system` pods remain untouched. Self-managed and local
flavors (`kind`, `k3s`, `rke2`, and `talos`) leave `platformNamespaces` empty
and continue describing their `kube-system` pods with
`networkPolicy.platformIntents`.

Inside a `platformNamespaces` namespace, Kix also writes no policy selecting
pods that Kix does not deploy, unless configured in
`networkPolicy.platformIntents`.

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
When a policy needs API server egress and `cidrs` is empty, `kix check` fails
and prints the platform-specific command to look up the address. Before
applying resources, `kix deploy` compares `cidrs` against the live `kubernetes`
`Service` and `EndpointSlice` and stops if neither is covered, reporting the
live address immediately after a control-plane IP rotation.

Which address `cidrs` must list depends on when the CNI evaluates policy: on
GKE, it is the control-plane endpoint IP (V, F21); on EKS, it is likely the
`kubernetes` `Service` ClusterIP if the VPC CNI evaluates policy before Service
translation (**A**).

**API server ingress.** Eleven packages expose admission webhooks or aggregated
APIs (`from = "apiserver"`), which generate ingress rules from `sources`.
Vendor docs do not state the exact source IPs of webhook calls: on GKE, the
candidates are `konnectivity-agent` pods or the control-plane CIDR; on EKS, the
cluster subnet CIDRs (D [a-net]). Once the live tests in `181a` identify the
source on each cloud, each flavor can set a default where possible; until then,
the cluster author sets `sources` or `kix check` fails.

**Load balancer ingress.** Backend pods for `LoadBalancer` Services allow
ingress from `0.0.0.0/0`. That worked on GKE behind a passthrough Network Load
Balancer (V, F21), and it is the only CIDR rule that works across every AWS
target mode, where traffic can arrive from a node IP, a load balancer IP, or
the client IP (D [a-lb]). Where `ipBlock` matches pod IPs, `0.0.0.0/0` is wider
than Cilium's `world` entity, and `networkPolicyWidened` reports it.

**Cost.** One API server address per cluster to look up and update after GKE IP
rotations (D [g-iprot]).

**Rejected.**

- *Read the API server IP from the live cluster during `kix deploy` and fill it
  in.* Applied policies would diverge from built manifests, and nothing would
  update the policy if the IP rotated between deploys.
- *Allow outbound TCP 443 to `0.0.0.0/0` for API server access.* Every workload
  with a `RoleBinding` or `ClusterRoleBinding` would gain outbound HTTPS access
  to the internet.

**Known limitation.** GKE `NetworkPolicy` has no field that selects node IPs or
host-network pods (D [g-np]), so `kix check` refuses rules targeting `host` or
`remote-node` on GKE. That blocks egress enforcement for workloads such as
Prometheus scraping kubelets or host-network exporters on other nodes; affected
GKE clusters must set `networkPolicy.directions = "ingress"` today.

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
3. **Refuse `host` and `remote-node` peers on GKE?** Recommended: yes,
   documenting `networkPolicy.directions = "ingress"` as the workaround
   (decision 6). The alternative is omitting the rule with a warning and
   letting node scrapes fail at runtime.
4. **Default `networkPolicyWidened` to a warning?** Recommended: yes. Almost
   every EKS cluster will trigger at least one widened policy, so defaulting to
   an error would block EKS clusters out of the box.
5. **Apply the stricter default-deny namespace rule across all flavors (`silent`
   breaking change)?** Recommended: yes, so every flavor follows one rule. The
   alternative is keeping the old rule and adding only
   `networkPolicy.platformNamespaces`, which leaves F4's root cause in place
   for namespaces holding only imports.
6. **Add a post-deploy enforcement probe as a follow-up step?** Recommended:
   yes. After `kix deploy`, a short `Job` in a Kix-managed namespace attempts a
   connection that default-deny must block, failing the deploy if it connects.
   Without a probe, a cluster whose declared enforcer is turned off passes
   every check.
7. **Default `cluster.flavor.eks.networkPolicy` to `"none"`?** Recommended:
   yes, because AWS disables enforcement by default on new EKS clusters.

## 11. What the EKS tests could change

Decisions 1, 2, 4, and 5 do not depend on the live EKS results. These details
in decisions 2, 3, and 6 do:

- **VPC CNI behavior flags:** whether `ipBlock` matches pod and node IPs, and
  whether policy evaluates Service calls before translation (if after,
  `egressBeforeServiceTranslation` goes away).
- **`cluster.network.apiServer.cidrs` on EKS:** which IP it must hold, and
  whether the `eks` flavor can derive it automatically from
  `cluster.network.serviceCidr`.
- **EKS Pod Identity egress:** whether Pod Identity needs an explicit
  `169.254.170.23/32` rule if the VPC CNI always allows traffic to the pod's
  own node (leaving `egress` empty on the standard renderer).
- **Default `cluster.network.apiServer.sources` on EKS:** which source ranges
  webhook requests arrive from.
- **Startup policy window:** whether `standard` mode leaves new pods briefly
  open in practice, and whether the `eks` flavor should require VPC CNI
  `strict` mode.
- **AWS rule-count limits:** AWS allows 24 port/protocol pairs per CIDR across
  all policies (D [a-np]), and `0.0.0.0/0` rules from multiple packages share
  one range.

## 12. Sources

- [g-np] https://docs.cloud.google.com/kubernetes-engine/docs/how-to/network-policy
- [g-dpv2] https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2
- [g-nldns] https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nodelocal-dns-cache
- [g-clouddns] https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cloud-dns
- [g-iprot] https://docs.cloud.google.com/kubernetes-engine/docs/how-to/ip-rotation
- [a-np] https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html
- [a-npcfg] https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html
- [a-bp] https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html
- [a-pi] https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- [a-lb] https://docs.aws.amazon.com/eks/latest/best-practices/load-balancing.html
- [a-sts] https://docs.aws.amazon.com/eks/latest/userguide/configure-sts-endpoint.html
- [a-net] https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html
- [a-auto] https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html
- [z-np] https://learn.microsoft.com/en-us/azure/aks/use-network-policies
- [z-cil] https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium
- [z-wi] https://learn.microsoft.com/en-us/azure/aks/outbound-rules-control-egress
- [z-ldns] https://learn.microsoft.com/en-us/azure/aks/localdns-custom
- [k-np] https://kubernetes.io/docs/concepts/services-networking/network-policies/
- [k3s] https://docs.k3s.io/networking/networking-services

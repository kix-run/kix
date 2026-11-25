# 181: Network policy on managed clouds

**Status:** Draft. Decisions proposed on 2026-11-25, not built. Section 10 lists what the maintainer must decide.
**Related:** `121_netpol_as_plugin.md` (section 5, the envelope repair this doc schedules), `95_netpol_build_time_validation.md`, `177_workload_cloud_identity.md`, `180_cloud_identity_across_packages.md`, `housekeeping/2026-11-24-only-cilium-enforces-generated-network-policy.md`, `kix/lib/plugins/netpol/`, `kix/packages/experimental/cilium/netpol-rules.nix`

## 1. Context

Kix ran on real GKE and EKS clusters for the first time on 2026-11-25. Kix
writes only `CiliumNetworkPolicy`. GKE Dataplane V2 and the Amazon VPC CNI
enforce the standard `networking.k8s.io/v1` `NetworkPolicy` and do not serve
the Cilium kind. On GKE, `kix check` passed and the deploy timed out waiting
for a CustomResourceDefinition that nothing installs.

Every platform fact below carries one of three marks:

- **V (Fn):** verified on a live cluster. `Fn` is the finding in the GKE test
  report of 2026-11-25.
- **D [ref]:** from the platform's documentation, read on 2026-11-25. Section
  12 holds the links.
- **A:** assumption. Nothing confirms it yet.

The EKS test of network policy (its "test C") had not been written when this
doc was finished. Every EKS fact is D or A. Section 11 says what the EKS
results can change.

## 2. What the platforms do

| Fact | GKE Dataplane V2 | EKS with the VPC CNI | AKS |
|---|---|---|---|
| Enforces standard `NetworkPolicy` | Always, no setting. V (F19), D [g-dpv2] | Only after the add-on sets `enableNetworkPolicy`. Off on a new cluster. D [a-bp] | Depends on the engine chosen: none, Azure NPM, Calico, or Cilium. D [z-np] |
| Serves `CiliumNetworkPolicy` | No. V (F3) | No. A | Yes, layers 3 and 4, on Azure CNI Powered by Cilium. D [z-cil] |
| An `ipBlock` matches pod addresses | Never. D [g-np] | Unknown. A: yes | Never on Cilium. D [z-cil] |
| An `ipBlock` or selector matches nodes and host-network pods | No field can. D [g-np] | Unknown. A: `ipBlock` can | Not on Cilium. D [z-cil] |
| Policy sees a Service call before or after address translation | After. The rule must name the endpoint address. V (F21) | A: before. Docs require the Service port to equal the container port. D [a-np] | Unknown |
| Cluster DNS answers from | `kube-dns` pods, or `node-local-dns` pods when NodeLocal DNSCache is on (default from 1.34). V (F20), D [g-nldns]. With Cloud DNS (Autopilot default): `169.254.169.254` or `169.254.20.10`. D [g-clouddns] | CoreDNS pods labelled `k8s-app: kube-dns`. D [a-bp] | CoreDNS pods, or LocalDNS on `169.254.10.10` and `.11`. D [z-ldns] |
| API server as pods reach it | The control plane's internal address, TCP 443. It changes on IP rotation. V (F21), D [g-iprot] | Network interfaces in the cluster subnets. They change on a version upgrade. D [a-net] | Varies with the cluster type. D [z-wi] |
| Cloud identity needs egress to | `169.254.169.254/32` TCP 80 (V, F19) and 8080 (D [g-np]) | IRSA: the STS endpoint, TCP 443. D [a-sts]. Pod Identity: `169.254.170.23` TCP 80, a host-network agent. D [a-pi] | `login.microsoftonline.com` TCP 443, no metadata address. D [z-wi] |
| A pod's first moments | Unknown | The pod starts with everything allowed until its policies load, in the default `standard` mode. D [a-npcfg] | Unknown |

Kubernetes leaves `ipBlock` behaviour inside the cluster, and under address
rewriting, to the network plugin. D [k-np]. Kix therefore needs those rows as
declared facts.

## 3. Decision 1: one set of rule builders, two renderers

**Decision.** Kix keeps one description of each policy and gains a second
renderer for it. The `network-policy-enforcer` role chooses the renderer. A
cluster has one renderer. The standard renderer is library code, because a
platform that enforces `NetworkPolicy` needs nothing installed.

**Mechanism.** The enforcer contract (`out.netpol`) is already a set of rule
builders named for what a rule means: `mkServiceEgressRule`,
`mkCallerIngressRule`, `dnsEgressRule`, `apiServerEgressRule`,
`mkExternalIngressRule`, `translateIntentRules`. The netpol plugin, `kix.expose`,
and about 20 packages build every policy through them. Those builders are the
policy intent. Three things leak Cilium through the contract today, and the
first build step removes them:

1. Callers write the policy's subject as `spec.endpointSelector.matchLabels`.
   It becomes an argument, `selector`, and the renderer writes
   `endpointSelector` or `podSelector`.
2. `clickhouse-cluster` and `clickhouse-keeper` write `toEndpoints` and
   `fromEndpoints` directly. They move to `mkSelfRules` and
   `mkCallerIngressRule`.
3. `entities` on `meta.network.intents` takes any Cilium entity name. The
   plugin accepts a closed list (`world`, `host`, `remote-node`,
   `kube-apiserver`, `cluster`, `all`) and each renderer maps it.

A package author then writes:

```nix
kix.operandPolicy {
  inherit scope;
  name = "pg-operand";
  selector = operandSelector;
  egress = [ netpol.dnsEgressRule netpol.apiServerEgressRule ];
}
```

On GKE, Kix emits a `NetworkPolicy`. On a Cilium cluster the same call emits
today's `CiliumNetworkPolicy`, byte for byte:

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

The standard renderer always writes `policyTypes`. Kubernetes adds `Ingress`
to a policy that omits the field, which would cut all ingress to the pods of
an egress-only policy. D [k-np].

**What the standard kind cannot express.** Each case has one of three
outcomes. *Same* means the policy allows the same traffic. *Wider* means it
allows more, and Kix reports it. *Refused* means `kix check` fails and names
the instance, the rule, and the setting that would make the rule expressible.

| What Kix asks for | Cilium output | Standard output | Outcome |
|---|---|---|---|
| Pods by label, in one namespace or any | `toEndpoints`, `fromEndpoints` | `podSelector` with `namespaceSelector` | Same |
| Default deny for a namespace | Empty rule per direction | `podSelector: {}` with `policyTypes` | Same |
| DNS | Pods from the DNS provider | The DNS provider's peers (decision 4) | Same |
| API server, egress | `kube-apiserver`, `host`, `remote-node` | `ipBlock` from `cluster.network.apiServer` (decision 6) | Same when the fact is set. Refused when it is not |
| API server, ingress (webhooks) | Same three entities | Peers from `cluster.network.apiServer.sources` | Same when set. Refused when not |
| `world`, egress | `world` entity | `0.0.0.0/0` and `::/0`, except `cluster.network.podCidr` and `nodeCidrs` when set | Same where an `ipBlock` never matches pods. Wider where it does and the ranges are unset |
| `world`, ingress | `world` entity | `0.0.0.0/0` and `::/0` | Same on Dataplane V2. Wider elsewhere: in-cluster sources are admitted too, which load balancer traffic forwarded by a node needs |
| `host`, `remote-node` | Entities | `ipBlock` over `cluster.network.nodeCidrs` | Same where an `ipBlock` can match nodes. Refused where it cannot (GKE), or when the range is unset |
| `all-pods` | `cluster` entity: pods, nodes, API server | `namespaceSelector: {}`: pods only | Narrower. See below |
| A named port on egress | Cilium drops the traffic (today's warning) | Supported | Better |
| `ingressDeny`, `egressDeny` | Passed through | None | Refused |
| A cluster-wide platform intent | `CiliumClusterwideNetworkPolicy` | None | Refused |
| Other entities (`health`, `ingress`) | Entities | None | Refused |
| Waiting until a policy is in force | `Valid` condition | No status | Not available. Kix applies the policy before the workload and cannot wait for the platform |

Kix generates no FQDN rule and no layer 7 rule anywhere, so the standard
renderer loses none.

`all-pods` is the one narrower case. On the standard renderer it means every
pod in every namespace, without nodes or the API server. Nine packages and
two flavours use it. Build step 4 reads each use and changes the ones that
need nodes or the API server to say so. The rule is then expressed or refused.

**How a wider policy becomes visible.** A new cluster scorecard rule,
`networkPolicyWidened`, reports each class of widening once with the number of
policies, and lists them under `kix check -v`. It is a warning by default. A
cluster can raise it to an error or accept it with a reason, as with any rule.

**Cost.** One mechanical change across about 20 packages. A second renderer
to keep in step with the first: every new rule builder needs both. Two new
cluster facts for the cluster author on a standard platform.

**Rejected.**

- *A separate data model for rules, with two renderers over it.* The rule
  builders already are that model. A data model would rewrite every caller
  for no new ability.
- *Emit standard `NetworkPolicy` everywhere.* Cilium clusters would lose the
  `kube-apiserver` and `host` entities and the `Valid` condition, and would
  need address facts they do not need today.
- *A `cluster.capabilities.networkPolicyAPI` setting* (the roadmap's earlier
  idea). The role provider already says which renderer the cluster has. A
  second switch could disagree with it.
- *Take the renderer from the `cni` role.* The pod network and the policy
  engine are separate choices on EKS, AKS, and k3s.

## 4. Decision 2: the flavour declares the enforcer, and the role binding closes the other path

**Decision.** A flavour says what enforces policy by declaring an import that
claims `network-policy-enforcer` and carries the renderer with the platform's
facts. Where the platform owns the pod network, the flavour binds the role
`exclusive`. Kix then refuses a `cilium` instance at evaluation, so no Cilium
kind can enter the build (F3, F29).

A flavour author writes:

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

The three facts are the `ipBlock` and translation rows of section 2. They
decide between *same*, *wider*, and *refused*. With
`egressBeforeServiceTranslation = true` a Service egress rule lists the
Service port beside the pod port.

A cluster author on GKE writes two lines:

```nix
networkPolicy.enable = true;
cluster.network.apiServer.cidrs = [ "10.0.0.2/32" ];
```

Per flavour:

| Flavour | Declaration | Why |
|---|---|---|
| `gke`, `gke-autopilot` | Always the standard renderer, `exclusive` | Enforcement is always on. D [g-dpv2] |
| `eks` | New option `cluster.flavor.eks.networkPolicy`: `"none"` (default) or `"vpc-cni"` | Enforcement is off until the add-on enables it, and Kix cannot read that. D [a-bp]. With `"none"` and `networkPolicy.enable`, the flavour's own check fails and names the add-on setting and this option |
| `aks` | New option `cluster.flavor.aks.networkPolicy`: `"none"`, `"cilium"`, `"calico"`, or `"azure"` | `"cilium"` uses the Cilium renderer through a `platform-cilium` import, because AKS serves the kind. D [z-cil]. The others use the standard renderer. All A: no AKS cluster has run Kix |
| `k3s` | Standard renderer, `shadowable` | k3s embeds a policy controller. D [k3s]. Replacing Flannel with Cilium still works |
| `kind` | Standard renderer, `shadowable`, if stock kind enforces policy | A: kind 0.24 and later do. This would let the test suite run the standard renderer without a cloud |

Three more guards keep a kind the cluster does not serve out of a deploy:

- The refusal for a missing enforcer stops recommending Cilium when
  `cluster.roles.cni.binding` is `exclusive`. That advice caused F3.
- A validation check refuses any policy object whose kind is neither
  `NetworkPolicy` nor one of the enforcer's `policyKinds`.
- A cluster author can still override the binding and assert that the
  environment serves the Cilium kinds. Only the live cluster can disprove
  that, so `kix plan` must stop when a kind is not served and the build holds
  only a reference to its CustomResourceDefinition (F5), and prune must treat
  an object of an unserved kind as already gone (F29).

**Cost.** One option each on `eks` and `aks` that must match the cluster,
like `cluster.flavor.rke2.cni` today. The API accepts a `NetworkPolicy` on a
cluster that ignores it, so Kix cannot verify a declared enforcer. Section 10
proposes a probe.

**Rejected.** *Read the enforcer from the live cluster during the build.* A
build must not depend on a cluster. *Turn the standard renderer on by default
on EKS.* Policies that nothing enforces would pass `kix check`.

**Not covered.** GKE's older Calico dataplane, EKS Auto Mode (no CoreDNS
pods, DNS by address. D [a-auto]), and the cluster-wide kinds each cloud now
offers (GKE and EKS `ClusterNetworkPolicy`, both alpha).

## 5. Decision 3: the mechanism declares its egress

**Decision.** Each cloud identity mechanism declares the egress it needs.
Binding an identity to a ServiceAccount adds those rules to the egress policy
of every workload that runs as it. A package author writes nothing.

`kix/lib/vocab/cloud-identity-mechanisms.nix` gains an `egress` field per
mechanism, in intent vocabulary plus one new target for an address on the
pod's own node:

```nix
gke = mkMechanism {
  # ...
  egress = [ { to = "node-local"; cidr = "169.254.169.254/32"; ports = [ (tcp 80) (tcp 8080) ]; } ];
};
```

| Mechanism | Egress | Standard renderer | Cilium renderer | Evidence |
|---|---|---|---|---|
| `gke` | `169.254.169.254/32` TCP 80, 8080 | `ipBlock` | Does not occur: GKE has no Cilium kind | Port 80: V (F19). Port 8080: D [g-np] |
| `irsa` | `world` TCP 443 (STS) | `0.0.0.0/0` | `world` entity | D [a-sts] for the endpoint. A that nothing else is needed |
| `eks-pod-identity` | `169.254.170.23/32` and `fd00:ec2::23/128` TCP 80 | `ipBlock` | `toCIDR` and the `host` entity, both on that port | Address: D [a-pi]. A that a rule is needed at all, since the VPC CNI always allows a pod's own node. D [a-bp]. A for Cilium |
| `azure-workload-id` | `world` TCP 443 | `0.0.0.0/0` | `world` entity | D [z-wi] |

The Cilium renderer writes both `toCIDR` and `host` for a node-local address
because Microsoft documents that a link-local address bound on the node
matched a CIDR rule up to Cilium 1.16 and the `host` entity from 1.17.
D [z-ldns]. The `host` entity on one port also admits other host-network
listeners on that port of the node. That is a widening on Cilium and the
scorecard rule reports it.

The workload builder already carries the identity to the pod template for
`checksum/cloud-identity`. It carries `egress` the same way, and the netpol
workload hook appends the rules. For pods an operator creates
(`cnpg-cluster`), the identity value a package receives as a dependency
exposes `networkIntents`, and the package passes it to the operand policy it
already writes.

On GKE a pod with no identity still needs the metadata server to call Google
(F12). `kix.cloudIdentity.gcp { }` is how a package asks for the rule.

**Cost.** IRSA and Entra open TCP 443 to any address, because Kix generates
no rule that names a host. Most bound workloads already hold that rule for
the cloud API itself.

**Rejected.** *Each package declares the rule in `meta.network.intents`.* The
package does not know the cluster's mechanism. *One rule for every pod in the
cluster.* It would give every pod a path to the credential endpoint.

## 6. Decision 4: the DNS provider publishes its peers

**Decision.** The instance that claims the `dns` role publishes where queries
go, as `out.dnsPeers`. Both renderers build the DNS rule from it. The
`k8s-app: kube-dns` selector leaves the renderers.

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

`peers` defaults to today's selector, so existing clusters build the same
manifests. The `coredns` package publishes its own pods. The `cilium`
package's cluster-wide DNS policy reads the same value.

The GKE flavours list every documented DNS path. A cluster uses one or two.
A rule for a peer that does not exist opens nothing, except port 53 of the
metadata address, so a setting per DNS mode would add nothing.

| Peer | Evidence |
|---|---|
| `kube-dns` pods without NodeLocal DNSCache | A: the Service's labels match (F20), the path itself was not run |
| `node-local-dns` pods | V (F20) |
| `169.254.169.254` and `169.254.20.10` with Cloud DNS | D [g-clouddns]. A that an `ipBlock` reaches them. Needs an Autopilot cluster |
| EKS CoreDNS pods | D [a-bp] |

**Cost.** One more field on the `dns` role's `out`.

**Rejected.** *Allow port 53 to any address.* It is a known path for data to
leave a cluster.

## 7. Decision 5: default deny only where Kix runs something

**Decision.** Kix writes a namespace's default deny when the namespace holds
at least one active instance that Kix deploys, or the cluster definition
declares it under `namespaces`. An import does not count, and neither does an
inactive optional instance. Kix never writes a default deny in a namespace
listed in `networkPolicy.platformNamespaces`.

The cloud flavours set `platformNamespaces = [ "kube-system" ]`. A workload
Kix deploys there still gets its own policies, and a policy isolates the pods
it selects, so that workload stays closed. The platform's pods stay
untouched. The kind, k3s, RKE2, and Talos flavours leave the list empty: they
describe their `kube-system` pods with platform intents, as today.

In a platform namespace Kix also writes no policy that selects pods it does
not deploy, except from a `networkPolicy.platformIntents` entry.

**Cost.** A namespace that held only imports loses its default deny on
upgrade. That is a change nobody is told about, so it needs a `silent`
record and a minor release. Declaring the namespace under `namespaces` keeps
the old result.

**Rejected.** *Describe each cloud's `kube-system` with platform intents.*
The cloud changes those pods between versions and Kix would break DNS or the
metrics API on an upgrade it did not make.

## 8. Decision 6: the API server is a declared address, and load balancers come from anywhere

**API server egress.** The standard kind has no name for the API server. The
cluster author declares it:

```nix
cluster.network.apiServer = {
  cidrs = [ "10.0.0.2/32" ];   # what policy sees when a pod calls the API
  port = 443;                  # default
  sources = [ ];               # where webhook calls come from
};
```

A workload bound to a Role gets egress to `cidrs`. With the list empty,
`kix check` refuses and prints the command that finds the value on that
platform. `kix deploy` compares the list with the live `kubernetes` Service
and EndpointSlice before it applies anything and stops when neither is
covered, so a rotated address fails early with the new value in the message.

Which address to declare differs. On GKE it is the endpoint address
(V, F21). On EKS it is probably the Service's cluster address, because the
VPC CNI seems to decide before translation (A).

**API server ingress.** Eleven packages serve admission webhooks. Their rule
admits `sources`. No platform documents where those calls come from. On GKE
the candidates are the `konnectivity-agent` pods and the control plane's
range. On EKS it is the cluster subnets. D [a-net]. The live tests in 181a
find out, and each flavour then sets a default. Until then the cluster
author sets it, or `kix check` refuses.

**Load balancer ingress.** A `LoadBalancer` Service's backends admit
`0.0.0.0/0`. That worked on GKE through a passthrough load balancer
(V, F21). It is the only rule that works in every AWS target mode, because
traffic can arrive from a node, from the load balancer's own addresses, or
from the client. D [a-lb]. Where an `ipBlock` matches pods this is wider than
Cilium's `world`, and the scorecard rule says so.

**Cost.** One address per cluster to look up and keep current. GKE changes it
on IP rotation. D [g-iprot].

**Rejected.**

- *Read the address from the cluster at deploy and fill it in.* The applied
  policy would differ from the built one, and something would have to rewrite
  it after a rotation.
- *Allow TCP 443 to any address for the API server.* Every workload with a
  RoleBinding would gain the internet on 443.

**Known gap.** GKE has no field that selects a node (D [g-np]), so a rule to
`host` or `remote-node` is refused there. Prometheus scraping the kubelet or
a host-network exporter on another node is such a rule. With egress enforced
that cluster cannot build. The way out today is
`networkPolicy.directions = "ingress"`.

## 9. Build plan

`181a_network_policy_on_clouds_build_plan.md` holds the ten steps, their order,
the change record each carries, and the exact tests to run on the live GKE
and EKS clusters. Two steps are breaking: the default deny rule of decision 5
(`silent`) and, one minor release later, the refusal of the old `spec`
argument (`error`). Nothing else changes what an existing cluster builds.

## 10. For the maintainer

1. **Break `kix.operandPolicy { spec }`?** Recommended: yes, one minor after
   the new arguments ship. Keeping `spec` leaves a Cilium shape as Kix's
   public vocabulary, and the standard renderer would have to parse it.
2. **The API server address as a declared fact.** Recommended. It costs one
   line per cluster and fails early when stale. The alternative that needs no
   line is a rule Kix rewrites at deploy.
3. **Node peers on GKE: refuse.** Recommended, with the gap named in
   decision 6. The other choice is to leave the rule out with a warning and
   let the scrape fail.
4. **A wider policy is a warning by default.** Recommended. On EKS nearly
   every cluster has one, and an error by default would block them all.
5. **The default deny rule changes for existing clusters** (a `silent`
   record). Recommended: one rule for all flavours. The alternative
   keeps the old rule and adds only `platformNamespaces`, which leaves F4's
   cause in place for namespaces that hold only imports.
6. **A probe that proves enforcement.** Recommended as a later step. After a
   deploy, a Job in a Kix namespace tries a connection the default deny must
   block, and the deploy fails if it connects. Without it, a cluster whose
   declared enforcer is switched off passes every check.
7. **`"none"` as the EKS default.** Recommended, because AWS ships it off.

## 11. What the EKS results can change

The model in decisions 1, 2, 4, and 5 does not depend on them. These parts do:

- The three VPC CNI facts. If policy is decided after translation, the
  Service-port fact goes away.
- Which address `cluster.network.apiServer.cidrs` must hold on EKS, and
  whether the flavour can derive it from `cluster.network.serviceCidr`.
- Whether Pod Identity needs a rule. If the pod's own node is always
  reachable, the mechanism's `egress` is empty on the standard renderer.
- The default for `sources` on EKS.
- Whether the first-moments window is real enough that the flavour should
  require the add-on's `strict` mode.
- Whether a rule count limit matters. AWS allows 24 port and protocol pairs
  per address range across all policies. D [a-np]. `0.0.0.0/0` rules from
  many packages share one range.

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

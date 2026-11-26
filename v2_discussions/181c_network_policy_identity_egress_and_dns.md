# 181c: Cloud identity egress and DNS for network policy on managed clouds

**Status:** Draft (2026-11-26). Covers decisions 3 and 4 of `181_network_policy_on_managed_clouds.md`, split out to keep that document short. Implementation has not started.
**Related:** `181_network_policy_on_managed_clouds.md` (decisions 1, 2, 5, and 6, plus definitions of the marks V, D, and A), `181a_network_policy_on_clouds_build_plan.md` (build steps 4 and 7), `181b_network_policy_platform_facts.md` (platform evidence and source links), `177_workload_cloud_identity.md`

## 1. Decision 3: cloud identity mechanisms declare their own egress

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

The `gke` mechanism keeps both TCP 80 and TCP 8080 because Google documents
both (D [g-np]); only port 80 was used on the test cluster (V, F19 and N3).

| Mechanism | Required egress | Standard renderer | Cilium renderer | Evidence |
|---|---|---|---|---|
| `gke` | `169.254.169.254/32` TCP 80, 8080 | `ipBlock` | Unused (GKE serves no Cilium kind) | Port 80: V (F19, N3). Port 8080: D [g-np]; unused on the test cluster (N3) |
| `irsa` | `world` TCP 443 (STS) | `0.0.0.0/0` | `world` entity | V (AWS F18): the pod receives credentials with this rule and DNS, and calls hang without it |
| `eks-pod-identity` | `169.254.170.23/32` and `fd00:ec2::23/128` TCP 80 | `ipBlock` | Both `toCIDR` and `host` entity on TCP 80 | V (AWS F18) for IPv4: the pod receives credentials with this rule and gets none without it. IPv6 address: D [a-pi]. **A** on Cilium |
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

On GKE, a pod whose package declares no cloud identity still authenticates
through the metadata server as its Kubernetes `ServiceAccount`'s own principal
(F12). Because Kix adds the metadata egress rule only when a cloud identity is
bound, a package that calls Google Cloud APIs must bind
`kix.cloudIdentity.gcp { }` to get the rule, even when it links no Google
service account.

**Cost.** IRSA and Microsoft Entra Workload ID open outbound TCP 443 to
`0.0.0.0/0` (any address, including pod IPs on platforms where `ipBlock`
matches them) because Kix generates no hostname-based rules. Most workloads
with a cloud identity already hold that rule to reach the cloud APIs
themselves.

**Rejected.**

- *Declare credential egress in each package's `meta.network.intents`.* A
  package does not know which cloud identity mechanism the cluster uses.
- *Open credential endpoints for every pod in the cluster.* Pods that do not
  use cloud credentials would gain network access to the credential endpoint.

## 2. Decision 4: the DNS provider publishes its peers

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

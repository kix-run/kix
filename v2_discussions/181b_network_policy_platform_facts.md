# 181b: Platform facts for network policy on managed clouds

**Status:** Platform facts and test evidence supporting `181_network_policy_on_managed_clouds.md`, current as of 2026-11-25.
**Related:** `181_network_policy_on_managed_clouds.md` (design decisions, `Fn` and `AWS Fn` finding numbers, and evidence marks: **V** verified on a live cluster, **D** documented, and **A** unverified assumption), `181a_network_policy_on_clouds_build_plan.md` (live cluster tests to verify the remaining **A** assumptions)

## 1. How managed cloud platforms enforce policy

| Behavior | GKE Dataplane V2 | EKS with Amazon VPC CNI | AKS |
|---|---|---|---|
| Enforces standard `NetworkPolicy` | Always on, with no toggle. V (F19), D [g-dpv2] | Off until `enableNetworkPolicy` is set on the add-on, and enforced once set. V (AWS F18), D [a-bp] | Depends on the chosen policy engine: none, Azure NPM, Calico, or Cilium. D [z-np] |
| Serves `CiliumNetworkPolicy` | No. V (F3) | No. A | Yes (layers 3 and 4) on Azure CNI Powered by Cilium. D [z-cil] |
| `ipBlock` matches pod IPs | Never. D [g-np] | Unknown (A: yes) | Never on Cilium. D [z-cil] |
| `ipBlock` or selector matches nodes and host-network pods | No field can match them. D [g-np] | `ipBlock` matches node IPs. V (AWS F18) | Never on Cilium. D [z-cil] |
| When policy evaluates Service calls | After Service address translation; rules must match the endpoint IP. V (F21) | A: before translation. AWS docs require the Service port to match the container port. D [a-np] | Unknown |
| Where cluster DNS answers from | `kube-dns` pods, or `node-local-dns` pods when NodeLocal DNSCache is enabled (default from 1.34). V (F20), D [g-nldns]. With Cloud DNS (Autopilot default): `169.254.169.254` or `169.254.20.10`. D [g-clouddns] | CoreDNS pods labeled `k8s-app: kube-dns`. V (AWS F18) | CoreDNS pods, or LocalDNS at `169.254.10.10` and `169.254.10.11`. D [z-ldns] |
| How pods reach the API server | Control-plane internal IP on TCP 443; changes during IP rotation. V (F21), D [g-iprot] | Reachable with a rule allowing the VPC and Service ranges on TCP 443. V (AWS F18). Unknown whether the rule must match the Service IP or the endpoint IP (A). Endpoint interfaces change on cluster version upgrades. D [a-net] | Varies by cluster type. D [z-wi] |
| Outbound traffic needed for cloud identity | `169.254.169.254/32` on TCP 80 (V, F19) and TCP 8080 (D [g-np]) | IRSA: the STS endpoint outside the VPC on TCP 443. V (AWS F18). Pod Identity: the host-network agent at `169.254.170.23` on TCP 80, which requires an explicit rule. V (AWS F18) | `login.microsoftonline.com` on TCP 443; no metadata IP. D [z-wi] |
| Pod startup window | Unknown | In the default `standard` mode, a new pod's first calls go out before its policies load. V (AWS F18), D [a-npcfg] | Unknown |

Kubernetes leaves it up to each network plugin how `ipBlock` handles in-cluster
pods, nodes, and Service address translation (D [k-np]). Because of that, each
platform flavor must declare those behaviors explicitly for Kix.

## 2. What the EKS tests settled and what remains open

The EKS test (AWS F16 to F18) changed no decisions and confirmed these points:

- The VPC CNI enforces standard `NetworkPolicy` only after enforcement is
  enabled on the add-on, so the `eks` flavor needs its option.
- The DNS rule Kix generates today matches EKS CoreDNS pods.
- IRSA requires outbound TCP 443 to addresses outside the VPC. Pod Identity
  also needs its own egress rule for `169.254.170.23/32` on TCP 80, even though
  the EKS Pod Identity agent runs on the pod's own node and listens on that
  link-local address. AWS documents that the VPC CNI always allows traffic
  between a pod and its own node (D [a-bp]), yet calls to `169.254.170.23`
  still time out under default deny until an egress rule allows that address
  (V, AWS F18).
- Load balancer traffic arrived from a node IP, confirming that `ipBlock`
  matches node IPs on the VPC CNI.
- The startup window in `standard` mode occurs in practice.

The following points remain unverified assumptions, covered by tests 2, 3, 4,
and 7 in `181a` section 3:

- **Service translation:** whether a rule must allow the Service port. If the
  VPC CNI evaluates policy after translation, `egressBeforeServiceTranslation`
  is not needed.
- **`ipBlock` and pod IPs:** whether `0.0.0.0/0` also matches pod IPs, which
  determines how often `networkPolicyWidened` triggers on EKS.
- **`cluster.network.apiServer.cidrs` on EKS:** whether the rule must match the
  Service IP or the endpoint IPs, and whether the `eks` flavor can derive it
  from `cluster.network.serviceCidr`.
- **Default `cluster.network.apiServer.sources` on EKS:** which source
  addresses webhook requests arrive from.
- **AWS rule limits:** AWS allows 24 port-and-protocol pairs per CIDR across
  all policies (D [a-np]), and `0.0.0.0/0` rules across packages share one
  CIDR.

## 3. Sources

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

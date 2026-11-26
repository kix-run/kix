# 181b: Platform facts for network policy on managed clouds

**Status:** Platform facts and test evidence supporting `181_network_policy_on_managed_clouds.md`, current as of 2026-11-25.
**Related:** `181c_network_policy_identity_egress_and_dns.md` (the identity egress and DNS decisions that cite these facts), `181_network_policy_on_managed_clouds.md` (design decisions, `Fn` and `AWS Fn` finding numbers, and evidence marks: **V** verified on a live cluster, **D** documented, and **A** unverified assumption), `181a_network_policy_on_clouds_build_plan.md` (live cluster tests to verify the remaining **A** assumptions)

## 1. How managed cloud platforms enforce policy

| Behavior | GKE Dataplane V2 | EKS with Amazon VPC CNI | AKS |
|---|---|---|---|
| Enforces standard `NetworkPolicy` | Always on, with no toggle. V (F19), D [g-dpv2] | Off until `enableNetworkPolicy` is set on the add-on, and enforced once set. V (AWS F18), D [a-bp] | Depends on the chosen policy engine: none, Azure NPM, Calico, or Cilium. D [z-np] |
| Serves `CiliumNetworkPolicy` | No. V (F3) | No. A | Yes (layers 3 and 4) on Azure CNI Powered by Cilium. D [z-cil] |
| `ipBlock` matches pod IPs | Never. V (N1), D [g-np] | Yes. V (AWS Q3) | Never on Cilium. D [z-cil] |
| `ipBlock` or selector matches nodes and host-network pods | An `ipBlock` covering the whole node range matches nodes. V (N2). Google's docs say no field can match them. D [g-np] | `ipBlock` matches node IPs. V (AWS F18) | Never on Cilium. D [z-cil] |
| When policy evaluates Service calls | After Service address translation; rules must match the endpoint IP. V (F21) | Selector peers after translation (pod port); `ipBlock` peers before translation (Service address and Service port). V (AWS Q1) | Unknown |
| Where cluster DNS answers from | `kube-dns` pods, or `node-local-dns` pods when NodeLocal DNSCache is enabled (default from 1.34). V (F20), D [g-nldns]. With Cloud DNS (Autopilot default): `169.254.169.254` or `169.254.20.10`. D [g-clouddns] | CoreDNS pods labeled `k8s-app: kube-dns`. V (AWS F18) | CoreDNS pods, or LocalDNS at `169.254.10.10` and `169.254.10.11`. D [z-ldns] |
| How pods reach the API server | Control-plane internal IP on TCP 443; changes during IP rotation. V (F21), D [g-iprot] | Only the `kubernetes` Service address on TCP 443 works (the first address of the Service range, which does not change); endpoint addresses change, and rules for the `EndpointSlice` addresses or VPC range alone time out. V (AWS F18, AWS Q2), D [a-net] | Varies by cluster type. D [z-wi] |
| Where API server webhook calls come from | Pods labeled `k8s-app: konnectivity-agent` in `kube-system`. V (N1). Private clusters and clusters without konnectivity are untested (A) | Control plane network interfaces, the `kubernetes` `EndpointSlice` addresses, which change; admitted by a rule for the VPC range, while a rule for node addresses fails. V (AWS Q6), D [a-net] | Unknown |
| Outbound traffic needed for cloud identity | `169.254.169.254/32` on TCP 80, V (F19, N3); TCP 8080 is documented, D [g-np], and unused on the test cluster (N3) | IRSA: the STS endpoint outside the VPC on TCP 443. V (AWS F18). Pod Identity: the host-network agent at `169.254.170.23` on TCP 80, which requires an explicit rule. V (AWS F18) | `login.microsoftonline.com` on TCP 443; no metadata IP. D [z-wi] |
| Pod startup window | Unknown | About one second of unrestricted egress in the default `standard` mode before policies load. V (AWS F18, AWS Q8), D [a-npcfg] | Unknown |

Kubernetes leaves it up to each network plugin how `ipBlock` handles in-cluster
pods, nodes, and Service address translation (D [k-np]). Because of that, each
platform flavor must declare those behaviors explicitly for Kix.

## 2. What the EKS tests settled and what remains open

The EKS tests (AWS F16 to F18, and AWS Q1 to Q8) settled these points:

- **Enforcement off by default:** the VPC CNI enforces standard `NetworkPolicy`
  only after enforcement is enabled on the add-on (enforcement was off on the
  cluster as created; V, AWS F18), so the `eks` flavor needs its
  option.
- **Cluster DNS:** the DNS rule shape Kix generates today matches EKS CoreDNS
  pods (V, AWS F18 and AWS Q8).
- **Cloud identity:** IRSA needs TCP 443 to any address and fails without it
  (V, AWS F18 and AWS Q4). Pod Identity needs an `ipBlock` rule for
  `169.254.170.23/32` on TCP 80, even though the EKS Pod Identity agent runs on
  the pod's own node and listens on that link-local address. AWS documents that
  the VPC CNI always allows traffic between a pod and its own node (D [a-bp]),
  yet calls to `169.254.170.23` still time out under default deny until an
  egress rule allows that address (V, AWS F18 and AWS Q5).
- **Service translation:** rules with pod-selector peers match after Service
  address translation and must name the pod port, so Kix's Service egress rules
  need no extra port; rules with `ipBlock` peers match before translation and
  must name the Service address and Service port (`ipBlockSeesServiceAddress =
  true`; V, AWS Q1).
- **`ipBlock` against pod and node IPs:** `ipBlock` `0.0.0.0/0` on a port admits
  both pod addresses and node addresses on that port (`ipBlockSelectsPods =
  true` and `ipBlockSelectsNodes = true`; V, AWS F18 and AWS Q3).
- **`cluster.network.apiServer.cidrs` on EKS:** only an `ipBlock` containing the
  cluster IP of the `kubernetes` Service (the first address of the Service
  range, which does not change) on TCP 443 lets a pod reach the API server;
  rules for the `EndpointSlice` addresses or for the VPC range alone time out,
  and the `EndpointSlice` addresses change (V, AWS Q2). Kix derives `cidrs` from
  `cluster.network.serviceCidr` when set.
- **`cluster.network.apiServer.sources` on EKS:** admission webhook calls arrive
  from the control plane's network interfaces in the cluster subnets (the
  `kubernetes` `EndpointSlice` addresses, which change). A rule for node
  addresses does not admit them, while a rule for the VPC range does (V,
  AWS Q6), so the cluster author sets `sources` to the cluster subnet range.
- **Classic load balancers:** a `LoadBalancer` Service behind a classic load
  balancer answers with ingress from `0.0.0.0/0`; the pod sees a node address
  with `externalTrafficPolicy: Cluster` and the load balancer's own VPC address
  with `Local` (V, AWS F18 and AWS Q7).
- **Pod startup window:** in `standard` mode, a new pod has about one second of
  unrestricted egress before its policies load (V, AWS F18 and AWS Q8).

The following points remain open on EKS:

- **Load balancers with IP targets:** untested (**A**; test 8 in `181a` section
  3, which needs the AWS Load Balancer Controller).
- **AWS rule limits:** AWS allows 24 port-and-protocol pairs per CIDR across
  all policies (D [a-np]), and `0.0.0.0/0` rules across packages share one
  CIDR.
- **Policy built by Kix on EKS:** waits for build step 8 (test 1 in `181a`
  section 3).

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

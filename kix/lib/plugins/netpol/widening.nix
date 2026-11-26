# The ways a standard NetworkPolicy can allow more traffic than the Cilium
# policy Kix writes for the same rule. The standard renderer marks each rule
# with the ids that apply, writes them on the policy as
# `kix.run/network-policy-widened`, and the `networkPolicyWidened` scorecard
# rule reads them back and prints `summary` and `fix` once per id.
{
  world-egress-pods = {
    summary = "A `world` egress rule also allows traffic to pods, because on this platform an ipBlock matches pod addresses.";
    fix = "Set `cluster.network.podCidr` so Kix can exclude the pod range from `world`.";
  };
  world-egress-nodes = {
    summary = "A `world` egress rule also allows traffic to the nodes, because on this platform an ipBlock matches node addresses.";
    fix = "Set `cluster.network.nodeCidrs` so Kix can exclude the node ranges from `world`.";
  };
  world-egress-services = {
    summary = "A `world` egress rule also allows traffic to every Service on its port, including the API server, because on this platform an ipBlock matches the Service address.";
    fix = "Set `cluster.network.serviceCidr` so Kix can exclude the Service range from `world`.";
  };
  world-ingress-pods = {
    summary = "A `world` ingress rule also admits traffic from pods, because on this platform an ipBlock matches pod addresses.";
    fix = "Kix keeps the pod addresses in, because load balancer traffic can arrive from them. Accept this finding, or select the callers with a narrower rule.";
  };
  world-ingress-nodes = {
    summary = "A `world` ingress rule also admits traffic from the nodes, because on this platform an ipBlock matches node addresses.";
    fix = "Kix keeps the node addresses in, because nodes forward load balancer traffic. Accept this finding.";
  };
  node-range-pods = {
    summary = "A rule for the nodes uses `cluster.network.nodeCidrs`, and on this platform it also matches pods whose addresses fall in those ranges.";
    fix = "Set `cluster.network.nodeCidrs` to ranges that hold only nodes, or accept this finding where pods and nodes share subnets.";
  };
  host-all-nodes = {
    summary = "A rule for the `host` entity means the pod's own node, and a NetworkPolicy cannot name one node, so it allows every node in `cluster.network.nodeCidrs`.";
    fix = "Accept this finding, or narrow the rule's ports.";
  };
  apiserver-sources-pods = {
    summary = "Admission webhook and aggregated API rules admit the address ranges in `cluster.network.apiServer.sources`, and on this platform they also match pods whose addresses fall in those ranges.";
    fix = "Set `cluster.network.apiServer.sources` to the narrowest ranges the control plane calls from, or accept this finding.";
  };
  pod-start-egress-open = {
    summary = "A new pod can send traffic for about one second before the platform applies its egress policy.";
    fix = "Accept this finding. On EKS, the VPC CNI's `strict` policy mode closes the gap, but it also blocks every pod that has no policy, including the pods in `kube-system`.";
  };
}

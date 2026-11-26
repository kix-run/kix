# The ways a standard NetworkPolicy can allow more traffic than the Cilium
# policy Kix writes for the same rule. The standard renderer marks each rule
# with the ids that apply, writes them on the policy as
# `kix.run/network-policy-widened`, and the `networkPolicyWidened` scorecard
# rule reads them back and prints `summary` and `fix` once per id.
{
  world-egress-pods = {
    summary = "`world` egress rules also allow traffic to in-cluster pods because `cluster.network.podCidr` is unset and `ipBlock` rules match pod IPs on this platform.";
    fix = "Set `cluster.network.podCidr` so Kix excludes pod IPs from `world` egress.";
  };
  world-egress-nodes = {
    summary = "`world` egress rules also allow traffic to cluster nodes because `cluster.network.nodeCidrs` is empty and `ipBlock` rules match node IPs on this platform.";
    fix = "Set `cluster.network.nodeCidrs` so Kix excludes node IPs from `world` egress.";
  };
  world-egress-node-subnets = {
    summary = "`world` egress rules also allow traffic to cluster nodes, because on this platform the node range also holds other addresses that `world` must reach, such as VPC endpoints, load balancers, and databases, so Kix does not exclude it.";
    fix = "No Kix setting narrows this rule while the node range holds other addresses. Accept this finding.";
  };
  world-egress-services = {
    summary = "`world` egress rules also allow traffic to in-cluster Services (including the API server) on the allowed ports because `cluster.network.serviceCidr` is unset and `ipBlock` rules match Service IPs on this platform.";
    fix = "Set `cluster.network.serviceCidr` so Kix excludes Service IPs from `world` egress.";
  };
  world-ingress-pods = {
    summary = "`world` ingress rules also admit traffic from in-cluster pods because `ipBlock` rules match pod IPs on this platform, and Kix cannot exclude pod ranges where load balancer traffic may arrive from them.";
    fix = "Replace `world` ingress with a narrower caller selector if external load balancer access is not needed; otherwise no change is required.";
  };
  world-ingress-nodes = {
    summary = "`world` ingress rules also admit traffic from cluster nodes because `ipBlock` rules match node IPs on this platform, and Kix cannot exclude node ranges without blocking load balancer traffic forwarded by nodes.";
    fix = "Replace `world` ingress with a narrower caller selector if external load balancer access is not needed; otherwise no change is required.";
  };
  node-range-pods = {
    summary = "Rules targeting cluster nodes match `cluster.network.nodeCidrs`, which on this platform also matches pods whose IPs fall in those ranges.";
    fix = "Set `cluster.network.nodeCidrs` to node-only IP ranges if your cluster separates node and pod subnets; where pods and nodes share subnets, no Kix setting can narrow this rule.";
  };
  host-all-nodes = {
    summary = "Rules for the `host` entity allow every node in `cluster.network.nodeCidrs` because standard `NetworkPolicy` cannot restrict traffic to only the pod's own node.";
    fix = "Restrict the rule to specific ports where possible; otherwise no change is required.";
  };
  apiserver-sources-pods = {
    summary = "Admission webhook and aggregated API ingress rules allow the IP ranges in `cluster.network.apiServer.sources`, which on this platform also match pods in those ranges.";
    fix = "Set `cluster.network.apiServer.sources` to the narrowest CIDR ranges the control plane calls from; otherwise no change is required.";
  };
  pod-start-egress-open = {
    summary = "Newly started pods can send outbound traffic for roughly one second before the platform applies their egress `NetworkPolicy` rules.";
    fix = "No Kix change is required to keep default behavior. On EKS, enabling `strict` policy mode in the Amazon VPC CNI add-on closes this window, though it also blocks all traffic on pods without a `NetworkPolicy` (including unmanaged pods in `kube-system`).";
  };
}

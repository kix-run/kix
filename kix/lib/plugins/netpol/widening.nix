# The ways a standard NetworkPolicy can allow more traffic than the Cilium
# policy Kix writes for the same rule. The standard renderer marks each rule
# with the ids that apply, writes them on the policy as
# `kix.run/network-policy-widened`, and the `networkPolicyWidened` scorecard
# rule reads them back and prints `summary` and `fix` once per id.
{
  world-egress-pods = {
    summary = "Egress rules for `world` also allow traffic to pods in the cluster. Because `cluster.network.podCidr` is not set, Kix could not exclude pod IPs, and `ipBlock` rules on this platform match pods.";
    fix = "Set `cluster.network.podCidr` to the pod IP range so Kix excludes it from `world` egress rules.";
  };
  world-egress-nodes = {
    summary = "Egress rules for `world` also allow traffic to cluster nodes. Because `cluster.network.nodeCidrs` is empty, Kix could not exclude node IPs, and `ipBlock` rules on this platform match nodes.";
    fix = "Set `cluster.network.nodeCidrs` to the cluster's node IP ranges so Kix excludes them from `world` egress rules.";
  };
  world-egress-node-subnets = {
    summary = "Egress rules for `world` also allow traffic to cluster nodes. On this platform, nodes share subnets with VPC endpoints, load balancers, and databases, so Kix keeps those subnets in `world` egress rules.";
    fix = "No Kix setting can exclude node IPs where nodes share subnets with other services, so no configuration change is needed.";
  };
  world-egress-services = {
    summary = "Egress rules for `world` also allow traffic to Services in the cluster (including the Kubernetes API server) on the rule's allowed ports. Because `cluster.network.serviceCidr` is not set, Kix could not exclude Service IPs, and `ipBlock` rules on this platform match Service IPs.";
    fix = "Set `cluster.network.serviceCidr` to the Service IP range so Kix excludes it from `world` egress rules.";
  };
  world-ingress-pods = {
    summary = "Ingress rules for `world` also allow traffic from pods in the cluster. On this platform, `ipBlock` rules match pod IPs, and Kix keeps pod IP ranges in `world` ingress rules so load balancer traffic is not blocked.";
    fix = "If the workload does not need direct external access, use a `ClusterIP` Service (or `kix.expose`) instead of a `LoadBalancer` Service, or remove `from = \"world\"` from the intent; otherwise no change is needed.";
  };
  world-ingress-nodes = {
    summary = "Ingress rules for `world` also allow traffic from cluster nodes. On this platform, `ipBlock` rules match node IPs, and Kix keeps node IP ranges in `world` ingress rules so load balancer traffic forwarded by nodes is not blocked.";
    fix = "If the workload does not need direct external access, use a `ClusterIP` Service (or `kix.expose`) instead of a `LoadBalancer` Service, or remove `from = \"world\"` from the intent; otherwise no change is needed.";
  };
  node-range-pods = {
    summary = "Rules targeting cluster nodes allow `cluster.network.nodeCidrs`, and `ipBlock` rules on this platform also match any pods with IPs in those ranges.";
    fix = "If your cluster places nodes and pods in separate subnets, set `cluster.network.nodeCidrs` to the node subnets only; if nodes and pods share subnets, no Kix setting can exclude pod IPs.";
  };
  host-all-nodes = {
    summary = "Rules for the `host` entity allow traffic to or from every node in `cluster.network.nodeCidrs`. Standard `NetworkPolicy` cannot match only the node where a pod runs, so Kix allows all cluster nodes.";
    fix = "Limit the rule to specific `ports` where possible; otherwise no change is needed.";
  };
  apiserver-sources-pods = {
    summary = "Ingress rules for `apiserver` (admission webhooks and aggregated APIs) allow the CIDR ranges in `cluster.network.apiServer.sources`, and `ipBlock` rules on this platform also match any pods in those ranges.";
    fix = "Set `cluster.network.apiServer.sources` to the narrowest CIDR ranges the control plane calls from; otherwise no change is needed.";
  };
  pod-start-egress-open = {
    summary = "New pods can send outbound traffic for about one second after startup before the platform enforces the egress `NetworkPolicy` rules Kix wrote.";
    fix = "No change in Kix is needed to keep this default behavior. On EKS, turning on `strict` policy mode in the Amazon VPC CNI add-on closes this startup window, but also blocks all traffic on pods without a `NetworkPolicy` (including unmanaged pods in `kube-system`).";
  };
}

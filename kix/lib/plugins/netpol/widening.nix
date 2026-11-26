# The ways a standard NetworkPolicy can admit traffic its rules did not ask
# for. The standard renderer marks each rule with the ids that apply, writes
# them on the policy as `kix.run/network-policy-widened`, and the
# `networkPolicyWidened` scorecard rule reads them back. It prints `summary`
# and `fix` once per id, and `detail` for each policy under `kix check -v`.
{
  world-egress-pods = {
    detail = "its outbound `world` rule also reaches pods in the cluster";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to pods in the cluster. On this platform, `ipBlock` rules match pod IPs, and `cluster.network.podCidr` is unset.";
    fix = "Set `cluster.network.podCidr` so Kix excludes the pod IP range from outbound `world` rules.";
  };
  world-egress-pod-subnets = {
    detail = "its outbound `world` rule also reaches pods in the cluster, which share subnets with addresses outside the cluster";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to pods in the cluster. On this platform, `ipBlock` rules match pod IPs, and pods take addresses from the same VPC subnets as VPC endpoints, load balancers, and databases, so Kix cannot exclude the pod range without cutting those off.";
    fix = "No Kix setting narrows this rule while pods share subnets with other addresses. Do not set `cluster.network.podCidr` to narrow it.";
  };
  world-egress-nodes = {
    detail = "its outbound `world` rule also reaches cluster nodes";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to cluster nodes. On this platform, `ipBlock` rules match node IPs, and `cluster.network.nodeCidrs` is empty.";
    fix = "Set `cluster.network.nodeCidrs` to your cluster's node IP ranges so Kix excludes them from outbound `world` rules.";
  };
  world-egress-node-subnets = {
    detail = "its outbound `world` rule also reaches cluster nodes in the shared VPC subnets";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to cluster nodes. On this platform, nodes share VPC subnets with VPC endpoints, load balancers, and databases, so Kix keeps those subnets in outbound `world` rules.";
    fix = "No `cluster.network` setting can exclude node IPs when nodes share subnets with external services; limit `world` egress intents to specific `ports` where possible.";
  };
  world-egress-services = {
    detail = "its outbound `world` rule also reaches cluster Services, including the API server, on the rule's ports";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to cluster Services, including the Kubernetes API server, on the rule's ports. On this platform, `ipBlock` rules match Service IPs, and `cluster.network.serviceCidr` is unset.";
    fix = "Set `cluster.network.serviceCidr` so Kix excludes the Service IP range from outbound `world` rules.";
  };
  world-ingress-pods = {
    detail = "its `world` ingress rule also accepts traffic from pods in the cluster";
    summary = "External (`world`) ingress rules (`0.0.0.0/0` and `::/0`) for `LoadBalancer` Service target ports and `from = \"world\"` intents also accept traffic from pods in the cluster. On this platform, `ipBlock` rules match pod IPs, and Kix keeps pod ranges in `world` ingress rules because load balancer traffic can arrive from them.";
    fix = "If the workload does not need direct external access, expose it through a `ClusterIP` Service (or `kix.expose`) instead of `LoadBalancer`, or remove `from = \"world\"`; otherwise no change is needed.";
  };
  world-ingress-nodes = {
    detail = "its `world` ingress rule also accepts traffic from cluster nodes";
    summary = "External (`world`) ingress rules (`0.0.0.0/0` and `::/0`) for `LoadBalancer` Service target ports and `from = \"world\"` intents also accept traffic from cluster nodes. On this platform, `ipBlock` rules match node IPs, and Kix keeps node ranges in `world` ingress rules because load balancer traffic can arrive from nodes.";
    fix = "If the workload does not need direct external access, expose it through a `ClusterIP` Service (or `kix.expose`) instead of `LoadBalancer`, or remove `from = \"world\"`; otherwise no change is needed.";
  };
  node-range-pods = {
    detail = "its node rule also matches pods with IPs in `cluster.network.nodeCidrs`";
    summary = "Rules targeting cluster nodes allow `cluster.network.nodeCidrs`, and `ipBlock` rules on this platform also match pods with IPs in those ranges.";
    fix = "If nodes and pods use separate subnets, set `cluster.network.nodeCidrs` to the node subnets only; when they share subnets, Kix cannot exclude pod IPs.";
  };
  host-all-nodes = {
    detail = "its `host` rule (intended for the pod's own node) matches every node in `cluster.network.nodeCidrs`";
    summary = "Rules for the `host` entity are intended for the pod's own node, but standard `NetworkPolicy` cannot select a single node, so Kix allows every node in `cluster.network.nodeCidrs`.";
    fix = "Limit the rule to specific `ports` where possible; otherwise no change is needed.";
  };
  apiserver-sources-pods = {
    detail = "its `apiserver` ingress rule also accepts traffic from pods with IPs in `cluster.network.apiServer.sources`";
    summary = "Ingress rules for calls from the Kubernetes API server (admission webhooks and aggregated APIs) allow the CIDR ranges in `cluster.network.apiServer.sources`, and `ipBlock` rules on this platform also match pods in those ranges.";
    fix = "Set `cluster.network.apiServer.sources` to the subnets the control plane uses (on EKS, the subnets given when the cluster was created), and no narrower, because the control plane's addresses move within them. When pods share those subnets, Kix cannot exclude pod IPs.";
  };
  pod-start-egress-open = {
    detail = "new pods it selects can send outbound traffic for about one second before egress rules apply";
    summary = "In Amazon VPC CNI standard mode, new pods can send outbound traffic for about one second after startup before egress `NetworkPolicy` rules take effect.";
    fix = "No change in Kix is needed to keep this default. Enabling strict mode in the Amazon VPC CNI add-on closes this startup window, but blocks pods that have no `NetworkPolicy`, including pods in `kube-system`.";
  };
}

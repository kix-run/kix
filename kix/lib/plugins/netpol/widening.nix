# The ways a standard NetworkPolicy can admit traffic its rules did not ask
# for. The standard renderer marks each rule with the ids that apply, writes
# them on the policy as `kix.run/network-policy-widened`, and the
# `networkPolicyWidened` scorecard rule reads them back. It prints `summary`
# and `fix` once per id, and `detail` for each policy under `kix check -v`.
{
  world-egress-pods = {
    detail = "outbound `world` rules also allow traffic to pods in the cluster";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to pods in the cluster. `cluster.network.podCidr` is unset, so Kix could not exclude pod IPs from those `ipBlock` rules.";
    fix = "Set `cluster.network.podCidr` to your cluster's pod IP range.";
  };
  world-egress-pod-subnets = {
    detail = "outbound `world` rules also allow traffic to pods in shared VPC subnets";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to pods in the cluster. Pods share VPC subnets with VPC endpoints, load balancers, and databases, so Kix keeps pod subnets in outbound `world` rules to avoid blocking those services.";
    fix = "No `cluster.network` setting can exclude pod IPs here (`cluster.network.podCidr` is ignored for `world` rules). Limit `world` egress rules to specific `ports` where possible.";
  };
  world-egress-nodes = {
    detail = "outbound `world` rules also allow traffic to cluster nodes";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to cluster nodes. `cluster.network.nodeCidrs` is empty, so Kix could not exclude node IPs from those `ipBlock` rules.";
    fix = "Set `cluster.network.nodeCidrs` to your cluster's node IP ranges.";
  };
  world-egress-node-subnets = {
    detail = "outbound `world` rules also allow traffic to cluster nodes in shared VPC subnets";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to cluster nodes. Nodes share VPC subnets with VPC endpoints, load balancers, and databases, so Kix keeps node subnets in outbound `world` rules to avoid blocking those services.";
    fix = "No `cluster.network` setting can exclude node IPs here (`cluster.network.nodeCidrs` is ignored for `world` rules). Limit `world` egress rules to specific `ports` where possible.";
  };
  world-egress-services = {
    detail = "outbound `world` rules also allow traffic to cluster Services (including the API server) on the rule's ports";
    summary = "Outbound `world` rules (`0.0.0.0/0` and `::/0`) also allow traffic to cluster Services, including the Kubernetes API server, on the rule's ports. `cluster.network.serviceCidr` is unset, so Kix could not exclude Service IPs from those `ipBlock` rules.";
    fix = "Set `cluster.network.serviceCidr` to your cluster's Service IP range.";
  };
  world-ingress-pods = {
    detail = "inbound `world` rules also accept traffic from pods in the cluster";
    summary = "Inbound `world` rules (`0.0.0.0/0` and `::/0`, for `LoadBalancer` Services and `from = \"world\"` intents) also accept traffic from pods in the cluster. Kix keeps pod subnets in inbound `world` rules because cloud load balancers can forward external traffic from addresses in those subnets.";
    fix = "No change is needed if this workload should accept direct external traffic. Otherwise, expose it through a `ClusterIP` Service (with `kix.expose` for HTTP routes) instead of `LoadBalancer`, or remove `from = \"world\"`.";
  };
  world-ingress-nodes = {
    detail = "inbound `world` rules also accept traffic from cluster nodes";
    summary = "Inbound `world` rules (`0.0.0.0/0` and `::/0`, for `LoadBalancer` Services and `from = \"world\"` intents) also accept traffic from cluster nodes. Kix keeps node IPs in inbound `world` rules because cloud load balancers often forward external traffic through nodes.";
    fix = "No change is needed if this workload should accept direct external traffic. Otherwise, expose it through a `ClusterIP` Service (with `kix.expose` for HTTP routes) instead of `LoadBalancer`, or remove `from = \"world\"`.";
  };
  node-range-pods = {
    detail = "rules targeting cluster nodes also match pods with IPs in `cluster.network.nodeCidrs`";
    summary = "Rules targeting cluster nodes use `ipBlock` over `cluster.network.nodeCidrs`, which on this platform also matches pods with IPs in those ranges.";
    fix = "If nodes and pods use separate subnets, list only the node subnets in `cluster.network.nodeCidrs`. If they share subnets, Kix cannot exclude pod IPs; limit node rules to specific `ports` where possible.";
  };
  host-all-nodes = {
    detail = "`host` rules match every node in `cluster.network.nodeCidrs` instead of only the pod's own node";
    summary = "Rules targeting `host` are meant for the pod's own node. Standard `NetworkPolicy` cannot select a single node, so Kix allows every node in `cluster.network.nodeCidrs`.";
    fix = "Limit `host` rules to specific `ports` where possible; otherwise no change is needed.";
  };
  apiserver-sources-pods = {
    detail = "`apiserver` ingress rules also accept traffic from pods with IPs in `cluster.network.apiServer.sources`";
    summary = "Ingress rules for Kubernetes API server calls (admission webhooks and aggregated APIs) allow the CIDR ranges in `cluster.network.apiServer.sources`. On this platform, `ipBlock` rules also match pods with IPs in those ranges.";
    fix = "Keep `cluster.network.apiServer.sources` set to the full control plane subnets (on EKS, the subnets configured for the control plane) rather than individual `/32` IPs, because control plane IPs change. When pods share those subnets, Kix cannot exclude pod IPs.";
  };
  pod-start-egress-open = {
    detail = "new pods selected by this policy can send outbound traffic for about one second before egress rules apply";
    summary = "In Amazon VPC CNI standard mode, new pods can send unrestricted outbound traffic for about one second after startup before Kix's egress `NetworkPolicy` rules take effect.";
    fix = "No change is needed to keep standard mode. Enabling strict mode in the Amazon VPC CNI add-on closes this startup window, though it blocks pods that have no `NetworkPolicy`, including unmanaged pods in `kube-system`.";
  };
}

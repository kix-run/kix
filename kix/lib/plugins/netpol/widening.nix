# The ways a standard NetworkPolicy can admit traffic its rules did not ask
# for. The standard renderer marks each rule with the ids that apply, writes
# them on the policy as `kix.run/network-policy-widened`, and the
# `networkPolicyWidened` scorecard rule reads them back. It prints `summary`
# and `fix` once per id, and `detail` for each policy under `kix check -v`.
#
# `fixable` says whether a cluster setting removes the reason. Only a
# fixable reason is a warning; the others are limits of the platform, which
# no setting removes, and are reported at `info`. `node-range-pods` is a
# limit: the renderer marks it wherever an ipBlock matches pods, whatever
# `nodeCidrs` holds, so no setting removes the mark.
{
  world-egress-pods = {
    fixable = true;
    detail = "outbound external (`world`) rules also allow traffic to pods in the cluster";
    summary = "Outbound rules for external traffic (`0.0.0.0/0` and `::/0`) also allow connections to pods in the cluster because `cluster.network.podCidr` is unset, so Kix could not exclude pod IPs.";
    fix = "Set `cluster.network.podCidr` to your cluster's pod CIDR.";
  };
  world-egress-pod-subnets = {
    fixable = false;
    detail = "outbound external (`world`) rules also allow traffic to pods in shared VPC subnets";
    summary = "Outbound rules for external traffic (`0.0.0.0/0` and `::/0`) also allow connections to pods in the cluster. Because VPC subnets can hold pods alongside VPC endpoints, load balancers, and databases, Kix keeps pod subnets in these rules (and ignores `cluster.network.podCidr` here) to avoid blocking those services.";
    fix = "No `cluster.network` setting narrows this rule. Restrict `to = \"world\"` egress rules to specific `ports` where possible.";
  };
  world-egress-nodes = {
    fixable = true;
    detail = "outbound external (`world`) rules also allow traffic to cluster nodes";
    summary = "Outbound rules for external traffic (`0.0.0.0/0` and `::/0`) also allow connections to cluster nodes because `cluster.network.nodeCidrs` is empty, so Kix could not exclude node IPs.";
    fix = "Set `cluster.network.nodeCidrs` to your cluster's node IP ranges.";
  };
  world-egress-node-subnets = {
    fixable = false;
    detail = "outbound external (`world`) rules also allow traffic to cluster nodes in shared VPC subnets";
    summary = "Outbound rules for external traffic (`0.0.0.0/0` and `::/0`) also allow connections to cluster nodes. Because nodes share VPC subnets with VPC endpoints, load balancers, and databases, Kix keeps node subnets in these rules (and ignores `cluster.network.nodeCidrs` here) to avoid blocking those services.";
    fix = "No `cluster.network` setting narrows this rule. Restrict `to = \"world\"` egress rules to specific `ports` where possible.";
  };
  world-egress-services = {
    fixable = true;
    detail = "outbound external (`world`) rules also allow traffic to cluster Services (including the API server) on the rule's ports";
    summary = "Outbound rules for external traffic (`0.0.0.0/0` and `::/0`) also allow connections to cluster Services, including the Kubernetes API server, on the rule's ports because `cluster.network.serviceCidr` is unset, so Kix could not exclude Service IPs.";
    fix = "Set `cluster.network.serviceCidr` to your cluster's Service CIDR.";
  };
  world-ingress-pods = {
    fixable = false;
    detail = "external ingress (`world`) rules also accept traffic from pods in the cluster";
    summary = "External ingress rules (`0.0.0.0/0` and `::/0`, generated for `LoadBalancer` Services and `from = \"world\"` intents) also accept connections from pods in the cluster. Kix keeps pod subnets in these rules because cloud load balancers can forward external requests from VPC subnet IPs.";
    fix = "No `cluster.network` setting narrows this rule. To restrict in-cluster callers on HTTP workloads, use a `ClusterIP` Service with `kix.expose` instead of `LoadBalancer`, or remove `from = \"world\"` if external access is unnecessary.";
  };
  world-ingress-nodes = {
    fixable = false;
    detail = "external ingress (`world`) rules also accept traffic from cluster nodes";
    summary = "External ingress rules (`0.0.0.0/0` and `::/0`, generated for `LoadBalancer` Services and `from = \"world\"` intents) also accept connections from cluster nodes. Kix keeps node IPs in these rules because cloud load balancers forward external traffic through nodes.";
    fix = "No `cluster.network` setting narrows this rule. To accept external HTTP traffic only through an Ingress or Gateway controller, use a `ClusterIP` Service with `kix.expose` instead of `LoadBalancer`, or remove `from = \"world\"` if external access is unnecessary.";
  };
  node-range-pods = {
    fixable = false;
    detail = "node rules also match any pods with IPs in `cluster.network.nodeCidrs`";
    summary = "Standard `NetworkPolicy` has no node selector, so Kix targets cluster nodes using `cluster.network.nodeCidrs`. On this platform, CIDR rules also match any pods whose IPs fall in those ranges (Kix cannot verify whether pods and nodes share subnets).";
    fix = "On a default Amazon VPC CNI cluster, pods and nodes share subnets and no `cluster.network` setting narrows node rules, so restrict them to specific `ports` to limit what they open. With VPC CNI custom networking (separate pod subnets), list only the node subnets in `cluster.network.nodeCidrs` to keep pods out of node rules, though no setting removes this finding.";
  };
  host-all-nodes = {
    fixable = false;
    detail = "local-node (`host`) rules allow every node in `cluster.network.nodeCidrs` instead of only the pod's own node";
    summary = "Rules targeting the local node (`host`) allow every node in `cluster.network.nodeCidrs` because standard `NetworkPolicy` cannot select only the node a pod runs on.";
    fix = "No `cluster.network` setting narrows this rule. Restrict `host` rules to specific `ports` where possible.";
  };
  apiserver-sources-pods = {
    fixable = false;
    detail = "API server ingress (`apiserver`) rules also accept traffic from pods with IPs in `cluster.network.apiServer.sources`";
    summary = "Ingress rules for calls from the Kubernetes API server (admission webhooks and aggregated APIs) allow the CIDR ranges in `cluster.network.apiServer.sources`. On this platform, CIDR rules also match any pods with IPs in those ranges.";
    fix = "Keep `cluster.network.apiServer.sources` set to the full control plane subnets rather than individual `/32` IPs, because control plane IPs change. When pods share those subnets, Kix cannot exclude pod IPs.";
  };
  pod-start-egress-open = {
    fixable = false;
    detail = "new pods can send outbound traffic for about one second before egress rules take effect";
    summary = "In Amazon VPC CNI standard mode, new pods can send outbound traffic for about one second after startup before egress `NetworkPolicy` rules take effect.";
    fix = "No Kix setting changes this. Turning on `strict` mode in the Amazon VPC CNI add-on closes this startup window, but blocks every pod that has no `NetworkPolicy`, including pods in `kube-system`.";
  };
}

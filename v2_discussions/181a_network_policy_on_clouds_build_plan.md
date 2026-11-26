# 181a: Build plan for network policy on managed clouds

**Status:** Draft implementation plan for `181_network_policy_on_managed_clouds.md`. Implementation has not started.
**Related:** `181c_network_policy_identity_egress_and_dns.md` (decisions 3 and 4, built by steps 7 and 4), `181_network_policy_on_managed_clouds.md` (design decisions and the `Fn` and `AWS Fn` finding numbers cited below)

## 1. Implementation steps

| # | Change | Depends on | Change record |
|---|---|---|---|
| 1 | Stop recommending Cilium in the missing-enforcer error when `cluster.roles.cni.binding` is `"exclusive"`. Update validation check 12 (`[K1895]`) to honor `kix.run/operand-of` on a `NetworkPolicy` a package defines directly (AWS F17). Fix the `gke` and `k3s` flavor header comments and the "Network policy" docs page. | none | `fixed` |
| 2 | CLI: fail `kix plan` immediately when a resource's kind is unserved and the build holds only a CRD reference with no CRD manifest (F5). Treat unserved kinds as already absent during prune (F29). | none | `fixed` |
| 3 | Repair the enforcer envelope: add `selector`, `ingress`, and `egress` arguments to `mkPolicy` and `kix.operandPolicy`, migrate all in-tree callers, and restrict `entities` on `meta.network.intents` to the fixed list. Keep `spec` working on the Cilium renderer for now. Every cluster in `clusters/` must build identical manifests. | none | `added` |
| 4 | Publish DNS peers in `meta.dnsPeers` on packages that claim the `dns` role. Add a `dnsPeers` argument to `kix.mkImport` that stores `meta.dnsPeers` in the import's metadata, and pass `peers` to `dnsPeers` in the flavors' `platform-dns` helper. Treat a pod peer without `namespace` as the provider instance's own namespace. Set `meta.dnsPeers = [ { podSelector."k8s-app" = "kube-dns"; } ]` on `coredns`, so it no longer has to run in `kube-system`. Read the provider's `meta.dnsPeers` without evaluating the instance in the Cilium renderer, which refuses `cidr` peers, and in the `cilium` package. Audit all 11 `all-pods` callers and split out explicit node or API server rules where needed. Existing manifests must stay unchanged. | 3 | `added` |
| 5 | Skip default-deny in namespaces whose only instances are imports or inactive optional instances, and add `networkPolicy.platformNamespaces` (decision 5). | none | `silent` (minor release) |
| 6 | Implement the standard `NetworkPolicy` renderer, the link-local exclusion on `world` rules, `cluster.network.apiServer`, `cluster.network.nodeCidrs`, unsupported-rule refusals, the `networkPolicyWidened` scorecard rule, the policy-kind validation check, the check 12 skip for policies that Kix generates for operator-created pods and platform intents (AWS F17), and the `kix deploy` API server IP check. Enable the standard renderer in `gke` and `gke-autopilot`, plus `k3s` and `kind` once live tests confirm stock enforcement. | 3, 4, 5 | `added` |
| 7 | Add `egress` rules on cloud identity mechanisms, the `"node-local"` intent target, and `networkIntents` on bound identity values. | 3 | `fixed` (adds egress rules on Cilium clusters using cloud identity; no user action needed) |
| 8 | Add `cluster.flavor.eks.networkPolicy` and the verified VPC CNI behavior flags. | 6 | `added` |
| 9 | Remove the legacy `spec` argument of `kix.operandPolicy` with an error naming `selector`, `ingress`, and `egress`. The enforcer contract keeps a `spec` path: default deny passes the enforcer's own `mkDefaultDenySpec` result as `extraArgs.spec`, and `mkEndpointSelector` has no callers left. Either keep that path or replace it with a `mkDefaultDenyPolicy` contract entry, and drop `mkEndpointSelector`. | 3 (next minor release) | `error` (with an id) |
| 10 | Add `cluster.flavor.aks.networkPolicy`. | 6 + live AKS cluster | `added` |
| 11 | Add the post-deploy enforcement probe, if approved (`181`, section 10). | 6 | `added` |

Steps 1, 2, 3, and 5 have no dependencies and can run in parallel; steps 4 and
7 can run in parallel once step 3 lands. Check before starting steps 1 and 2,
as fixes for those findings may already be underway separately. Each step
updates its corresponding user docs, skills, and `architecture.md` in the same
pull request.

Only steps 5 and 9 are breaking changes; no other step changes what existing
clusters build. Steps 3, 4, 5, and 7 can be verified locally without a cloud
cluster: every cluster in `clusters/` must build cleanly, and the Change kind
check must list only the expected manifest changes. Step 6 is the first step
that requires a live cloud cluster.

## 2. Live GKE tests

For step 2, repeat F3 (step 2) and F29: `kix plan` must fail within seconds,
and prune must finish without errors. For steps 6 and 7, run checks 1 through 9
on a GKE Dataplane V2 cluster with NodeLocal DNSCache enabled once those steps
are built. Test 10 can run immediately in a scratch namespace using an explicit
`NetworkPolicy` manifest before any Kix changes are built.

The live GKE tests already answered the platform questions in tests 5 (N1,
webhook source), 7 (N2, node kubelet egress), and 9 (N5, Autopilot DNS via
`169.254.20.10/32`), plus test 10 (N4, excluding the node range from
`0.0.0.0/0` egress). Tests 1 through 9 still need to run against Kix once steps
6 and 7 land:

1. Deploy a cluster with `kix.flavors.gke`, `networkPolicy.enable = true`, and
   one `echo-server` instance in namespace `np`. Verify that `kix build`
   contains `NetworkPolicy` `np/np-default-deny`, contains no policy in
   `kube-system`, and contains no `cilium.io` resources, and that `kix deploy`
   succeeds (F3, F4).
2. From the `echo-server` pod, verify that `nslookup kubernetes.default`
   resolves (F20) and `curl -m 5 https://example.com` times out.
3. Add a client package in another namespace that depends on the `echo-server`
   Service, plus an unconnected pod. Verify that the client gets HTTP 200 and
   the unconnected pod times out.
4. Add `external-dns` with `kix.cloudIdentity.gcp { }`. First leave
   `cluster.network.apiServer.cidrs` unset and verify that `kix check` fails
   and names that option. Set `cidrs` to the control plane's internal IP and
   verify that DNS records appear in Cloud DNS (F19, F21). Then set `cidrs` to
   a wrong IP and verify that `kix deploy` stops before applying anything.
5. Add `cert-manager` and create a `Certificate` with
   `cluster.network.apiServer.sources` unset. Verify that `sources` defaults to
   the `konnectivity-agent` pods and that the webhook answers (N1).
6. Set the `echo-server` Service to `LoadBalancer` and verify that four
   external requests return HTTP 200 (F21).
7. Add `prometheus` with `node-exporter`. First leave
   `cluster.network.nodeCidrs` unset and verify that `kix check` refuses and
   names `cluster.network.nodeCidrs`. Then set `cluster.network.nodeCidrs` to
   the node range and verify that Prometheus scrapes `node-exporter` (N2).
8. Empty the cluster definition and verify that `kix deploy --prune` finishes
   without errors.
9. If a GKE Autopilot cluster is available, repeat test 2 with the
   `gke-autopilot` flavor and verify that DNS resolves through
   `169.254.20.10/32` (N5).
10. Under default-deny egress, allow `0.0.0.0/0` except the node range on TCP
    10250 and record whether a node is still reachable.

## 3. Live EKS tests

Tests 2 through 9 use explicit `NetworkPolicy` manifests in a scratch namespace
and need no Kix changes; test 1 runs once step 8 is built. Enable
`enableNetworkPolicy` on the VPC CNI add-on for all nine tests.

Live EKS tests already answered tests 2 (AWS Q1), 3 (AWS Q2), 4 (AWS Q3), 5
(AWS F18, AWS Q4), 6 (AWS F18, AWS Q5), 7 (AWS Q6), and 9 (AWS F18, AWS Q8),
plus test 8 with `instance` targets behind a classic load balancer (AWS F18,
AWS Q7). What remains is test 1 after step 8, and test 8 with `ip` targets,
which needs the AWS Load Balancer Controller:

1. With `cluster.flavor.eks.networkPolicy` unset, verify that `kix check` fails
   and names `cluster.flavor.eks.networkPolicy`. Set it to `"vpc-cni"` and
   repeat GKE tests 1 through 3.
2. Create a Service on port 80 backed by pods on port 8080. Allow egress on TCP
   8080 only, then on both TCP 80 and 8080, and record which rule reaches the
   Service by DNS name.
3. Allow egress to the `kubernetes` Service's ClusterIP only, then to its
   endpoint IPs only, and record which rule reaches the Kubernetes API.
4. Allow egress to `0.0.0.0/0` on a single port, and record whether another
   pod's IP and a node's IP are reachable on that port.
5. Test `external-dns` with IRSA under default-deny egress, both with and
   without TCP 443 allowed to `0.0.0.0/0`.
6. Repeat test 5 using EKS Pod Identity, with and without an egress rule
   allowing TCP 80 to `169.254.170.23/32`.
7. Trigger the `cert-manager` admission webhook and record the source IP of the
   API server's requests. Restart the webhook pod between policy changes,
   because the API server reuses open connections that a policy change does not
   cut.
8. Expose a `LoadBalancer` Service with `instance` targets and then `ip`
   targets, allowing ingress from `0.0.0.0/0`. Verify HTTP 200 in both modes
   and record the source IP seen by the pod.
9. Run a `Job` that calls a denied IP within its first second of startup, and
   record whether the connection succeeds before policies load.

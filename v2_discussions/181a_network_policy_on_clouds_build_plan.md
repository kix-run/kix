# 181a: Build plan for network policy on managed clouds

**Status:** Draft implementation plan for `181_network_policy_on_managed_clouds.md`. Implementation has not started.
**Related:** `181_network_policy_on_managed_clouds.md` (design decisions and the `Fn` and `AWS Fn` finding numbers cited below)

## 1. Implementation steps

| # | Change | Depends on | Change record |
|---|---|---|---|
| 1 | Stop recommending Cilium in the missing-enforcer error when `cluster.roles.cni.binding` is `"exclusive"`. Update validation check 12 (`[K1895]`) to honor `kix.run/operand-of` on a `NetworkPolicy` a package defines directly (AWS F17). Fix the `gke` and `k3s` flavor header comments and the "Network policy" docs page. | none | `fixed` |
| 2 | CLI: fail `kix plan` immediately when a resource's kind is unserved and the build holds only a CRD reference with no CRD manifest (F5). Treat unserved kinds as already absent during prune (F29). | none | `fixed` |
| 3 | Repair the enforcer envelope: add `selector`, `ingress`, and `egress` arguments to `mkPolicy` and `kix.operandPolicy`, migrate all in-tree callers, and restrict `entities` on `meta.network.intents` to the fixed list. Keep `spec` working on the Cilium renderer for now. Every cluster in `clusters/` must build identical manifests. | none | `added` |
| 4 | Add `out.dnsPeers` to the `dns` role and read it in the Cilium renderer and `cilium` package. Audit all 11 `all-pods` callers and split out explicit node or API server rules where needed. Existing manifests must stay unchanged. | 3 | `added` |
| 5 | Skip default-deny in namespaces whose only instances are imports or inactive optional instances, and add `networkPolicy.platformNamespaces` (decision 5). | none | `silent` (minor release) |
| 6 | Implement the standard `NetworkPolicy` renderer, `cluster.network.apiServer`, `cluster.network.nodeCidrs`, unsupported-rule refusals, the `networkPolicyWidened` scorecard rule, the policy-kind validation check, the check 12 skip for policies that Kix generates for operator-created pods and platform intents (AWS F17), and the `kix deploy` API server IP check. Enable the standard renderer in `gke` and `gke-autopilot`, plus `k3s` and `kind` once live tests confirm stock enforcement. | 3, 4, 5 | `added` |
| 7 | Add `egress` rules on cloud identity mechanisms, the `"node-local"` intent target, and `networkIntents` on bound identity values. | 3 | `fixed` (adds egress rules on Cilium clusters using cloud identity; no user action needed) |
| 8 | Add `cluster.flavor.eks.networkPolicy` and the verified VPC CNI behavior flags. | 6 + EKS test C | `added` |
| 9 | Remove the legacy `spec` argument with an error naming `selector`, `ingress`, and `egress`. | 3 (next minor release) | `error` (with an id) |
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
and prune must finish without errors. For steps 6 and 7, run these checks on a
GKE Dataplane V2 cluster with NodeLocal DNSCache enabled:

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
5. Add `cert-manager` and create a `Certificate`. Test `sources` first with the
   `konnectivity-agent` pods and then with the control-plane CIDR, and record
   which one lets the webhook answer.
6. Set the `echo-server` Service to `LoadBalancer` and verify that four
   external requests return HTTP 200 (F21).
7. From a pod under default egress deny, run
   `curl -m 3 -k https://<another node>:10250` and record whether Dataplane V2
   blocks it. Then add `prometheus` with `node-exporter` and verify that
   `kix check` fails and names node peers.
8. Empty the cluster definition and verify that `kix deploy --prune` finishes
   without errors.
9. If a GKE Autopilot cluster is available, read `/etc/resolv.conf` inside a
   pod, repeat test 2, and record which DNS peer matched.

The standalone policy checks in tests 5 and 7 (webhook source and node kubelet
egress) can run immediately with explicit `NetworkPolicy` manifests before any
Kix changes are built.

## 3. Live EKS tests

Tests 2 through 9 can run immediately in a scratch namespace using explicit
`NetworkPolicy` manifests before any step is built; their results determine the
VPC CNI settings for step 8. Test 1 runs once step 8 is built. Enable
`enableNetworkPolicy` on the VPC CNI add-on for all nine tests.

The 2026-11-25 EKS test (AWS F18) already covered tests 5, 6, and 9, plus test
8 with `instance` targets behind a classic load balancer. Tests 2, 3, 4, and 7,
along with test 8 using `ip` targets, still need to run:

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
   API server's requests.
8. Expose a `LoadBalancer` Service with `instance` targets and then `ip`
   targets, allowing ingress from `0.0.0.0/0`. Verify HTTP 200 in both modes
   and record the source IP seen by the pod.
9. Run a `Job` that calls a denied IP within its first second of startup, and
   record whether the connection succeeds before policies load.

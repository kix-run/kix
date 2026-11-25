# 181a: Network policy on managed clouds, the build plan

**Status:** Draft plan for `181_network_policy_on_managed_clouds.md`. Nothing is built.
**Related:** `181_network_policy_on_managed_clouds.md` (the decisions, and the finding numbers `Fn` used below)

## 1. Steps

| # | Change | After | Record |
|---|---|---|---|
| 1 | The missing-enforcer refusal stops recommending Cilium where the pod network is `exclusive`. Correct the `gke` and `k3s` flavour comments and the "Network policy" page | none | `fixed` |
| 2 | CLI: `kix plan` stops on an unserved kind that only a CRD reference covers (F5). Prune treats an unserved kind as gone (F29) | none | `fixed` |
| 3 | Envelope repair: `selector`, `ingress`, `egress` arguments on `mkPolicy` and `kix.operandPolicy`. Move every in-tree caller. The closed entity list. The Cilium renderer still accepts `spec`. Every cluster in `clusters/` must build identical manifests | none | `added` |
| 4 | `out.dnsPeers` on the `dns` role, read by the Cilium renderer and the `cilium` package. Audit the eleven `all-pods` users. Existing manifests unchanged | 3 | `added` |
| 5 | The default deny rule of decision 5 and `networkPolicy.platformNamespaces` | none | `silent`, minor release |
| 6 | The standard renderer, `cluster.network.apiServer` and `nodeCidrs`, the refusals, `networkPolicyWidened`, the policy-kind check, the deploy comparison of the API server address. `gke` and `gke-autopilot` declare it. `k3s` and `kind` declare it once a test on each shows that the stock cluster enforces policy | 3, 4, 5 | `added` |
| 7 | Mechanism `egress`, the `node-local` target, `networkIntents` on the identity value | 3 | `fixed` (policies on Cilium clusters with an identity gain a rule; nobody must act) |
| 8 | `cluster.flavor.eks.networkPolicy` and the VPC CNI facts | 6, and the EKS test C | `added` |
| 9 | Refuse the old `spec` argument with an error that names the new ones | 3, one minor later | `error`, with an id |
| 10 | `cluster.flavor.aks.networkPolicy` | 6, and an AKS cluster | `added` |
| 11 | The enforcement probe, if the maintainer agrees (181, section 10) | 6 | `added` |

Steps 1, 2, 3, and 5 can run in parallel. Steps 4 and 7 can run in parallel
after 3. Each step carries its own docs, skill, and `architecture.md` edits.
Steps 5 and 9 are the breaking ones. Nothing else changes what an existing
cluster builds. Steps 1 and 2 may already be in progress from the findings
themselves, so check before starting them.

Steps 3, 4, 5, and 7 change nothing on a cloud by themselves. Their proof is
local: every cluster in `clusters/` builds, and the Change kind check lists
only the objects each step names. Step 6 is the first that needs a cloud.

## 2. Live GKE tests

Step 2: repeat F3 step 2 and F29. The plan must stop in seconds, and the
prune must finish with no failure. Steps 6 and 7, on a Dataplane V2 cluster
with NodeLocal DNSCache:

1. `kix.flavors.gke`, `networkPolicy.enable = true`, one `echo-server` in
   `np`. `kix build` holds `NetworkPolicy np/np-default-deny`, no policy in
   `kube-system`, and no `cilium.io` object. `kix deploy` finishes (F3, F4).
2. In the echo pod: `nslookup kubernetes.default` answers (F20), and
   `curl -m 5 https://example.com` times out.
3. Add a client package that depends on the echo Service from another
   namespace. The client gets 200. A pod with no dependency times out.
4. Add `external-dns` with `kix.cloudIdentity.gcp { }`. Without
   `cluster.network.apiServer.cidrs`, `kix check` refuses and names the
   option. Set it to the control plane's internal address. Records appear in
   Cloud DNS (F19, F21). Then set a wrong address: `kix deploy` stops before
   applying.
5. Add `cert-manager` and create a Certificate. Try
   `sources = [ konnectivity-agent pods ]`, then the control plane range.
   Report which one lets the webhook answer.
6. Set the echo Service to `LoadBalancer`. Four requests from outside return
   200 (F21).
7. From a pod under egress deny, `curl -m 3 -k https://<another node>:10250`.
   Report whether it is blocked. Add `prometheus` with `node-exporter`:
   `kix check` refuses and names node peers.
8. Empty the definition. `kix deploy --prune` finishes with no failure.
9. On an Autopilot cluster, if one exists: read `/etc/resolv.conf`, repeat
   test 2, and report which DNS peer carried it.

The first halves of tests 5 and 7 can run today with policies written for
the test.

## 3. Live EKS tests

Tests 2 to 9 can run today, before any step is built, with policies written
for the test in a scratch namespace. They decide the facts step 8 puts in
the flavour. Test 1 needs step 8. All of them need the VPC CNI add-on set to
`enableNetworkPolicy`:

1. With `cluster.flavor.eks.networkPolicy` unset, `kix check` refuses and
   names it. With `"vpc-cni"`, repeat GKE tests 1 to 3.
2. A Service on port 80 with pods on 8080. Allow egress on 8080 only, then on
   80 and 8080. Report which reaches the Service by name.
3. Allow egress to the `kubernetes` Service's cluster address only, then to
   its endpoint addresses only. Report which reaches the API.
4. Allow egress to `0.0.0.0/0` on one port. Report whether another pod's
   address and a node's address on that port are reachable.
5. `external-dns` with IRSA under default deny, with and without TCP 443 to
   any address.
6. The same with EKS Pod Identity, with and without a rule for
   `169.254.170.23/32` TCP 80.
7. The cert-manager webhook: report the source address of the API server's
   calls.
8. A `LoadBalancer` Service with instance targets, then IP targets: ingress
   from `0.0.0.0/0` returns 200. Report the source address the pod sees.
9. A Job that calls a denied address in its first second. Report whether the
   call succeeds.


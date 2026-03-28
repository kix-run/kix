---
title: "From Dependencies to Network Policies"
date: 2026-03-26
series: 13
commits:
  - 4bd8864  # feat: network policy generation
  - 5943b5d  # feat: new crd design
  - eb26d67  # feat: rename main -> root(s)
---

# From Dependencies to Network Policies

*2026-03-26 -- Post 13*

---

kix already knows which packages talk to each other. Why not generate the network policies from that?

Post 4 described how kix tracks dependencies: Nix string interpolation captures name-based references automatically, and `requires` handles semantic dependencies like CRDs and label selectors. The result is a full dependency graph computed at build time. Every edge in that graph means "package A references something from package B."

A Kubernetes **NetworkPolicy** says "pod A can talk to pod B on port X." That is the same information. If package A references package B's service, A needs to reach B on B's ports. If there is no reference, there is no reason for traffic to flow. The dependency graph *is* the network policy.

## The problem with hand-written policies

Network policies are notoriously tedious to maintain. You add a new service dependency -- say your web app now talks to a caching layer -- but forget to update the network policy. The app cannot reach the cache. You spend an hour debugging connectivity before realizing the policy is blocking traffic. Multiply this by every service in the cluster and you get a configuration surface that drifts from reality within weeks.

Most teams give up. They either run without network policies entirely or write overly permissive rules that defeat the purpose.

## Before: hand-written policies

Here is what a hand-written CiliumNetworkPolicy looks like for one service talking to one dependency:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: immich-egress-valkey
  namespace: apps
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: immich
  egress:
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: valkey
      toPorts:
        - ports:
            - port: "6379"
              protocol: TCP
```

Now imagine writing that for every service pair in a 26-package cluster. Then keeping it updated as dependencies change. Then doing ingress policies too. Then default-deny policies per namespace. This is why most teams give up on network policies entirely.

## After: generated from the graph

kix walks the dependency graph at build time. For each workload (Deployment, StatefulSet, DaemonSet), it inspects Nix's string context to find which Services the workload references. It then generates **CiliumNetworkPolicy** resources that allow exactly the traffic implied by those references.

Concrete example. Package `immich` depends on package `valkey`'s service on port 6379. kix sees that `immich`'s Deployment manifest contains a string-context reference to `valkey`'s Service. It generates two policies:

1. An **egress** policy on `immich`'s pods allowing traffic to `valkey`'s pods on port 6379.
2. An **ingress** policy on `valkey`'s pods allowing traffic from `immich`'s pods on port 6379.

Every namespace also gets a **default-deny** policy that blocks all traffic not explicitly allowed. If you add a dependency, the policy updates automatically. If you remove one, the traffic is blocked. No manual step. No drift.

The system auto-detects several patterns without any configuration. Packages with RBAC resources get API server egress. Packages with LoadBalancer Services get external ingress. StatefulSets get self-communication rules for peer discovery and replication. Helm-wrapped packages get a warning that intra-package edges may be incomplete since kix cannot see inside the Helm black box.

## The CRD redesign

Alongside network policies, CRD handling was reworked from scratch. **Custom Resource Definitions** define new Kubernetes resource types -- `Certificate`, `SGCluster`, `VirtualMachine`. The old approach scattered CRD logic across individual packages. The new design introduces `lib/crd.nix`, a pipeable transformer library.

A package that provides CRDs declares them explicitly:

```nix
crd.fromKind "SGCluster" { spec.group = "stackgres.io"; }
|> crd.withShortNames [ "sgclu" ]
|> scope.mkCRD
```

The library auto-derives plural names, list kinds, and schema boilerplate from the kind name. Packages that consume custom resources automatically depend on the provider through the existing type-provider mechanism from post 4. The CRD and its consumer are now linked in the dependency graph, which means they are also linked in the generated network policies.

## The rename: main to root(s)

One more change landed the same day. Every package previously had a `main` resource -- the "primary" output, usually a Service. This was renamed to **`root`** (or **`roots`** for packages with multiple entry points).

The old name was misleading. `main` suggested "the most important thing the package does." But its actual role is narrower: it is the resource that other packages reference when they depend on this package. It is the root of the package's resource tree, the entry point for dependency tracking. `root` says what it means. Other packages reference `self.myDep.out.root` and get the service they need to connect to.

## Why this matters

Network policies are one of the hardest things to get right in Kubernetes. They require exact knowledge of which services communicate, on which ports, in which direction. That knowledge already exists in the dependency graph. Generating policies from the graph is not a convenience feature. It is the same principle that drives the rest of kix: if the system already knows the answer, do not make the human type it again.

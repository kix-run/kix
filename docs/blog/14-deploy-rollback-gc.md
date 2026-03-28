---
title: "Deploy, Rollback, Garbage Collect"
date: 2026-03-27
date_end: 2026-03-28
series: 14
commits:
  - f171749  # feat: kix deploy and kix gc - first version
  - 8ffdd27  # feat: kix deploy, kix gc
  - 0c9fb2f  # feat: activation lifecycle, multi-activation refs, wave progress
  - 632d2d8  # feat: rollback command, hardware flavors, demo scripts
  - e495c12  # feat: mkLocked
  - e2e55a5  # refactor: merge library crates into single kix crate
---

# Deploy, Rollback, Garbage Collect

*2026-03-27 to 2026-03-28 -- Post 14*

---

Until now, kix built YAML files. Getting them onto a cluster was your problem. The workflow looked like this:

```bash
# Before: manual pipeline
nix build .#cluster-prod
kubectl apply -f ./result/kube-system/
kubectl apply -f ./result/cert-manager/
# wait for CRDs...
kubectl apply -f ./result/ingress-nginx/
# wait for controller...
kubectl apply -f ./result/apps/
# hope you got the order right
```

You had to know the dependency order. You had to wait between steps. You had to clean up removed resources by hand. Not anymore.

```
$ kix deploy prod
Wave 1: priority-classes, storage-classes (2/2 ready)
Wave 2: cert-manager, coredns (2/2 ready)
Wave 3: ingress-nginx, external-dns (2/2 ready)
...
Deploy complete. Activation: act-20260328-001
```

One command. kix evaluates the cluster definition, resolves the dependency graph, and applies resources in the right order. It waits for each batch to become healthy before moving to the next. When it finishes, the cluster matches the Nix definition.

## Waves

The dependency graph from [post 4](04-the-dependency-problem.md) already encodes which resources depend on which. **Waves** are what you get when you topologically sort that graph. Resources with no unsatisfied dependencies form Wave 1. Resources that only depend on Wave 1 form Wave 2. And so on.

This is Kahn's algorithm applied to the resource DAG. Each wave is applied to the cluster, then kix polls for readiness -- Deployments fully rolled out, CRDs registered, Services with endpoints. Only when every resource in a wave reports ready does the next wave begin.

The result: cert-manager's CRDs exist before any Certificate resources try to use them. The ingress controller is running before anything creates Ingress objects. Dependencies are enforced at deploy time, not just at definition time.

## Activations

Each deploy creates an **Activation** custom resource in the cluster. Think of it as a deployment receipt. It records the cluster name, the timestamp, and which wave the deploy reached.

Activations are a state machine with two states: **Active** (this is the current deploy) and **Superseded** (a newer deploy replaced it). They form a linked list through `kix.dev/previous` annotations -- each Activation points back to the one before it. You can trace the full deployment history by walking the chain.

Every resource kix applies gets a `kix.dev/activations` annotation listing which Activations own it. This is reference counting. A Namespace created in Activation 1 and still present in Activation 2 will list both. A ConfigMap removed in Activation 2 will only reference Activation 1. This bookkeeping is what makes rollback and garbage collection safe.

## Resume from crash

Deploys fail. Network timeouts, OOM kills, someone tripping over a power cable. When a deploy fails mid-way, the Activation CR records which wave completed successfully.

The next `kix deploy` sees the incomplete Activation and picks up where it left off. Resources from completed waves are not re-applied. This makes recovery cheap -- you just run the same command again.

## Rollback

```
$ kix rollback prod act-20260327-003
Rolling back to act-20260327-003...
Re-applying 357 manifests from target activation.
Cleaning up 4 resources not in target.
Rollback complete.
```

**`kix rollback`** points the cluster back to a previous Activation. It re-applies that Activation's manifests, then removes resources that exist in the current Activation but not in the target. The rolled-back Activation becomes Active again. The one it replaced becomes Superseded.

Because Activations form a linked list, you can roll back multiple steps. The activation annotations on each resource tell kix exactly what needs to change.

## Garbage collection

Over time, superseded Activations accumulate. Resources that were removed in later deploys linger with stale activation references. **`kix gc`** cleans this up.

```
$ kix gc prod
Removing 3 superseded activations.
Removing 7 orphaned resources.
GC complete.
```

It walks every resource with `kix.dev/activations` annotations. If a resource only references superseded Activations, it is orphaned and gets deleted. Active Activations and their resources are never touched. The safety boundary is strict -- kix only deletes resources stamped with its own annotations.

## Crate consolidation

The Rust workspace started as four crates: kix-eval, kix-manifest, kix-cluster, and kix-cli. In practice, the three library crates formed a strict linear dependency chain: kix-eval depended on nothing, kix-manifest depended on kix-eval, and kix-cluster depended on kix-manifest. The boundaries were artificial.

They are now three crates: **kix** (the merged library), **kix-cli** (the binary), and **kix-operator** (the binary that watches for Activation CRs). One library, two consumers. The code is easier to navigate and the compile graph is simpler.

## mkLocked

Container images are usually referenced by tag. Tags are mutable -- upstream can re-push `v1.2.3` with different contents. **`mkLocked`** pins a package's container images and chart versions to exact content hashes. Once locked, builds are reproducible regardless of what upstream does to their tags.

This is the last piece of the supply chain story. Nix already gives you reproducible evaluation. mkLocked extends that guarantee to the container images and Helm charts your manifests reference.

---

Three weeks ago this was a Nix expression that produced YAML. Now it is a deployment system. It evaluates, diffs, deploys in dependency order, tracks history through Activation CRs, resumes failed deploys, rolls back, and garbage collects. The entire lifecycle, from definition to cleanup, in one tool.

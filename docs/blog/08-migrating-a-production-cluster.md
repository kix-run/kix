---
title: "Migrating a Production Cluster"
date: 2026-03-17
date_end: 2026-03-18
series: 8
commit: 996e0aa  # feat: production cluster migration — 26 packages, 357 manifests
---

# Migrating a Production Cluster

*2026-03-17 to 2026-03-18 -- Post 8*

---

The target was one of our client's production clusters -- a 3-node Hetzner bare-metal setup running real workloads. Before this migration it was managed with Ansible and Helm. 17+ namespaces. 20+ Helm charts. Real traffic. Real users. If kix could not handle this cluster, the whole project was an academic exercise.

## The numbers

The migrated cluster definition produces **357 YAML manifests** across **19 namespaces** from a single command:

```bash
nix build .#cluster-prod
```

Behind that command: **26 packages** (23 native kix packages and 3 wrapped via `fromHelmChart`), totalling **18,488 lines of Nix**. Every manifest is deterministic. Run the build again tomorrow, get the same output byte-for-byte.

## The approach: tiered waves

You do not migrate 20+ services at once. The packages were written in waves, starting with the simplest and working toward the most complex:

- **Tier 7** (trivial): priority-classes, storage-classes, cluster-issuers. No dependencies, no state, no moving parts. Good warm-up.
- **Tier 1** (core infra): coredns, cert-manager, ingress-nginx, external-dns, valkey. The foundation everything else depends on.
- **Tier 2** (platform): reloader, velero, arc, infisical-operator, tailscale. Services that watch or manage other services.
- **Tier 3** (storage/data): stackgres-operator, stackgres-cluster, openebs, harbor. Stateful workloads where getting the config wrong means data loss.
- **Tier 4** (VM): kubevirt, cdi. Niche but surprisingly straightforward once the CRD patterns were established.
- **Tier 5** (monitoring): kube-prometheus-stack, loki, promtail. This is where the Helm bridge earned its keep. More on that below.
- **Tier 6** (apps): python-app, n8n, metabase. Application-level packages that consume everything the lower tiers provide.

Each tier was built and diffed against the live cluster before moving to the next. The `kix-diff` tool made this loop fast: write the package, build, diff, fix discrepancies, repeat.

## What the cluster definition looked like

This is not a toy single-service cluster. It runs **multiple Valkey instances** (one for caching, one for queues), **multiple PostgreSQL clusters** via StackGres, and **per-namespace network policies** that restrict traffic between services. All of this is wired through the **instance system** -- each instance declares what it needs, and the cluster definition connects them:

```nix
instances.production = {
  valkey-cache = {
    package = packages.valkey;
    config = { maxMemory = "512mb"; };
  };
  valkey-queue = {
    package = packages.valkey;
    config = { maxMemory = "256mb"; persistence = true; };
  };
  stackgres-main = {
    package = packages.stackgres-cluster;
    config = { instances = 3; };
  };
};
```

Same package, different config, different instance name. The instance system handles the rest -- unique resource names, correct selectors, no collisions.

## What broke

**Shallow merge broke nested defaults.** Early packages used Nix's `//` operator to merge config with defaults. This works for flat attrsets. It silently drops nested keys. A package with `{ server = { port = 8080; host = "0.0.0.0"; }; }` as defaults would lose `host` entirely if the user passed `{ server = { port = 9090; }; }`. The fix was switching to `lib.recursiveUpdate`, which merges at every level. Simple bug, subtle symptoms.

**ingress-nginx externalTrafficPolicy needed null handling.** The Kubernetes API treats the absence of a field differently from a field set to `null`. The ingress-nginx Service needed `externalTrafficPolicy: Local` in some cases and no field at all in others. The package had to explicitly handle the `null` case and strip the key from the output rather than emitting `externalTrafficPolicy: null`, which Kubernetes would reject.

**Self-referential requires caused infinite recursion.** One package accidentally listed itself in its own `requires` set. Nix's lazy evaluation does not save you from a value that depends on its own definition. The error message was unhelpful -- a stack overflow with no indication of which package caused it. The fix was a one-line cycle check, but finding it took an hour.

**The monitoring stack was too complex to rewrite natively.** kube-prometheus-stack alone generates hundreds of resources -- Prometheus rules, Grafana dashboards, ServiceMonitors, alerting configs. Rewriting all of that as a native kix package would have taken weeks with no real benefit. This is exactly the case `fromHelmChart` was designed for: wrap the Helm chart, expose a few typed options for the values you actually customize, and let Helm do the heavy lifting for the rest. Loki and Promtail got the same treatment. Three packages, three Helm charts, fully integrated into the kix dependency graph.

## The result

Run `nix build .#cluster-prod`. Wait a few seconds. Open `./result/`. There are 357 YAML files, organized by namespace, each one traceable to the package and instance that produced it. Change a Valkey config option, rebuild, and only the affected manifests change. Add a new service, rebuild, and the new manifests appear alongside the existing ones. Remove a package, rebuild, and its manifests disappear.

There is no hidden state. No Terraform state file. No Helm release history stored in cluster Secrets. The entire cluster is a function of its inputs. The `result` directory is the complete truth.

That is what it feels like when infrastructure becomes a build artifact.

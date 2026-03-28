---
title: "From Packages to Clusters"
date: 2026-03-07
date_end: 2026-03-08
series: 3/11
commits:
  - f5eb344  # feat: intent merging — cluster defaults, service registry, cross-cutting modules
  - 6b67097  # feat: declarative cluster state — multi-chart composition
  - a9fb286  # feat: add eval-time assertions and kubeconform schema validation
---

# From Packages to Clusters

*2026-03-07 to 2026-03-08 -- Post 3 of 11*

---

A package produces Kubernetes resources. But a package alone is not a cluster. You need namespaces, shared configuration, cross-package wiring, and validation. This post covers how kix composes packages into a complete cluster definition.

## The cluster file

Here is the simplest possible cluster:

```nix
# clusters/test-minimal.nix
{ kix, packages }:

kix.buildCluster {
  name = "test-minimal";
  modules = [
    {
      namespaces.kube-system = { };

      instances.kube-system = {
        coredns = {
          package = packages.coredns;
        };
      };
    }
  ];
}
```

That is the whole file. Run `nix build .#cluster-test-minimal` and you get a directory of validated Kubernetes manifests.

## What buildCluster does

`buildCluster` takes two things: a **name** and a list of **modules**. Modules are attribute sets (or paths to `.nix` files) that declare two things:

- **Namespaces.** `namespaces.kube-system = { }` ensures the namespace exists. kix creates the Namespace resource for you.
- **Instances.** An **instance** is a package placed into a specific namespace. `instances.kube-system.coredns` means "deploy the coredns package into kube-system." You can pass **config overrides** to customize it -- replica counts, resource limits, domain names, whatever the package exposes.

Under the hood, `buildCluster` uses the NixOS module system. Each module can declare options, set config values, and import other modules. This is the same machinery that powers NixOS itself, repurposed for Kubernetes.

## Linear composition is not enough

The minimal cluster above works fine for one package. But real clusters have dozens of packages that need to share state. CoreDNS needs to know which ingress controllers exist so it can rewrite DNS. Monitoring needs to discover scrape targets across every namespace. Cert-manager needs to know the cluster domain.

Early kix treated each package in isolation. You configured each one independently and hoped the values lined up. Luca pointed out that this was "linear composition, not intent merging" -- packages were stacked side by side but never talked to each other.

Three levels of composition were added to fix this.

### Level 1: Cluster defaults

Modules can declare **options** that propagate to all instances. The production cluster sets a domain, labels, and monitoring flag at the top level:

```nix
{
  cluster.domain = "prod.example.com";
  monitoring.enabled = true;
  clusterLabels = {
    "app.kubernetes.io/part-of" = "prod";
    "cluster" = "prod-01";
    "team" = "platform";
  };
}
```

Every instance inherits `clusterLabels` automatically. Any module can read `config.cluster.domain` to configure itself. No copy-pasting values between packages.

### Level 2: Service registry

Packages announce outputs through `out`. An ingress controller instance exposes `out.fqdn`. CoreDNS reads it:

```nix
{ name = "rewrite";
  parameters = "name exact harbor.${config.cluster.domain} ${ref.nginx-system.ingress-private-v2.out.fqdn} answer auto";
}
```

The **ref** mechanism provides cross-namespace, cross-instance references. `ref.nginx-system.ingress-private-v2` points to the ingress-private-v2 instance in the nginx-system namespace. No hardcoded service names. If the ingress controller's name changes, the reference updates automatically.

### Level 3: Cross-cutting modules

Some concerns span the entire cluster. The monitoring module is a good example. It declares an option (`monitoring.enabled`), and when enabled, it deploys Prometheus, Loki, and Promtail. It also collects ServiceMonitors that reference services in other namespaces -- valkey instances in shopfront-prod, DNS exporters across worker nodes.

This is the module split in the production cluster:

```nix
modules = [
  ./cluster/platform.nix      # namespaces, DNS, ingress, cert-manager
  ./cluster/operators.nix     # operator lifecycle
  ./cluster/monitoring.nix    # Prometheus, Loki, Promtail
  ./cluster/apps.nix          # application workloads
  # ...
  { cluster.domain = "prod.example.com"; }
];
```

Each module file focuses on one concern. The module system merges them. A platform module can declare options that an application module consumes. A monitoring module can conditionally deploy based on a flag set in the top-level config.

## Eval-time validation

When `nix build` runs, it does not just template YAML. It evaluates the entire cluster as a single Nix expression, then validates the result.

**kubeconform** runs against every generated manifest. If a Deployment has a malformed field, the build fails. You do not find out at apply time.

**Registry ownership checks** prevent two instances from claiming the same resource name in the same namespace. If two modules both try to create a Service called `my-service` in `kube-system`, the build fails with a clear error.

**Type checking** from the module system catches misconfigurations. If a module option expects a string and you pass a list, the build fails.

All of this happens during `nix build`. There is no cluster involved. No kubectl. No dry-run against an API server. The manifests in `./result` are validated before they exist as files.

## Building it

```bash
nix build .#cluster-test-minimal --extra-experimental-features pipe-operators
```

The output is a directory of YAML files, one per resource, organized by namespace. From here you can diff against a live cluster, pipe into kubectl, or feed into a GitOps tool. That part comes later.

---

*Next post: [The Dependency Problem](04-the-dependency-problem.md) -- what breaks when packages need to know about each other.*

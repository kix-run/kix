---
title: "V2: Starting Over (Sort Of)"
date: 2026-03-14
date_end: 2026-03-17
series: 7/11
commits:
  - 7d811eb  # feat: v2 first stab at implementation
  - 9f6be91  # chore: remove v1 code paths, consolidate to v2-only
  - 33e7fd7  # feat: transitive dependencies, full store path tracking
  - 0ee0611  # feat: helm support
---

# V2: Starting Over (Sort Of)

*2026-03-14 to 2026-03-17 -- Post 7 of 11*

---

After two weeks of building, we hit walls.

The fixpoint system worked. Parity testing proved we could match Helm output byte for byte. Cluster definitions composed. But as soon as we tried to wire up a real production cluster, three problems surfaced that the v1 architecture could not absorb.

## The walls

**Problem 1: multi-instance.** Our cluster runs seven Valkey instances -- session cache, rate limiter, job queue, and so on. In v1, each package lived under `services.coredns` or `services.valkey`. One name, one instance. Running two copies of the same package meant forking the code or inventing a naming hack.

**Problem 2: transitive dependencies.** If package A requires B, and B requires C, A should get C automatically. In v1, every cluster file had to import every package and wire every dependency by hand. Add a package, touch every cluster file.

**Problem 3: Helm charts that are not worth rewriting.** Some charts are enormous. `kube-prometheus-stack` ships hundreds of resources across Prometheus, Grafana, Alertmanager, and a dozen exporters. Rewriting it as a native kix package would take weeks and produce something worse than the original. We needed a bridge, not a rewrite mandate.

## v1 vs v2: the code

Here is a v1 package. It uses the NixOS module system -- `options` under `services.*`, a custom `ref` system for cross-resource references, and manual namespace threading:

```nix
# v1: module system
{ k8s, lib }:
k8s.mkPackage
  ({ namespace ? "kube-system", ... }:
   self: {
    configmap = k8s.mkResource {
      inherit namespace;
      name = "coredns";
      data.Corefile = "...";
    };
    workload = k8s.mkResource {
      inherit namespace;
      name = "coredns";
      spec.template.spec.volumes = [{
        configMap.name = self.configmap.ref;  # custom ref system
      }];
    };
    service = k8s.mkResource {
      inherit namespace;
      name = "coredns";
    };
    main = k8s.withRequires [ self.workload ] self.service;
  })
  { namespace = "kube-system"; }
```

And the v2 equivalent. No module system. No custom ref system. Just Nix:

```nix
# v2: scope-injected package
{ scope, config, lib }:

let cfg = scope.defaults config {
  image = "registry.k8s.io/coredns/coredns:v1.11.1";
  replicas = 2;
};
in self: {

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-coredns";
    data.Corefile = "...";
  };

  workload = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-coredns";
    spec.template.spec.volumes = [{
      configMap.name = "${self.configmap}";  # plain Nix interpolation
    }];
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-coredns";
    spec.ports = [{ port = 53; }];
  };

  main = self.service // { requires = [ self.workload ]; };
}
```

The differences that matter: `self.configmap.ref` becomes `"${self.configmap}"` -- just normal Nix string interpolation. Forget `.ref` in v1 and the dependency is silently lost. Forget the `${}` in v2 and Nix itself tells you the type is wrong. The namespace disappeared from the package entirely. And the resource names include `scope.instanceName`, so two instances of the same package get distinct names automatically.

## The key concepts

**Instance.** A package placed into a namespace with specific config. Same package, different config, different namespace -- different instance. The cluster definition declares instances, not packages:

```nix
instances = { ref, ... }: {
  data = {
    session-cache = {
      package = packages.valkey;
      config = { maxmemory = "2Gi"; };
    };
    job-queue = {
      package = packages.valkey;
      config = { maxmemory = "512Mi"; persistence = true; };
    };
  };
};
```

Two Valkey instances. Same package. Different config. No code duplication.

**Scope.** The injected context a package receives instead of importing globals. It carries the namespace, instance name, and resource constructors. The package never decides where it lives -- the cluster definition does.

**Requires.** Explicit dependency declarations that are transitive. If CoreDNS requires cert-manager, and cert-manager requires its CRDs package, then adding CoreDNS to a cluster automatically pulls in both cert-manager and the CRDs. No manual wiring.

**Helm bridge.** `fromHelmChart` wraps an existing Helm chart as a kix package. You pass it the chart reference and values; it produces resources that participate in the same dependency system as native packages. We used this for kube-prometheus-stack, loki, and other charts where a native rewrite was not justified.

**Store path tracking.** Every resource becomes a Nix store path via `builtins.toFile`. Its content hash reflects both its own manifest and every resource it references. This forms a Merkle DAG -- change any input, and the hash changes all the way up. You can trace exactly which package produced which resource and what it depends on.

## How it happened

This redesign was not a solo effort. Adam and Luca spent a week in intense design sessions, producing around fifteen discussion documents that explored instance models, dependency injection patterns, Merkle DAGs, namespace scoping, and CRD handling. Each document built on the previous one. The final unified RFC ran to 1400 lines.

The old v1 code was cleanly removed. No compatibility layer, no gradual migration. The cluster definitions were small enough to rewrite in a day. The packages took longer -- each one needed its references updated from the custom `ref` system to plain Nix interpolation, and its namespace handling removed in favor of `scope`.

The result was fewer concepts, less custom machinery, and a system that could handle the real cluster we had been trying to deploy. The next post covers what happened when we pointed it at a production cluster.

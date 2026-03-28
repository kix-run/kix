---
title: "Composing Resources with Pipes"
date: 2026-03-09
date_end: 2026-03-10
series: 5
commit: bad90c9  # feat: pipe-based chart composition — mkServiceDeployment, withMetrics, chart refactors
---

# Composing Resources with Pipes

*2026-03-09 to 2026-03-10 -- Post 5*

---

Here is what the CoreDNS package looked like before the refactoring. Five separate resource definitions, each manually cross-referencing the others:

```nix
deployment = kixlib.workload.mkDeployment { ... };                    # 26 lines
service = kixlib.networking.mkService { ... };                        # 7 lines
metricsService = kixlib.networking.mkService { ... };                 # 17 lines
pdb = kixlib.policy.mkPodDisruptionBudget { ... };                    # 10 lines
hpa = kixlib.autoscaling.mkHorizontalPodAutoscaler { ... };           # 8 lines
```

That is roughly 68 lines. Every resource had to repeat the same selector labels. The PDB copied the Deployment's `matchLabels`. The HPA referenced the Deployment by name. The metrics Service duplicated the selector from the main Service. Miss one and you get a silent mismatch that only shows up at runtime.

Here is the same thing after:

```nix
mainGroup = mkServiceDeployment {
  name = "coredns";
  containers = [ container ];
  selectorLabels = selectorLabels;
  servicePorts = ports.servicePorts;
  replicas = cfg.replicaCount;
  serviceType = cfg.serviceType;
  volumes = [ configVolume ];
  inherit serviceAccountName;
}
|> withMetrics {
  metricsPort = 9153;
  metricsName = "coredns-service-metrics";
}
|> withAutoscaler {
  hpaArgs = { inherit (cfg.hpa) minReplicas maxReplicas metrics; };
}
|> withPodDisruptionBudget {
  pdbArgs = { inherit (cfg.podDisruptionBudget) minAvailable maxUnavailable; };
};
```

About 25 lines. Same output. No repeated selectors.

## What each piece does

**`mkServiceDeployment`** is the starting point. It takes a name, containers, selector labels, and service ports. It returns a **resource group** -- an attribute set containing both a Deployment and a Service. The Service's `selector` is derived from the Deployment's `matchLabels` automatically. You define the selectors once and both resources stay in sync.

**`withMetrics`** takes a resource group and adds a metrics Service to it. It pulls the selector from the existing Deployment in the group. You specify the port number, it handles the wiring. The result is a new group with three resources instead of two.

**`withAutoscaler`** adds a HorizontalPodAutoscaler. It finds the Deployment in the group and sets `scaleTargetRef` to point at it. It knows the Deployment's API version, kind, and name because they are already in the group.

**`withPodDisruptionBudget`** adds a PDB. It copies `matchLabels` from the Deployment's selector. Same pattern -- receive the group, add a resource, return the updated group.

## The pipe operator

The `|>` syntax is a Nix experimental feature called the **pipe operator**. It reads left to right: take the value on the left, pass it as the last argument to the function on the right.

```nix
x |> f
# is equivalent to
f x
```

So the CoreDNS pipeline reads as: "Start with a Deployment+Service group, then add metrics, then add an autoscaler, then add a PDB." Each step returns a new group with more resources in it. The steps are independent -- you can reorder them, drop one, or add new ones without touching the others.

This is what makes them **composable**. Each function -- each **combinator** -- only needs to know about the group it receives. It does not need to know what other combinators ran before it or will run after it. It inspects the group, adds its resource, and passes the result along.

## Scaling the pattern: cert-manager

cert-manager has three components: a controller, a webhook, and a CA injector. Each one needs a Deployment, a Service, and a ServiceAccount. Before combinators, that meant three near-identical blocks of resource definitions with slightly different labels and container specs. About 90 lines of structural repetition.

The fix was a local helper:

```nix
mkComponent = { componentName, labels, container, replicas, servicePorts, ... }:
  mkServiceDeployment {
    name = componentName;
    containers = [ container ];
    selectorLabels = labels.selector;
    inherit servicePorts replicas;
    deploymentLabels = labels.all;
    serviceLabels = labels.all;
  };
```

Then each component is one call:

```nix
controllerGroup = mkComponent {
  componentName = "controller";
  labels = controllerLabels;
  container = controllerContainer;
  replicas = config.replicaCount;
  servicePorts = [ { name = "tcp-prometheus"; port = 9402; } ];
};
```

**`mkComponent` is not part of kix's standard library.** It lives in the cert-manager package. That is the point -- `mkServiceDeployment` is generic enough that packages can wrap it in domain-specific helpers without modifying the core.

## Why this matters

The before-and-after is not just fewer lines. It is fewer places where a mistake can hide. When selectors are derived instead of copied, they cannot drift. When the HPA's target reference comes from the Deployment object in the group, it cannot point at the wrong name. The structure of the code matches the structure of the intent: "I want a service with metrics, autoscaling, and disruption protection."

Each combinator is a small, testable function. The pipe operator makes the composition visible. And because groups are plain attribute sets, you can inspect them at any point in the chain -- print the group after `withMetrics` to see exactly what resources exist before the autoscaler is added.

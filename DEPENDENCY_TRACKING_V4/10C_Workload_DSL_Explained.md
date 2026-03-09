# Workload DSL Example — what the V4 pipe vision looks like for Deployments

Luca's RBAC DSL (10A) shows pipe composition for RBAC rules.
This companion document shows the same idea applied to **workloads** —
Deployments, Services, StatefulSets — the things you `kubectl get` every day.

This is hypothetical. None of this code exists yet. But it's grounded in the
real coredns and valkey charts already in this repo, so you can compare.

## Nix refresher (Python edition)

| Nix syntax | What it means | Python equivalent |
|---|---|---|
| `let ... in ...` | Define local variables, then use them | Assigning variables before a `return` |
| `inherit (foo) a b c;` | Pull `a`, `b`, `c` out of `foo` into scope | `a, b, c = foo.a, foo.b, foo.c` |
| `{ key = value; }` | An attribute set (a dict) | `{"key": value}` |
| `[ a b c ]` | A list (NO commas between elements) | `[a, b, c]` |
| `x \|> f` | Pipe: pass `x` as argument to function `f` | `f(x)` |
| `f x` | Function application (no parens needed) | `f(x)` |
| `a // b` | Merge two dicts, `b` wins on conflict | `{**a, **b}` |
| `x: body` | Anonymous function (lambda) | `lambda x: body` |
| `{ a, b }: body` | Function that destructures its argument | `def f(*, a, b): body` |

---

## Part 1: What coredns looks like TODAY

This is simplified from `pkgs/coredns/resources.nix`. Read it to see the
baseline — then Part 2 shows where we're heading.

```nix
# ── Current code (simplified from pkgs/coredns/resources.nix) ─────────────
#
# This is real, working code. Each resource is built with a kixlib builder
# (mkDeployment, mkService, etc.) and then added to manifestList.

let
  # Build a container. This is a plain dict that becomes a K8s container spec.
  # kixlib'.pod.mkContainer just validates it and fills in defaults.
  #
  # In Python terms: mkContainer is a function that takes a dict and returns
  # a validated dict. Think of it as a dataclass constructor.
  container = kixlib'.pod.mkContainer {
    name = "coredns";
    image = "coredns/coredns:1.11.1";       # kixlib.imageRef normalises this
    args = ["-conf" "/etc/coredns/Corefile"];
    ports = [
      { containerPort = 53; protocol = "UDP"; name = "udp-53"; }
      { containerPort = 53; protocol = "TCP"; name = "tcp-53"; }
      { containerPort = 9153; protocol = "TCP"; name = "metrics"; }
    ];
    resources = cfg.resources;
    livenessProbe = {
      httpGet = { path = "/health"; port = 8080; scheme = "HTTP"; };
      initialDelaySeconds = 60; timeoutSeconds = 5; successThreshold = 1;
      failureThreshold = 5;
    };
  };

  # Build a Deployment. This is the K8s Deployment object you're used to,
  # but as a Nix dict instead of YAML.
  #
  # `template = kixlib'.pod.mkPodTemplate { ... }` builds the
  # spec.template section. Again, just validated dicts.
  deployment = kixlib'.workload.mkDeployment {
    replicas = cfg.replicaCount;
    selectorLabels = labels.selector;
    strategy = {
      type = "RollingUpdate";
      rollingUpdate = { maxUnavailable = 1; maxSurge = "25%"; };
    };
    template = kixlib'.pod.mkPodTemplate {
      metadata.labels = labels.all;
      spec = {
        containers = [ container ];
        volumes = [ configVolume ];
        serviceAccountName = "coredns";
        dnsPolicy = "Default";
      };
    };
  };

  # Build a Service (the K8s Service object).
  service = kixlib'.networking.mkService {
    spec = {
      type = cfg.serviceType;
      ports = [
        { port = 53; protocol = "UDP"; targetPort = "udp-53"; name = "udp-53"; }
        { port = 53; protocol = "TCP"; targetPort = "tcp-53"; name = "tcp-53"; }
      ];
      selector = labels.selector;
    };
  };

  # A separate metrics Service (Prometheus scrapes this).
  metricsService = kixlib'.networking.mkService {
    metadata.name = "coredns-metrics";
    spec = {
      type = "ClusterIP";
      ports = [{ port = 9153; protocol = "TCP"; name = "metrics"; }];
      selector = labels.selector;
    };
  };

# ── manifestList: the final output ───────────────────────────────────────
#
# Each entry is { name, resource, enable }. The name becomes the key in
# config.manifests (e.g., config.manifests.coredns-deployment).
# The enable flag gates whether the resource is actually emitted.
#
# This is a flat list. You manually wire every resource. If you want an HPA,
# you build it separately and add another entry. If you want a PodDisruptionBudget, same
# thing. Nothing connects them — they're just items in a list.
in {
  manifestList = [
    { name = "coredns-sa"; resource = sa; enable = true; }
    { name = "coredns-clusterrole"; resource = clusterRole; enable = true; }
    { name = "coredns-clusterrolebinding"; resource = clusterRoleBinding; enable = true; }
    { name = "coredns-configmap"; resource = configMap; enable = true; }
    { name = "coredns-deployment"; resource = deployment; enable = true; }
    { name = "coredns-service"; resource = service; enable = true; }
    { name = "coredns-metrics-service"; resource = metricsService; enable = cfg.prometheus.monitor.enabled; }
  ];
}
```

**What's wrong with this?** Nothing, if you're deploying one chart. But:
- Want to add an HPA? You build it manually, add it to the list, AND
  remember to set `replicas = null` on the Deployment (HPA controls that now).
  Two places to change. Easy to forget one.
- Want a PodDisruptionBudget? Build it manually, add it to the list.
  Same selector-label copy-paste as HPA.
- Want monitoring? You already declared `metricsService` above, but the
  ServiceMonitor is created elsewhere (monitoring module). How does the
  monitoring module know where your metrics are? You tell it separately
  in `extraConfig.monitoring.targets`. Three places now.

Each cross-cutting concern is a scavenger hunt across the codebase.

---

## Part 2: What coredns COULD look like with V4 combinators

This is the vision from Luca's feedback (section 10) and the revised
architecture (07A). **None of this code exists yet.** Read it as a design
sketch showing where the pipe operators lead for workloads.

```nix
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  HYPOTHETICAL — V4 combinator-based coredns                            ║
# ║                                                                        ║
# ║  The key idea: instead of building each K8s resource separately and    ║
# ║  manually wiring them together, you describe a "service deployment"    ║
# ║  (a deployment + its service + its service account) as a UNIT, then    ║
# ║  PIPE it through combinators that add capabilities.                    ║
# ║                                                                        ║
# ║  Each combinator (withAutoscaler, withPodDisruptionBudget, etc.)      ║
# ║  knows how to modify the resources it receives AND create any        ║
# ║  additional resources needed.                                        ║
# ╚══════════════════════════════════════════════════════════════════════════╝

let
  # ── Step 1: Define your container ──────────────────────────────────────
  #
  # This part is IDENTICAL to today. A container spec is a container spec.
  # There's no reason to abstract this further — the fields map 1:1 to what
  # you'd write in a K8s YAML file.

  container = kixlib'.pod.mkContainer {
    name = "coredns";
    image = "coredns/coredns:1.11.1";
    args = ["-conf" "/etc/coredns/Corefile"];
    ports = [
      { containerPort = 53; protocol = "UDP"; name = "udp-53"; }
      { containerPort = 53; protocol = "TCP"; name = "tcp-53"; }
      { containerPort = 9153; protocol = "TCP"; name = "metrics"; }
    ];
    resources = cfg.resources;
    livenessProbe = {
      httpGet = { path = "/health"; port = 8080; };
      initialDelaySeconds = 60; failureThreshold = 5;
    };
    readinessProbe = {
      httpGet = { path = "/ready"; port = 8181; };
    };
  };

  # ── Step 2: Build a "resource group" and compose it ────────────────────
  #
  # mkServiceDeployment creates a RESOURCE GROUP — not a single K8s resource,
  # but a bundle: { deployment, service, serviceAccount }.
  #
  # In Python terms, think of it like a dataclass that holds three related
  # K8s objects together:
  #
  #   @dataclass
  #   class ResourceGroup:
  #       deployment: Deployment
  #       service: Service
  #       serviceAccount: ServiceAccount
  #       extras: list[Resource]    # anything combinators add (HPA, PodDisruptionBudget, etc.)
  #
  # The |> (pipe) operator passes this group through combinator functions.
  # Each combinator receives the whole group, modifies what it needs, and
  # returns the updated group.

  coredns = kixlib'.mkServiceDeployment {
    # ┌──────────────────────────────────────────────────────────────────┐
    # │  mkServiceDeployment bundles three things:                      │
    # │                                                                 │
    # │  1. A Deployment (with the container, volumes, pod spec)        │
    # │  2. A Service (mapping ports from the container)                │
    # │  3. A ServiceAccount (for RBAC)                                 │
    # │                                                                 │
    # │  It wires them together automatically:                          │
    # │  - The Deployment references the ServiceAccount by name         │
    # │  - The Service selector matches the Deployment's pod labels     │
    # │  - Labels are consistent across all three                       │
    # │                                                                 │
    # │  Today you do this wiring by hand — repeating the same          │
    # │  serviceAccountName string, the same selector labels, etc.      │
    # │  mkServiceDeployment does it once, correctly.                   │
    # └──────────────────────────────────────────────────────────────────┘
    containers = [ container ];
    volumes = [ configVolume ];
    replicas = cfg.replicaCount;
    servicePorts = [
      { port = 53; protocol = "UDP"; targetPort = "udp-53"; name = "udp-53"; }
      { port = 53; protocol = "TCP"; targetPort = "tcp-53"; name = "tcp-53"; }
    ];
    strategy = {
      type = "RollingUpdate";
      rollingUpdate = { maxUnavailable = 1; maxSurge = "25%"; };
    };
    dnsPolicy = "Default";
  }

  # ┌──────────────────────────────────────────────────────────────────────┐
  # │  THE PIPE CHAIN                                                     │
  # │                                                                     │
  # │  Each |> passes the resource group to a combinator function.        │
  # │  Each combinator may:                                               │
  # │    - Modify existing resources (e.g., set replicas = null)          │
  # │    - Add new resources to the group (e.g., an HPA)                  │
  # │    - Register capabilities (e.g., "I have metrics on port 9153")    │
  # │                                                                     │
  # │  Read it top to bottom as a pipeline:                               │
  # │    "Take the base deployment, add autoscaling, add a                │
  # │     PodDisruptionBudget, expose metrics."                          │
  # └──────────────────────────────────────────────────────────────────────┘

  # ── withAutoscaler ─────────────────────────────────────────────────────
  #
  # What it does:
  #   1. Sets deployment.replicas = null
  #      (because the HPA controls replica count now — if you leave replicas
  #       set, the Deployment controller and HPA fight each other)
  #   2. Registers a capability declaration:
  #      capabilities.autoscaling.coredns = { min = 2; max = 10; ... }
  #      (a separate autoscaling-hpa module reads this and creates the
  #       actual HPA resource — the chart never touches HPA YAML)
  #
  # Today's code: you have to remember to set replicas = null yourself AND
  # build the HPA manually. withAutoscaler makes these two things atomic —
  # you can't forget one without the other.
  #
  |> kixlib'.withAutoscaler {
    minReplicas = 2;
    maxReplicas = 10;
    metrics = [{
      type = "Resource";
      resource = { name = "cpu"; target = { type = "Utilization"; averageUtilization = 60; }; };
    }];
  }

  # ── withPDB ────────────────────────────────────────────────────────────
  #
  # Adds a PodDisruptionBudget. This is a K8s resource that tells the
  # cluster "don't evict more than N pods at once during a node drain."
  #
  # What it does:
  #   1. Creates a PodDisruptionBudget resource with the right selector
  #      (matching the Deployment's pod labels — automatically, not by
  #      copy-paste)
  #   2. Adds the PodDisruptionBudget to the resource group's extras list
  #
  # Today's code: you build the PodDisruptionBudget manually, copy the
  # selector labels, add it to manifestList. Three steps. withPDB: one step.
  #
  |> kixlib'.withPDB {
    minAvailable = 1;
  }

  # ── withMetrics ────────────────────────────────────────────────────────
  #
  # Declares that this service exposes Prometheus metrics.
  #
  # What it does:
  #   1. Creates a separate metrics Service (coredns-metrics) pointing at
  #      port 9153, so the primary Service only exposes DNS ports
  #   2. Registers a capability declaration:
  #      capabilities.monitoring.coredns = { port = 9153; path = "/metrics"; }
  #
  # A monitoring IMPLEMENTATION module (monitoring-prometheus.nix or
  # monitoring-datadog.nix) reads that declaration and:
  #   - For Prometheus: creates a ServiceMonitor resource
  #   - For Datadog: adds pod annotations
  #   - For neither: does nothing
  #
  # The chart doesn't know which monitoring system is in use. It just says
  # "I have metrics here." That's the zero-coupling principle.
  #
  # Today's code: you build metricsService by hand, then ALSO declare
  # monitoring.targets in extraConfig. Two places, easy to get out of sync.
  # withMetrics does both atomically.
  #
  |> kixlib'.withMetrics {
    port = 9153;
    path = "/metrics";
  };

# ── The output ───────────────────────────────────────────────────────────
#
# `coredns` is now a resource group containing:
#   - deployment  (replicas = null because withAutoscaler set it)
#   - service     (DNS ports only)
#   - serviceAccount
#   - extras:
#     - metricsService (added by withMetrics)
#     - PodDisruptionBudget (added by withPDB)
#   - _capabilities:
#     - autoscaling declaration (withAutoscaler registered it)
#     - monitoring declaration (withMetrics registered it)
#
# `toManifestList` flattens the group into the same manifestList format
# that mkChartModule expects. Each resource gets a human-readable name.
#
# The _capabilities are extracted by mkChartModule and written to
# extraConfig, where the implementation modules can read them.

in {
  manifestList = kixlib'.toManifestList coredns;

  # No more extraConfig.monitoring.targets — withMetrics handles it.
  # No more manually coordinating replicas with HPA — withAutoscaler handles it.
  extraConfig = kixlib'.extractCapabilities coredns;
}
```

---

## Part 3: What changed and why it matters

### Side-by-side comparison

| Concern | Today (Part 1) | V4 Combinators (Part 2) |
|---|---|---|
| **Autoscaling** | Build HPA manually, remember to null out replicas, add to manifestList | `\|> withAutoscaler { min = 2; max = 10; }` — replicas nulled automatically |
| **PodDisruptionBudget** | Build it manually, copy selector labels, add to manifestList | `\|> withPDB { minAvailable = 1; }` — selector derived automatically |
| **Monitoring** | Build metricsService + declare monitoring.targets in extraConfig separately | `\|> withMetrics { port = 9153; }` — both created atomically |
| **Wiring** | Repeat serviceAccountName, selector labels, port names across resources | mkServiceDeployment wires once, combinators inherit |

### The pipe operator makes the architecture readable

```nix
# The ENTIRE operational topology of coredns, left to right:
kixlib'.mkServiceDeployment { ... }      # base workload
  |> kixlib'.withAutoscaler { ... }      # + autoscaling
  |> kixlib'.withPDB { ... }             # + PodDisruptionBudget
  |> kixlib'.withMetrics { ... }         # + monitoring
```

Compare that to scrolling through 100+ lines of individually-built resources
trying to understand "what does this chart do?" The pipe chain IS the
architecture diagram.

### What's NOT in the pipe (intentionally)

The pipe chain only contains **application-level** concerns — things that
belong to the chart author. Cluster-level concerns are handled by
implementation modules that the chart never sees:

- **ServiceMonitor creation** → monitoring-prometheus.nix (reads the
  monitoring capability the chart declared)
- **HPA creation** → autoscaling-hpa.nix (reads the autoscaling capability)
- **NetworkPolicy** → network-policy.nix (reads declared ports and peers)

This is the "capability levels" principle from 07A: the chart says WHAT it
needs, the cluster config decides HOW.

### For the valkey (StatefulSet) case

The same pattern applies to StatefulSets. Valkey today builds separate
primaryStatefulSet, replicaStatefulSet, headlessSvc, primarySvc, replicaSvc
— all manually wired. The V4 equivalent would be:

```nix
# Hypothetical — not real code
valkey-primary = kixlib'.mkStatefulService {
  containers = [ primaryContainer ];
  volumeClaimTemplates = [ dataVolume ];
  serviceName = "valkey-headless";   # headless svc for stable DNS
  replicas = 1;
}
  |> kixlib'.withMetrics { port = 9121; }
  |> kixlib'.withPersistence { size = "8Gi"; storageClass = "fast"; };

valkey-replicas = kixlib'.mkStatefulService {
  containers = [ replicaContainer ];
  volumeClaimTemplates = [ dataVolume ];
  serviceName = "valkey-headless";
  replicas = cfg.replica.replicaCount;
}
  |> kixlib'.withMetrics { port = 9121; }
  |> kixlib'.withPersistence { size = "8Gi"; };
```

Same principle: describe the base, pipe through capabilities, let the
system wire the details.

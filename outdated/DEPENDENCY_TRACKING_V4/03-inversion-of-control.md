# 03: Inversion of Control — The "BE Found" Pattern

## Luca's Insight

> Instead of "what are the labels of the thing I have to find", you could also
> ask as coredns "what are the labels I need to put to BE found." The second is
> MUCH nicer with the module system because suddenly the assumption to the config
> is no longer "knowing everything about the deployed manifest" but rather "if kix
> has a monitoring primitive, that might be implemented in whatever way, and I want
> to support it, I can depend on it."

This is dependency inversion applied to the module system. Currently:

```
coredns ──knows about──> monitoring.targets (Prometheus-shaped options)
monitoring.nix ──knows about──> ServiceMonitor (Prometheus Operator CRD)
```

Both sides know about Prometheus. Changing the monitoring backend requires
changing both charts AND the monitoring module.

Luca's proposal:

```
coredns ──declares──> "I have metrics on port 9153" (abstract)
coredns <──reads──── "put these labels on your pods" (bidirectional)
monitoring-impl ──reads──> abstract declarations
monitoring-impl ──writes──> labels/annotations back to charts
monitoring-impl ──creates──> ServiceMonitor (or Datadog annotations, or whatever)
```

Neither side knows about the other. Both depend on an abstract capability interface.

## The NixOS Precedent

NixOS already does this everywhere:

- **nginx doesn't know about iptables.** It opens port 80. The firewall module
  creates iptables rules. Nginx never touches `networking.firewall`.
- **ACME/Let's Encrypt.** Nginx says "I want TLS for this domain." The ACME
  module handles certificate generation. Nginx doesn't know about DNS challenges,
  HTTP challenges, or certificate renewal.
- **systemd.** Services declare what they need (ExecStart, User, etc.). The
  systemd module creates unit files. Services don't write unit files.

The pattern: services declare WHAT they need. Infrastructure modules handle HOW.

## Design: Capability Interfaces

### The Abstract Layer

```nix
# modules/capabilities/monitoring.nix — THE INTERFACE
#
# Defines WHAT monitoring means, not HOW it's implemented.
# Charts write the input fields. Implementation modules write the output fields.
{ lib, ... }:
{
  options.capabilities.monitoring = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        # --- Input fields (written by charts) ---
        port = lib.mkOption {
          type = lib.types.int;
          description = "Port where metrics are exposed.";
        };
        path = lib.mkOption {
          type = lib.types.str;
          default = "/metrics";
        };
        interval = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Desired scrape interval. Null = cluster default.";
        };

        # --- Output fields (written by implementation modules) ---
        # The implementation tells the chart what to do to be discovered.
        annotations = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Annotations to add to pods/services for discovery.";
        };
        labels = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Labels to add to pods/services for discovery.";
        };
      };
    });
    default = {};
  };
}
```

### The Chart Side (coredns)

```nix
# In pkgs/coredns/resources.nix — extraConfig section
#
# coredns doesn't know about ServiceMonitors, Prometheus, or Datadog.
# It just says "I have metrics on port 9153".
extraConfig = {
  capabilities.monitoring.coredns = lib.mkIf (hasPrometheus && cfg.prometheus.monitor.enabled) {
    port = 9153;
    path = "/metrics";
  };
};
```

And critically, coredns reads BACK from the capability when building resources:

```nix
# In pkgs/coredns/resources.nix — resource construction
#
# The monitoring capability tells coredns what annotations/labels to add.
# coredns doesn't know WHY — it just applies them.
monitoringMeta = config.capabilities.monitoring.coredns or {};

metricsService = kixlibCoredns.networking.mkService {
  metadata = {
    name = "coredns-metrics";
    labels = { "app.kubernetes.io/component" = "metrics"; }
      // (monitoringMeta.labels or {});
    annotations = cfg.prometheus.service.annotations
      // (monitoringMeta.annotations or {});
  };
  spec = {
    ports = [{ name = "metrics"; port = 9153; targetPort = 9153; }];
    selector = selectorLabels;
  };
};
```

### The Prometheus Implementation

```nix
# modules/implementations/monitoring-prometheus.nix
#
# Knows about Prometheus Operator. Reads abstract capabilities, creates
# ServiceMonitors. Charts don't know this module exists.
{ lib, config, kixlib, ... }:
let
  targets = config.capabilities.monitoring;
  discoveryLabel = "kix.monitoring/scrape";
in {
  config = lib.mkIf config.monitoring.enabled {
    # Write BACK to charts: "put this label on your services"
    capabilities.monitoring = lib.mapAttrs (name: target: {
      labels.${discoveryLabel} = "true";
      annotations = {
        "kix.monitoring/port" = toString target.port;
        "kix.monitoring/path" = target.path;
      };
    }) targets;

    # Create ServiceMonitor resources
    manifests = lib.mapAttrs' (name: target:
      lib.nameValuePair "monitoring-${name}-servicemonitor" (
        kixlib.monitoring.mkServiceMonitor {
          metadata = {
            name = "${name}-monitor";
            namespace = config.services.${name}.namespace or "default";
            labels = config.cluster.labels // {
              "app.kubernetes.io/managed-by" = "kix";
            };
          };
          endpoints = [{
            port = "metrics";
            interval = if target.interval != null
              then target.interval
              else config.monitoring.defaultInterval;
          }];
          selector.matchLabels.${discoveryLabel} = "true";
          namespaceSelector.matchNames = [
            (config.services.${name}.namespace or "default")
          ];
        }
      )
    ) targets;
  };
}
```

### A Datadog Alternative (same interface, zero chart changes)

```nix
# modules/implementations/monitoring-datadog.nix
#
# Drop-in replacement. Charts still just declare { port = 9153; }.
{ lib, config, ... }:
let targets = config.capabilities.monitoring; in {
  config = lib.mkIf (config.monitoring.enabled && config.monitoring.provider == "datadog") {
    # Datadog uses annotations on pods, not ServiceMonitors
    capabilities.monitoring = lib.mapAttrs (name: target: {
      annotations = {
        "ad.datadoghq.com/check_names" = ''["openmetrics"]'';
        "ad.datadoghq.com/init_configs" = "[{}]";
        "ad.datadoghq.com/instances" = builtins.toJSON [{
          prometheus_url = "http://%%host%%:${toString target.port}${target.path}";
          namespace = name;
          metrics = ["*"];
        }];
      };
    }) targets;
    # No ServiceMonitors needed — Datadog agent discovers via annotations
  };
}
```

**Zero chart code changed.** coredns still just says `port = 9153`.

## How the Bidirectional Flow Works

The NixOS module system's merge semantics make this possible. Multiple modules
can write to the same option path:

1. coredns sets `capabilities.monitoring.coredns.port = 9153`
2. monitoring-prometheus sets `capabilities.monitoring.coredns.labels = { ... }`
3. The module system merges both into one attrset

This is exactly how NixOS works: nginx declares ports, firewall reads them.
The option is a meeting point owned by neither side.

The one subtlety: the `labels` and `annotations` output fields need mergeable
types (`types.attrsOf types.str`). The chart sets the default (`{}`), the
implementation module sets actual values. The module system merges naturally.

## Extending to Other Capabilities

### Autoscaling

```nix
# modules/capabilities/autoscaling.nix
options.capabilities.autoscaling = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      # Input (chart declares)
      minReplicas = lib.mkOption { type = lib.types.int; default = 1; };
      maxReplicas = lib.mkOption { type = lib.types.int; };
      metrics = lib.mkOption { type = lib.types.listOf lib.types.anything; default = []; };

      # Output (implementation tells the chart)
      controlledByAutoscaler = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "When true, chart should omit spec.replicas.";
      };
    };
  });
  default = {};
};
```

Chart reads `controlledByAutoscaler` to decide whether to set `replicas`:

```nix
deployment = kixlibCoredns.workload.mkDeployment {
  replicas = if (config.capabilities.autoscaling.coredns.controlledByAutoscaler or false)
    then null
    else cfg.replicaCount;
  ...
};
```

### Network Policy

```nix
options.capabilities.networkPolicy = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      # Input
      ingressPorts = lib.mkOption { type = lib.types.listOf lib.types.int; };
      egressTo = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
      # Output
      podSelector = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; };
    };
  });
  default = {};
};
```

## Module Structure

```
modules/
  capabilities/
    monitoring.nix       # interface: "I have metrics"
    autoscaling.nix      # interface: "I want to scale"
    network-policy.nix   # interface: "I listen on these ports"
  implementations/
    monitoring-prometheus.nix   # ServiceMonitor creation
    monitoring-datadog.nix      # annotation-based discovery
    autoscaling-hpa.nix         # HPA creation
    autoscaling-keda.nix        # KEDA ScaledObject creation
    network-policy-k8s.nix      # native NetworkPolicy
    network-policy-cilium.nix   # CiliumNetworkPolicy
```

Cluster config selects implementations:

```nix
# clusters/production.nix
{
  monitoring = { enabled = true; provider = "prometheus"; defaultInterval = "15s"; };
  autoscaling.provider = "hpa";
  networkPolicy.provider = "kubernetes";
  services.coredns.enable = true;
}
```

## Options Considered

### Option A: Keep monitoring.targets (current)

Charts declare targets with K8s-level details (serviceName, portName, selector).
Monitoring module creates ServiceMonitors.

**Verdict**: Rejected. Tightly couples charts to Prometheus concepts.

### Option B: Abstract targets without bidirectional flow

Charts declare `monitoring.targets.coredns = { port = 9153; }`. Monitoring
module creates ServiceMonitors but doesn't write back to charts.

**Verdict**: Insufficient. The monitoring module still needs to know how to
find the chart's Service (by name convention). Charts can't be told what
labels/annotations to add for discovery.

### Option C: Capability interfaces with bidirectional flow (recommended)

As described above. Charts declare abstract capabilities, read back what they
need to do to be discovered. Implementation modules handle everything else.

**Verdict**: Recommended. Zero coupling. Swappable implementations. Tested
pattern (NixOS uses it everywhere).

## Recommendation

**Option C.** The capability interface pattern with bidirectional flow is the
clean architectural answer to Luca's feedback. It inverts the dependency
direction, eliminates tight coupling, and makes `config.manifests` a terminal
output that nothing reads from.

The migration is incremental: we can convert monitoring first (it already has
a cross-cutting module), then add autoscaling and network policy capabilities.
Each conversion simplifies the chart code (less K8s-level detail in
extraConfig) while making the system more extensible.

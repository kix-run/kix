# 31 — Port Fan-out: Declare Once, Wire Everywhere

## Problem

In valkey, the redis port `6379` appears in **10+ places**:

| Location | Code |
|---|---|
| Container env `VALKEY_PORT` | `"6379"` |
| Container env `VALKEY_PRIMARY_PORT_NUMBER` | `"6379"` |
| Container ports | `kix.port "redis" 6379` |
| Headless Service ports | `{ name = "tcp-redis"; port = 6379; targetPort = "redis"; }` |
| Main Service ports | `{ name = "tcp-redis"; port = 6379; targetPort = "redis"; }` |
| Main Service outputs | `outputs = { port = "6379"; }` |
| NetworkPolicy ingress | `{ port = 6379; protocol = "TCP"; }` |
| sentinel.conf | `sentinel monitor ... 6379 ...` |
| Shell scripts (fallback) | `echo 6379` |
| Sentinel port `26379` | Same fan-out pattern across all the above |

If someone changes the port, they must find and update every occurrence. Misses cause silent breakage.

## Design Constraint

Resources MUST stay vanilla K8s -- no magical keys in workload specs. A StatefulSet spec must look like a real K8s StatefulSet spec. Magic happens in **pipe transforms** and **scope helpers** that operate on the attribute set before or after `mkResource`.

## Proposal: `kix.ports` -- named port registry + fan-out transforms

### Core Idea

Declare ports once in a `let` binding as a structured object. Pipe transforms and helper functions consume the port object to generate the repetitive K8s boilerplate.

```nix
# Declare once
ports = {
  redis    = kix.namedPort "redis" 6379;
  sentinel = kix.namedPort "valkey-sentinel" 26379;
  metrics  = kix.namedPort "metrics" 9121;
};
```

A `namedPort` is a plain attrset:
```nix
# kix.namedPort : string -> int -> PortDef
namedPort = name: number: {
  inherit name number;
  protocol = "TCP";
  # Convenience accessors for different contexts:
  container = { inherit name; containerPort = number; protocol = "TCP"; };
  service   = { name = "tcp-${name}"; port = number; targetPort = name; protocol = "TCP"; };
  netpol    = { port = number; protocol = "TCP"; };
  env       = toString number;
};
```

### Before/After: Container Ports

**Before:**
```nix
valkeyContainer = {
  # ...
  env = kix.mkEnvVars {
    VALKEY_PORT = "6379";
    VALKEY_SENTINEL_PORT = "26379";
    VALKEY_PRIMARY_PORT_NUMBER = "6379";
    # ...
  };
  ports = [
    (kix.port "redis" 6379)
  ];
  # ...
};

sentinelContainer = {
  # ...
  env = kix.mkEnvVars {
    VALKEY_SENTINEL_PORT = "26379";
    # ...
  };
  ports = [
    (kix.port "valkey-sentinel" 26379)
  ];
  # ...
};
```

**After:**
```nix
valkeyContainer = {
  # ...
  env = kix.mkEnvVars {
    VALKEY_PORT = ports.redis.env;               # "6379"
    VALKEY_SENTINEL_PORT = ports.sentinel.env;   # "26379"
    VALKEY_PRIMARY_PORT_NUMBER = ports.redis.env; # "6379"
    # ...
  };
  ports = [
    ports.redis.container      # { name = "redis"; containerPort = 6379; protocol = "TCP"; }
  ];
  # ...
};

sentinelContainer = {
  # ...
  env = kix.mkEnvVars {
    VALKEY_SENTINEL_PORT = ports.sentinel.env;   # "26379"
    # ...
  };
  ports = [
    ports.sentinel.container   # { name = "valkey-sentinel"; containerPort = 26379; protocol = "TCP"; }
  ];
  # ...
};
```

The container spec remains vanilla K8s. The port definition just comes from a variable instead of a literal.

### Before/After: Service

**Before:**
```nix
headlessService = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "${name}-headless";
  spec = {
    type = "ClusterIP";
    clusterIP = "None";
    publishNotReadyAddresses = true;
    selector = selectorLabels;
    ports = [
      {
        name = "tcp-redis";
        port = 6379;
        targetPort = "redis";
        protocol = "TCP";
      }
    ]
    ++ lib.optional config.sentinel.enabled {
      name = "tcp-sentinel";
      port = 26379;
      targetPort = "valkey-sentinel";
      protocol = "TCP";
    };
  };
  requires = [ self.statefulSet ];
};

mainService = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "${name}";
  spec = {
    type = "ClusterIP";
    selector = selectorLabels // componentLabel;
    ports = [
      {
        name = "tcp-redis";
        port = 6379;
        targetPort = "redis";
        protocol = "TCP";
      }
    ]
    ++ lib.optional config.sentinel.enabled {
      name = "tcp-sentinel";
      port = 26379;
      targetPort = "valkey-sentinel";
      protocol = "TCP";
    };
  };
  outputs = {
    port = "6379";
  }
  // lib.optionalAttrs config.sentinel.enabled {
    sentinelPort = "26379";
    primarySet = config.sentinel.primarySet;
  };
  requires = [ self.statefulSet ];
};
```

**After:**
```nix
headlessService = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "${name}-headless";
  spec = {
    type = "ClusterIP";
    clusterIP = "None";
    publishNotReadyAddresses = true;
    selector = selectorLabels;
    ports = [ ports.redis.service ]
      ++ lib.optional config.sentinel.enabled ports.sentinel.service;
  };
  requires = [ self.statefulSet ];
};

mainService = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "${name}";
  spec = {
    type = "ClusterIP";
    selector = selectorLabels // componentLabel;
    ports = [ ports.redis.service ]
      ++ lib.optional config.sentinel.enabled ports.sentinel.service;
  };
  outputs = {
    port = ports.redis.env;
  }
  // lib.optionalAttrs config.sentinel.enabled {
    sentinelPort = ports.sentinel.env;
    primarySet = config.sentinel.primarySet;
  };
  requires = [ self.statefulSet ];
};
```

### Before/After: NetworkPolicy

**Before:**
```nix
networkPolicy = scope.mkResource {
  apiVersion = "networking.k8s.io/v1";
  kind = "NetworkPolicy";
  inherit name;
  spec = {
    podSelector.matchLabels = selectorLabels;
    policyTypes = [ "Ingress" "Egress" ];
    egress = [ { } ];
    ingress = [
      {
        ports = [
          { port = 6379; protocol = "TCP"; }
        ]
        ++ lib.optional config.sentinel.enabled
          { port = 26379; protocol = "TCP"; };
      }
    ]
    ++ lib.optional config.metrics.enabled {
      ports = [ { port = 9121; protocol = "TCP"; } ];
    };
  };
};
```

**After:**
```nix
networkPolicy = scope.mkResource {
  apiVersion = "networking.k8s.io/v1";
  kind = "NetworkPolicy";
  inherit name;
  spec = {
    podSelector.matchLabels = selectorLabels;
    policyTypes = [ "Ingress" "Egress" ];
    egress = [ { } ];
    ingress = [
      {
        ports = [ ports.redis.netpol ]
          ++ lib.optional config.sentinel.enabled ports.sentinel.netpol;
      }
    ]
    ++ lib.optional config.metrics.enabled {
      ports = [ ports.metrics.netpol ];
    };
  };
};
```

### Before/After: out declaration (on mainService)

**Before:**
```nix
outputs = {
  port = "6379";
}
// lib.optionalAttrs config.sentinel.enabled {
  sentinelPort = "26379";
  primarySet = config.sentinel.primarySet;
};
```

**After:**
```nix
outputs = {
  port = ports.redis.env;      # "6379" -- single source of truth
}
// lib.optionalAttrs config.sentinel.enabled {
  sentinelPort = ports.sentinel.env;  # "26379"
  primarySet = config.sentinel.primarySet;
};
```

### Before/After: Config strings (sentinel.conf)

**Before:**
```nix
sentinelConf = ''
  dir "/tmp"
  port 26379
  sentinel monitor ${config.sentinel.primarySet} ${name}-node-0.${headlessServiceFqdn} 6379 ${toString config.sentinel.quorum}
'';
```

**After:**
```nix
sentinelConf = ''
  dir "/tmp"
  port ${ports.sentinel.env}
  sentinel monitor ${config.sentinel.primarySet} ${name}-node-0.${headlessServiceFqdn} ${ports.redis.env} ${toString config.sentinel.quorum}
'';
```

## What This Does NOT Do

1. **No magic fields on workloads.** Container specs are still vanilla K8s. The `ports.redis.container` expression evaluates to a plain `{ name, containerPort, protocol }` attrset -- exactly what K8s expects.

2. **No new scope functions.** This is pure data + accessors in `kix` (compose.nix). No changes to `scope.nix` or `k8s.nix`.

3. **No auto-propagation from workload to Service.** That already exists via `kix.service.fromWorkload`. This proposal addresses the *other* fan-out points (env vars, NetworkPolicy, outputs, config strings) that `fromWorkload` cannot reach.

## Implementation

Add to `lib/compose.nix`:

```nix
# Named port with pre-computed projections for each K8s context.
#
# Usage:
#   redis = kix.namedPort "redis" 6379;
#   redis.container  → { name = "redis"; containerPort = 6379; protocol = "TCP"; }
#   redis.service    → { name = "tcp-redis"; port = 6379; targetPort = "redis"; protocol = "TCP"; }
#   redis.netpol     → { port = 6379; protocol = "TCP"; }
#   redis.env        → "6379"
#   redis.number     → 6379  (raw int, for arithmetic or interpolation)
namedPort = name: number: {
  inherit name number;
  protocol = "TCP";
  container = { inherit name; containerPort = number; protocol = "TCP"; };
  service   = { name = "tcp-${name}"; port = number; targetPort = name; protocol = "TCP"; };
  netpol    = { port = number; protocol = "TCP"; };
  env       = toString number;
};
```

That is it. One function, no framework changes. Packages opt in incrementally.

## Migration

This is backward-compatible. Existing packages keep working. Migration is mechanical:

1. Add a `ports = { ... }` block with `kix.namedPort` declarations.
2. Replace literal port numbers with the appropriate projection.
3. Verify with `nix build` -- output hashes should not change (same manifest content).

## Open Questions

1. **Should `namedPort` support UDP?** Could add an optional third arg or use `// { protocol = "UDP"; }` on the result. The override approach works today since it is just an attrset.

2. **Service port naming convention.** The `"tcp-${name}"` pattern matches Bitnami's convention. Other packages might prefer just `name`. Could make configurable: `namedPort "redis" 6379 // { service = { name = "redis"; ... }; }` -- but that defeats the purpose. Better to pick one convention and let packages override the `.service` field when needed.

3. **Should `kix.service.fromWorkload` use `namedPort` internally?** It already derives service ports from container ports. Could return `namedPort`-shaped objects in its output. Low priority -- the two mechanisms are complementary, not competing.

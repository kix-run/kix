# Options Mapping: Helm values.yaml → Nix mkOption

## Type Mapping

| Helm YAML type | Nix type | Notes |
|---|---|---|
| `string` | `types.str` | |
| `string (optional)` | `types.nullOr types.str` | Default `null` |
| `integer` | `types.int` | |
| `boolean` | `types.bool` | |
| `list of strings` | `types.listOf types.str` | |
| `list of objects` | `types.listOf types.attrs` | For passthrough (extraVolumes, etc.) |
| `list of typed objects` | `types.listOf (types.submodule { ... })` | When structure is known |
| `object (typed)` | `types.submodule { ... }` | When structure is known |
| `object (passthrough)` | `types.attrsOf types.anything` | For arbitrary user data |
| `map<string,string>` | `types.attrsOf types.str` | Labels, annotations, etc. |

## Values to Skip

These Helm values exist for template/release management reasons and don't apply in kix:

- `nameOverride` / `fullnameOverride` — kix uses `applicationName` directly
- `clusterRole.nameOverride` — same reason
- `deployment.name` — use `applicationName`
- `rbac.create` — if you need RBAC, create it; kix modules control their own resources

## Values to Restructure

Helm's flat values sometimes benefit from restructuring in kix:

### Image configuration
```yaml
# Helm values.yaml
image:
  repository: coredns/coredns
  tag: "1.12.3"
  pullPolicy: IfNotPresent
  pullSecrets: []
```

```nix
# kix option
image = lib.mkOption {
  type = types.submodule {
    options = {
      repository = lib.mkOption {
        type = types.str;
        default = "coredns/coredns";
      };
      tag = lib.mkOption {
        type = types.str;
        default = "1.12.3";
      };
      pullPolicy = lib.mkOption {
        type = types.str;
        default = "IfNotPresent";
      };
    };
  };
};
```

### Probe configuration
```yaml
# Helm: flat with enabled flag
livenessProbe:
  enabled: true
  initialDelaySeconds: 60
  periodSeconds: 10
```

```nix
# kix: the enabled flag controls whether the probe is set, the rest maps directly
livenessProbe = lib.mkOption {
  type = types.submodule {
    options = {
      enabled = lib.mkOption { type = types.bool; default = true; };
      initialDelaySeconds = lib.mkOption { type = types.int; default = 60; };
      periodSeconds = lib.mkOption { type = types.int; default = 10; };
      timeoutSeconds = lib.mkOption { type = types.int; default = 5; };
      failureThreshold = lib.mkOption { type = types.int; default = 5; };
      successThreshold = lib.mkOption { type = types.int; default = 1; };
    };
  };
};
```

Usage in resource construction:
```nix
|> lib.optionalAttrs cfg.livenessProbe.enabled {
  livenessProbe = {
    httpGet = { path = "/health"; port = 8080; scheme = "HTTP"; };
    inherit (cfg.livenessProbe) initialDelaySeconds periodSeconds timeoutSeconds failureThreshold successThreshold;
  };
}
```

### Resources (CPU/memory)
These map 1:1 — keep the same structure:
```nix
resources = lib.mkOption {
  type = types.submodule {
    options = {
      limits = lib.mkOption { type = types.attrsOf types.str; default = { cpu = "100m"; memory = "128Mi"; }; };
      requests = lib.mkOption { type = types.attrsOf types.str; default = { cpu = "100m"; memory = "128Mi"; }; };
    };
  };
};
```

## Passthrough / Extra Options

Helm charts commonly have "escape hatches" for arbitrary user data. Map these as:

```nix
extraVolumes = lib.mkOption {
  type = types.listOf types.attrs;
  default = [ ];
  description = "Additional volumes to add to the pod.";
};

extraContainers = lib.mkOption {
  type = types.listOf types.attrs;
  default = [ ];
  description = "Additional sidecar containers.";
};

podAnnotations = lib.mkOption {
  type = types.attrsOf types.str;
  default = { };
  description = "Annotations to add to pods.";
};

customLabels = lib.mkOption {
  type = types.attrsOf types.str;
  default = { };
  description = "Custom labels applied to all resources.";
};
```

## Service Account Pattern

```nix
serviceAccount = lib.mkOption {
  type = types.submodule {
    options = {
      create = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether to create a ServiceAccount.";
      };
      name = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Name of an existing ServiceAccount to use (when create is false).";
      };
    };
  };
};
```

## Feature Toggle Pattern

For optional features (autoscaler, HPA, monitoring):

```nix
hpa = lib.mkOption {
  type = types.submodule {
    options = {
      enabled = lib.mkOption {
        type = types.bool;
        default = false;
      };
      minReplicas = lib.mkOption {
        type = types.int;
        default = 1;
      };
      maxReplicas = lib.mkOption {
        type = types.int;
        default = 10;
      };
      metrics = lib.mkOption {
        type = types.listOf types.attrs;
        default = [ ];
      };
    };
  };
};
```

Used in config:
```nix
config.manifests = lib.optionalAttrs (cfg.hpa.enabled && !cfg.autoscaler.enabled) {
  "<name>-hpa" = kixlib'.mkManifest (mkHpa cfg.hpa);
};
```

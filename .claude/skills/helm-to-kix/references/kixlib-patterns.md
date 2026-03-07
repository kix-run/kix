# kixlib Patterns Reference

kixlib is the shared library at `lib/default.nix`. Read the header comment there for
architectural decisions and rationale.

## Core Concepts

### resourceName
Derives a human-readable K8s name from a resource attrset:
```nix
kixlib.resourceName resource  # → "coredns" (from metadata.name or app label)
```

### mkManifest
Serializes a resource attrset to a JSON store derivation. Sets `metadata.name` via
`resourceName`, strips nulls, runs preprocessors:
```nix
kixlib.mkManifest resource  # → /nix/store/...-coredns-deployment.json
```
This is the ONLY function that returns a derivation. Everything else returns attrsets.

### mkResource
Base builder. Merges default metadata (from `withMetadata`) into the resource:
```nix
kixlib.mkResource { apiVersion = "v1"; kind = "ConfigMap"; data = { key = "value"; }; }
```

### withMetadata
Sets default namespace, labels, annotations for all resources:
```nix
kixlib' = kixlib.withMetadata {
  namespace = "my-namespace";
  labels = {
    "app.kubernetes.io/managed-by" = "kix";
    "app.kubernetes.io/name" = "my-app";
  };
};
```

## Builder Namespaces

### kixlib.workload

**mkDeployment**:
```nix
kixlib.workload.mkDeployment {
  replicas = 3;
  selectorLabels = selectorLabels;  # IMPORTANT: stable labels only
  strategy = { type = "RollingUpdate"; rollingUpdate = { maxSurge = "25%"; maxUnavailable = 1; }; };
  template = kixlib.pod.mkPodTemplate {
    metadata.labels = selectorLabels // { "app.kubernetes.io/version" = "1.0"; };
    spec = { containers = [ myContainer ]; volumes = [ myVolume ]; };
  };
}
```

**withServiceAccount** — sets serviceAccountName using human-readable name:
```nix
deployment |> kixlib.workload.withServiceAccount serviceAccount
```

**intoService** — creates a Service using the Deployment's selector labels.
You MUST include spec.ports — they are NOT auto-derived:
```nix
deployment |> kixlib.workload.intoService {
  spec.type = "ClusterIP";
  spec.ports = [ { port = 80; targetPort = 8080; protocol = "TCP"; name = "http"; } ];
}
```

### kixlib.pod

**mkContainer** — passthrough: returns ALL arguments as-is:
```nix
kixlib.pod.mkContainer {
  name = "my-app";
  image = "my-image:v1.0";
  imagePullPolicy = "IfNotPresent";
  args = [ "-conf" "/etc/config" ];
  resources = { limits = { cpu = "100m"; memory = "128Mi"; }; };
  ports = [ { containerPort = 8080; protocol = "TCP"; name = "http"; } ];
  securityContext = { allowPrivilegeEscalation = false; };
  # Any valid container field works — lifecycle, envFrom, workingDir, etc.
}
```

**withVolumeMount / withLivenessProbe / withReadinessProbe** — pipe-friendly:
```nix
container
|> kixlib.pod.withVolumeMount { name = "config"; mountPath = "/etc/config"; }
|> kixlib.pod.withLivenessProbe { httpGet = { path = "/health"; port = 8080; }; }
|> kixlib.pod.withReadinessProbe { httpGet = { path = "/ready"; port = 8181; }; }
```

### kixlib.rbac

**mkServiceAccount / mkClusterRole**:
```nix
sa = kixlib.rbac.mkServiceAccount { };
role = kixlib.rbac.mkClusterRole {
  rules = [
    { apiGroups = [ "" ]; resources = [ "pods" "services" ]; verbs = [ "list" "watch" ]; }
  ];
};
```

**mkClusterRoleBinding** — returns an attrset (composable):
```nix
binding = kixlib.rbac.mkClusterRoleBinding clusterRole serviceAccount;
# Can pipe through further transformations before mkManifest
```

**bind** — DEPRECATED convenience that returns a derivation directly.
Prefer mkClusterRoleBinding for composability.

### kixlib.networking

**mkService** — for standalone services (when not using intoService):
```nix
kixlib.networking.mkService {
  spec = {
    type = "ClusterIP";
    ports = [ { port = 53; targetPort = 53; protocol = "UDP"; name = "udp-53"; } ];
    selector = selectorLabels;
  };
}
```

### kixlib.configMap

**mkConfigMap / withEntry / withEntries / asVolume**:
```nix
configMap = kixlib.configMap.mkConfigMap { }
  |> kixlib.configMap.withEntry "Corefile" corefileContent
  |> kixlib.configMap.withEntries [ { key = "extra.conf"; value = extraContent; } ];

# Turn into a volume for pod template
configVolume = configMap |> kixlib.configMap.asVolume {
  items = [ { key = "Corefile"; path = "Corefile"; } ];
};
```

## Output Pattern

Each module should output ONE manifest entry per resource:

```nix
config.manifests = lib.optionalAttrs cfg.enable {
  "${name}-sa" = kixlib'.mkManifest sa;
  "${name}-clusterrole" = kixlib'.mkManifest clusterRole;
  "${name}-clusterrolebinding" = kixlib'.mkManifest binding;
  "${name}-configmap" = kixlib'.mkManifest configMap;
  "${name}-deployment" = kixlib'.mkManifest deployment;
  "${name}-service" = kixlib'.mkManifest service;
};
```

## Adding New Builders

When a chart needs a resource type kixlib doesn't support:

1. Place in the appropriate namespace (or create one)
2. Use `self.mkResource` as the base
3. Set correct `apiVersion` and `kind`
4. Accept minimum required fields, use `...` for passthrough
5. Return an attrset, NOT a derivation
6. Add a detailed comment explaining the builder and any gotchas

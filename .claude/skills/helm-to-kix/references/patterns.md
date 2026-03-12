# Patterns from Existing Packages

## Package Complexity Tiers

### Simple: CoreDNS (pkgs-fp/coredns/)
- Single workload (Deployment) + Service + ConfigMap + RBAC
- Optional: HPA, PDB, metrics Service, cluster-proportional autoscaler (sub-component with own RBAC)
- Helpers extracted to `helpers.nix` for domain-specific logic (Corefile builder, port derivation)
- `main` = DNS Service with requires on workload + conditional optional resources

### Medium: Valkey (pkgs-fp/valkey/)
- Two modes: replication (primary SS + replica SS) vs sentinel (single node SS)
- Mode switching via `if sentinel.enabled then ... else ...` throughout
- Shell scripts with @PLACEHOLDER@ templating
- Shared container/volume/env helpers in `let` block (mkValkeyContainer, mkPodSpec, etc.)
- `main` selects different Service depending on mode:
  ```nix
  main = k8s.withRequires (...) (if sentinel.enabled then self.sentinelSvc else self.primarySvc);
  ```

### Complex: cert-manager (pkgs-fp/cert-manager/)
- 4 components: controller, webhook, cainjector, startupapicheck
- Extensive RBAC: 8+ ClusterRoles for controller, per-component RBAC
- Webhook admission configurations (MutatingWebhookConfiguration, ValidatingWebhookConfiguration)
- Each component has own labels, SA, Deployment/Job
- `main` = controller Service with requires on all component Deployments + webhook configs

## Multi-Component Label Pattern (cert-manager)

```nix
# Per-component labels
mkComponentLabels = component: {
  "app.kubernetes.io/instance" = instance;
  "app.kubernetes.io/name" = "cert-manager";
  "app.kubernetes.io/component" = component;
};

controllerLabels = allLabels // { "app.kubernetes.io/component" = "controller"; };
webhookLabels = allLabels // { "app.kubernetes.io/component" = "webhook"; };
cainjectorLabels = allLabels // { "app.kubernetes.io/component" = "cainjector"; };
```

## StatefulSet with VolumeClaimTemplates (Valkey)

volumeClaimTemplates go in `extra` to avoid clobbering the resolved spec:

```nix
primarySs = k8s.mkResource {
  kind = "StatefulSet";
  spec = {
    serviceName = self.headlessSvc.ref;
    selector.matchLabels = withComponent "primary";
    template = { ... };
  };
  extra = {
    spec.volumeClaimTemplates = lib.optionals persistence.enabled [{
      apiVersion = "v1";
      kind = "PersistentVolumeClaim";
      metadata = { name = "valkey-data"; labels = componentLabels; };
      spec = {
        accessModes = persistence.accessModes;
        resources.requests.storage = persistence.size;
      } // lib.optionalAttrs (persistence.storageClass != null) {
        storageClassName = persistence.storageClass;
      };
    }];
  };
};
```

## Headless Service (Valkey)

```nix
headlessSvc = k8s.mkResource {
  kind = "Service";
  name = "${fullname}-headless";
  spec = {
    type = "ClusterIP";
    clusterIP = "None";
    publishNotReadyAddresses = true;  # common for StatefulSet headless services
    selector = selectorLabels;
    ports = [ ... ];
  };
};
```

## NetworkPolicy Pattern (Valkey)

```nix
networkPolicyRes = k8s.mkResource {
  apiVersion = "networking.k8s.io/v1";
  kind = "NetworkPolicy";
  spec = {
    podSelector.matchLabels = selectorLabels;
    policyTypes = [ "Ingress" "Egress" ];
    egress = [ {} ];  # allow all egress
    ingress = [
      { ports = [ { port = 6379; } ] ++ lib.optionals sentinel.enabled [ { port = 26379; } ]; }
    ] ++ lib.optionals metrics.enabled [
      { ports = [ { port = 9121; } ]; }
    ];
  };
};
```

## Webhook Configuration Pattern (cert-manager)

```nix
mutatingWebhook = k8s.mkResource {
  apiVersion = "admissionregistration.k8s.io/v1";
  kind = "MutatingWebhookConfiguration";
  name = "cert-manager-webhook";
  namespace = null;  # cluster-scoped
  labels = webhookLabels;
  annotations = {
    "cert-manager.io/inject-ca-from-secret" = "${namespace}/cert-manager-webhook-ca";
  };
  webhooks = [{  # top-level field, not under spec
    name = "webhook.cert-manager.io";
    rules = [{ apiGroups = [...]; apiVersions = [...]; operations = [...]; resources = [...]; }];
    admissionReviewVersions = ["v1"];
    clientConfig.service = {
      name = self.webhookService.ref;
      namespace = namespace;
      path = "/mutate";
    };
    ...
  }];
};
```

## Job Pattern (cert-manager startupapicheck)

```nix
startupapicheckJob = k8s.mkResource {
  apiVersion = "batch/v1";
  kind = "Job";
  name = "cert-manager-startupapicheck";
  labels = startupapicheckLabels;
  requires = lib.optional serviceAccount.create self.startupapicheckSa;
  spec = {
    backoffLimit = 4;
    template = {
      metadata.labels = startupapicheckLabels;
      spec = {
        serviceAccountName = startupapicheckSaName;
        restartPolicy = "OnFailure";
        containers = [ ... ];
      };
    };
  };
  extra = {
    metadata.annotations = {
      "helm.sh/hook" = "post-install";
      "helm.sh/hook-delete-policy" = "before-hook-creation,hook-succeeded";
    };
  };
};
```

## Container Helper Pattern (Valkey)

Factor out shared container boilerplate:

```nix
mkValkeyContainer = {
  startScript,
  env ? [],
  probes ? {},
  resources,
  portName ? "redis",
  lifecycle ? {},
  volumeMounts ? commonVolumeMounts,
}: {
  name = "valkey";
  image = imageRef;
  imagePullPolicy = image.pullPolicy;
  securityContext = containerSecurityContext;
  command = [ "/bin/bash" ];
  args = [ "-c" "/opt/bitnami/scripts/start-scripts/${startScript}" ];
  env = valkeyServerEnv ++ env;
  ports = [{ name = portName; containerPort = 6379; }];
  inherit resources volumeMounts;
} // probes // lifecycle;

primaryContainer = mkValkeyContainer {
  startScript = "start-primary.sh";
  env = [{ name = "VALKEY_REPLICATION_MODE"; value = "primary"; }];
  probes = { livenessProbe = ...; readinessProbe = ...; };
  resources = primary.resources;
};
```

## Pod Spec Helper (Valkey)

```nix
mkPodSpec = { serviceAccountName, componentLabels, containers, volumes, annotations ? {} }: {
  automountServiceAccountToken = false;
  securityContext = podSecurityContext;
  affinity = mkAntiAffinity componentLabels;
  enableServiceLinks = true;
  terminationGracePeriodSeconds = 30;
  inherit serviceAccountName containers volumes;
};
```

## Prometheus Annotations Pattern

```nix
prometheusAnnotations = lib.optionalAttrs prometheus.enabled {
  "prometheus.io/scrape" = "true";
  "prometheus.io/port" = "9402";
};
```

## FQDN Helper (Valkey)

```nix
fqdn = name: "${name}.${namespace}.svc.${clusterDomain}";
headlessSvcFqdn = fqdn headlessSvcName;
primaryHostFqdn = "${fullname}-primary-0.${headlessSvcFqdn}";
```

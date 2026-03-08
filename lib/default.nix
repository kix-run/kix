# kixlib — shared Kubernetes resource builders for kixpkgs
#
# Design decisions captured here (2026-03):
#
# 1. HUMAN-READABLE NAMES (not store paths)
#    The original kix repo experimented with using Nix store paths as Kubernetes
#    resource names (e.g., /nix/store/abc123-ServiceAccount.json as the actual
#    serviceAccountName). This was content-addressable and traceable but:
#    - Store paths contain '/' which is illegal in K8s resource names
#    - Names change on any Nix expression change, orphaning old resources
#    - kubectl debugging becomes impossible
#    We now use `resourceName` to derive human-readable names from metadata.
#    Store path hashes can still appear in annotations for traceability.
#
# 2. RESOURCES AS ATTRSETS (not derivations)
#    All mk* builders return plain attrsets, not store derivations. Only
#    `mkManifest` serializes to a store path. This means you can always pipe
#    a resource through further transformations. The old `rbac.bind` returned
#    a derivation directly which blocked composition — replaced by
#    `rbac.mkClusterRoleBinding` which returns an attrset.
#
# 3. ONE MANIFEST PER RESOURCE
#    Each resource should be a separate entry in config.manifests, not bundled
#    into a single derivation with dependency annotations. This makes verification
#    straightforward (compare per-kind) and lets operators inspect/apply selectively.
#
# 4. CONTAINER PASSTHROUGH
#    mkContainer passes through ALL arguments rather than destructuring a fixed
#    list. The old version silently dropped unknown fields (lifecycle, startupProbe,
#    envFrom, etc.) which would cause subtle bugs on real charts.
#
# 5. SELECTOR vs LABELS SEPARATION
#    mkDeployment accepts an explicit `selectorLabels` argument. Selectors must be
#    stable across upgrades (no version labels). If you put app.kubernetes.io/version
#    in the selector, rolling updates break because the new ReplicaSet has a different
#    selector than the old one. The old code copied ALL template labels into selectors.
#
# 6. removeNulls STRIPS EMPTY COLLECTIONS (known issue)
#    See inline comment. Kubernetes distinguishes absent vs empty in some cases.
#    The original kix repo had 5 different removeNulls implementations trying to
#    solve this — we've settled on one for now with a documented workaround.
#
# MISSING RESOURCE TYPES (add as needed during chart migrations):
#   workload: DaemonSet, Job, CronJob
#   networking: Ingress
#   rbac: Role, RoleBinding (namespace-scoped)
#   config: Secret
#   autoscaling: HorizontalPodAutoscaler
#   monitoring: PrometheusRule

{
  pkgs,
  lib,
  ...
}:

lib.makeExtensible (self: {

  # --- Shared helpers ---
  # Utility functions used across chart modules. These avoid repeating common
  # patterns like image string formatting, FQDN construction, and label hierarchy
  # assembly that every chart needs.

  # Converts an image attrset { repository, tag } to a Docker image reference string.
  # Used in mkContainer calls: `image = kixlib.imageRef cfg.image;`
  imageRef = img: "${img.repository}:${img.tag}";

  # Builds a fully-qualified K8s service DNS name.
  # Used by registry endpoints and anywhere a chart needs to reference another
  # service by its cluster-internal DNS name.
  mkFqdn = { name, namespace, clusterDomain ? "cluster.local" }:
    "${name}.${namespace}.svc.${clusterDomain}";

  # Builds the standard label hierarchy every chart needs.
  #
  # Returns an attrset with three members:
  #   - `selector` — stable labels for spec.selector.matchLabels (NEVER include version)
  #   - `all` — full metadata labels (cluster labels + selector + managed-by + extras)
  #   - `withComponent` — function that returns selector labels scoped to a component
  #
  # The `withComponent` function is particularly useful for charts like valkey that
  # have multiple components (primary, replica, sentinel) each needing their own
  # selector labels for separate StatefulSets/Services.
  #
  # Example:
  #   labels = kixlib.mkLabels { chart = "valkey"; clusterLabels = config.cluster.labels; };
  #   labels.selector              # => { app.kubernetes.io/instance = ...; app.kubernetes.io/name = "valkey"; }
  #   labels.withComponent "node"  # => selector // { app.kubernetes.io/component = "node"; }
  mkLabels = {
    chart,
    clusterLabels ? {},
    instance ? "release-name",
    component ? null,
    extra ? {},
  }:
  let
    selector = {
      "app.kubernetes.io/instance" = instance;
      "app.kubernetes.io/name" = chart;
    } // lib.optionalAttrs (component != null) {
      "app.kubernetes.io/component" = component;
    };
    all = clusterLabels // selector // {
      "app.kubernetes.io/managed-by" = "kix";
    } // extra;
  in {
    inherit selector all;
    withComponent = c: selector // { "app.kubernetes.io/component" = c; };
  };

  # Shared option type constructors for chart modules.
  # Imported from lib/options.nix — see that file for usage examples.
  # Accessible as kixlib.options.imageSubmodule, kixlib.options.resourcesSubmodule, etc.
  options = import ./options.nix { inherit lib; };

  # Default metadata merged into every resource via mkResource.
  # Set via `withMetadata` to apply namespace, labels, annotations globally.
  _defaultMetadata = { };

  withMetadata =
    metadata:
    self.extend (
      self: super: {
        _defaultMetadata = lib.recursiveUpdate super._defaultMetadata metadata;
      }
    );

  # Preprocessors run on every resource during mkManifest, after null stripping.
  # Useful for injecting cluster-wide policies (e.g., adding a label to everything).
  _preprocessors = [ ];

  withPreprocessor =
    preprocessor:
    self.extend (
      self: super: {
        _preprocessors = super._preprocessors ++ [ preprocessor ];
      }
    );

  withPreprocessors = preprocessors: lib.foldl' (l: p: l.withPreprocessor p) self preprocessors;

  addPreprocessor = name: fn: self.withPreprocessor (lib.setFunctionArgs fn { __name = name; });

  listPreprocessors = map (fn: fn.__name or "<anonymous>") self._preprocessors;

  # Strips null values recursively from an attrset before JSON serialization.
  #
  # KNOWN ISSUE: also strips empty lists [] and empty attrsets {}. Kubernetes
  # distinguishes between absent and explicitly-empty in some cases (e.g.,
  # `tolerations: []` vs no `tolerations` field). The original kix repo had
  # 5 different implementations of this function trying to solve the problem.
  #
  # TODO: introduce a marker value like `kixlib.explicit []` that survives
  # removeNulls, so users can preserve intentional empties. For now, if you
  # need an explicit empty list, set it via a preprocessor or raw merge on
  # the resource after construction.
  removeNulls =
    attrs:
    builtins.mapAttrs
      (
        _: v:
        let
          cleanValue =
            if builtins.isAttrs v && !(lib.isDerivation v) && !(v ? type) then
              self.removeNulls v
            else if builtins.isList v then
              builtins.map (x: if builtins.isAttrs x && !(lib.isDerivation x) then self.removeNulls x else x) v
            else
              v;
        in
        cleanValue
      )
      (
        lib.filterAttrs (
          _: v:
          v != null
          && !(
            (builtins.isAttrs v && !(lib.isDerivation v) && !(v ? type) && v == { })
            || (builtins.isList v && v == [ ])
          )
        ) attrs
      );

  # Derive a human-readable Kubernetes resource name from a resource attrset.
  #
  # Priority: explicit metadata.name > app label from default metadata > "unnamed"
  #
  # This replaces the old pattern where mkManifest store paths were used as
  # resource names. Store paths are illegal in K8s names (contain '/') and
  # change on any expression change, orphaning old resources in the cluster.
  resourceName =
    resource:
    let
      meta = resource.metadata or { };
      appName =
        self._defaultMetadata.name
          or self._defaultMetadata.labels."app.kubernetes.io/name"
          or "unnamed";
    in
    meta.name or appName;

  # Serialize a resource attrset to a JSON file in the Nix store.
  # This is the only function that produces a derivation — all other builders
  # return plain attrsets so they can be composed further.
  #
  # The pipeline: set name → strip nulls → run preprocessors → strip nulls again → toJSON
  # (second removeNulls catches any nulls introduced by preprocessors)
  mkManifest =
    resource:
    let
      name = self.resourceName resource;
      namedResource = lib.recursiveUpdate resource {
        metadata = (resource.metadata or { }) // {
          name = name;
        };
      };
    in
    pkgs.writeText "${name}-${lib.toLower resource.kind}.json" (
      namedResource
      |> self.removeNulls
      |> (x: lib.foldl' (res: f: f res) x self._preprocessors)
      |> self.removeNulls
      |> builtins.toJSON
    );

  # Base builder for any Kubernetes resource. Merges in default metadata
  # (namespace, labels, annotations) set via withMetadata.
  mkResource =
    {
      kind,
      apiVersion ? "v1",
      metadata ? { },
      ...
    }@args:
    args
    // {
      inherit apiVersion kind;
      metadata = lib.recursiveUpdate self._defaultMetadata metadata;
    };

  # Track inter-resource dependencies via annotations.
  # The dependency value is a store path pointing to the depended-on resource's
  # JSON derivation. This enables the Nix store's reference graph to capture
  # the full deployment dependency tree (e.g., `nix-store --query --requisites`).
  addDependency =
    drv: resource:
    let
      currentAnnotations = resource.metadata.annotations or { };
      currentDeps = currentAnnotations."build.kix.dev/dependencies" or "";
      newDeps = if currentDeps == "" then toString drv else "${currentDeps},${toString drv}";
      newAnnotations = currentAnnotations // {
        "build.kix.dev/dependencies" = newDeps;
      };
    in
    lib.recursiveUpdate resource {
      metadata = (resource.metadata or { }) // {
        annotations = newAnnotations;
      };
    };

  rbac = {
    mkClusterRole =
      {
        rules,
        ...
      }@r:
      self.mkResource (
        lib.recursiveUpdate r {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRole";
          rules = rules;
          # ClusterRoles are cluster-scoped, so namespace is null (stripped by removeNulls)
          metadata = {
            namespace = null;
          };
        }
      );

    # Creates a ClusterRoleBinding resource linking a ClusterRole to a ServiceAccount.
    #
    # Returns a resource attrset (NOT a derivation). This is a deliberate change
    # from the original kix `rbac.bind` which called mkManifest internally and
    # returned a store path. That blocked composition — you couldn't add annotations
    # or modify the binding after creation. Now you pipe through transformations
    # and call mkManifest yourself when ready.
    #
    # References the ClusterRole and ServiceAccount by human-readable name
    # (via resourceName), not by store path.
    mkClusterRoleBinding =
      clusterRole: serviceAccount:
      self.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        metadata = {
          namespace = null;
        };
        roleRef = {
          apiGroup = lib.elemAt (lib.strings.split "/" clusterRole.apiVersion) 0;
          kind = clusterRole.kind;
          name = self.resourceName clusterRole;
        };
        subjects = [
          {
            kind = serviceAccount.kind;
            name = self.resourceName serviceAccount;
            namespace = serviceAccount.metadata.namespace or "default";
          }
        ];
      };

    # Like mkClusterRoleBinding but takes a single attrset, allowing explicit
    # subjects override. Avoids the `recursiveUpdate` workaround needed when
    # the auto-generated subject doesn't match (e.g., coredns binds to "default"
    # SA when serviceAccount.create is false).
    #
    # Example:
    #   kixlib.rbac.mkClusterRoleBindingWith {
    #     clusterRole = myRole;
    #     serviceAccount = mySa;
    #     subjects = [{ kind = "ServiceAccount"; name = "default"; namespace = "kube-system"; }];
    #   }
    mkClusterRoleBindingWith =
      { clusterRole, serviceAccount, subjects ? null }:
      let
        autoSubjects = [
          {
            kind = serviceAccount.kind;
            name = self.resourceName serviceAccount;
            namespace = serviceAccount.metadata.namespace or "default";
          }
        ];
      in
      self.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        metadata = {
          namespace = null;
        };
        roleRef = {
          apiGroup = lib.elemAt (lib.strings.split "/" clusterRole.apiVersion) 0;
          kind = clusterRole.kind;
          name = self.resourceName clusterRole;
        };
        subjects = if subjects != null then subjects else autoSubjects;
      };

    # DEPRECATED: use mkClusterRoleBinding for composability.
    # This convenience function creates and immediately serializes a binding.
    # Kept for backward compatibility with existing kix modules.
    bind =
      clusterRole: serviceAccount:
      self.mkManifest (self.rbac.mkClusterRoleBinding clusterRole serviceAccount);

    mkServiceAccount =
      {
        metadata ? { },
        imagePullSecrets ? null,
        automountServiceAccountToken ? null,
        ...
      }:
      self.mkResource {
        kind = "ServiceAccount";
        metadata = metadata;
        inherit imagePullSecrets automountServiceAccountToken;
      };
  };

  pod = {
    # Wraps containers + volumes into a pod template spec.
    # Currently a passthrough — returns its arguments unchanged.
    # TODO: in the future this could merge default pod-level metadata,
    # validate the spec structure, or inject common settings like
    # terminationGracePeriodSeconds, securityContext, etc.
    mkPodTemplate =
      args@{
        metadata ? { },
        spec,
        ...
      }:
      args;

    # Creates a container spec.
    #
    # IMPORTANT: this is a passthrough — it returns ALL arguments as-is.
    # The old version destructured specific fields (name, image, env, ports, etc.)
    # and re-assembled them, which silently dropped any field not in the explicit
    # list. This meant lifecycle hooks, startupProbes, envFrom, workingDir, and
    # other valid container fields were silently lost. Now everything passes through.
    mkContainer =
      {
        name,
        image,
        ...
      }@args:
      args;

    withVolumeMount =
      {
        name,
        mountPath,
        subPath ? null,
        readOnly ? null,
      }:
      container:
      lib.recursiveUpdate container {
        volumeMounts = (container.volumeMounts or [ ]) ++ [
          {
            name = name;
            mountPath = mountPath;
            subPath = subPath;
            readOnly = readOnly;
          }
        ];
      };

    withLivenessProbe =
      probeConfig: container:
      lib.recursiveUpdate container {
        livenessProbe = probeConfig;
      };

    withReadinessProbe =
      probeConfig: container:
      lib.recursiveUpdate container {
        readinessProbe = probeConfig;
      };
  };

  networking = {
    mkService =
      {
        metadata ? { },
        spec,
        ...
      }:
      self.mkResource {
        kind = "Service";
        metadata = metadata;
        spec = spec;
      };

    # Creates a NetworkPolicy resource.
    #
    # Controls ingress/egress traffic to/from pods matching `podSelector`.
    # By default applies both Ingress and Egress policy types — pods that
    # don't match any rule are denied.
    #
    # Added for valkey chart migration (2026-03). Valkey uses NetworkPolicy
    # to restrict access to redis/sentinel ports and allow prometheus scraping.
    mkNetworkPolicy =
      {
        podSelector,
        policyTypes ? [ "Ingress" "Egress" ],
        ingress ? null,
        egress ? null,
        metadata ? { },
        ...
      }:
      self.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "NetworkPolicy";
        metadata = metadata;
        spec = {
          inherit podSelector policyTypes ingress egress;
        };
      };
  };

  workload = {
    # Creates a Deployment resource.
    #
    # `selectorLabels` — controls spec.selector.matchLabels. These MUST be stable
    # across upgrades. If you include version-varying labels (e.g.,
    # app.kubernetes.io/version), rolling updates break because the new ReplicaSet
    # gets a different selector than the old one, and K8s treats it as a new
    # Deployment rather than an update.
    #
    # The old kix code did `selector.matchLabels = template.metadata.labels` which
    # copied ALL labels into selectors. This happened to work for CoreDNS because
    # its template labels were carefully chosen, but would break on any chart that
    # includes version or hash labels on pods.
    #
    # If selectorLabels is not provided, falls back to template.metadata.labels
    # for backward compatibility, but this should be considered a bug in the caller.
    mkDeployment =
      {
        replicas ? 1,
        strategy ? null,
        metadata ? { },
        template,
        selectorLabels ? null,
        ...
      }:
      self.mkResource {
        inherit metadata;
        apiVersion = "apps/v1";
        kind = "Deployment";
        spec = {
          inherit replicas strategy template;
          selector.matchLabels =
            if selectorLabels != null then selectorLabels
            else template.metadata.labels;
        };
      };

    # Creates a StatefulSet resource.
    #
    # Like mkDeployment but for stateful workloads. Requires `serviceName` (the
    # headless Service for pod DNS) and supports `volumeClaimTemplates` for
    # per-pod PVCs. Same selectorLabels semantics as mkDeployment — must be
    # stable across upgrades.
    #
    # Added for valkey chart migration (2026-03). The Bitnami valkey chart uses
    # StatefulSets for both sentinel and non-sentinel modes.
    mkStatefulSet =
      {
        replicas ? 1,
        serviceName,
        selectorLabels ? null,
        template,
        volumeClaimTemplates ? null,
        updateStrategy ? null,
        podManagementPolicy ? null,
        metadata ? { },
        ...
      }:
      self.mkResource {
        inherit metadata;
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        spec = {
          inherit replicas serviceName template;
          updateStrategy = updateStrategy;
          podManagementPolicy = podManagementPolicy;
          volumeClaimTemplates = volumeClaimTemplates;
          selector.matchLabels =
            if selectorLabels != null then selectorLabels
            else template.metadata.labels;
        };
      };

    # Sets serviceAccountName on a workload's pod template.
    # Works for both Deployments and StatefulSets (same spec.template.spec path).
    # Uses the human-readable resourceName, not a store path.
    withServiceAccount =
      serviceAccount: deployment:
      lib.recursiveUpdate deployment {
        spec = (deployment.spec or { }) // {
          template = (deployment.spec.template or { }) // {
            spec = (deployment.spec.template.spec or { }) // {
              serviceAccountName = self.resourceName serviceAccount;
            };
          };
        };
      };

    # Creates a Service that selects this Deployment's pods using the
    # Deployment's selector labels (NOT all pod labels — see selectorLabels above).
    #
    # IMPORTANT: you MUST include spec.ports in serviceArgs. Ports are NOT
    # auto-derived from the Deployment's container ports. Example:
    #   deployment |> kixlib.workload.intoService {
    #     spec.type = "ClusterIP";
    #     spec.ports = [ { port = 53; targetPort = 53; protocol = "UDP"; name = "udp-53"; } ];
    #   }
    intoService =
      serviceArgs: deployment:
      self.networking.mkService (
        lib.recursiveUpdate serviceArgs { spec.selector = deployment.spec.selector.matchLabels; }
      )
      |> self.addDependency (self.mkManifest deployment);
  };

  # HorizontalPodAutoscaler for autoscaling workloads based on metrics.
  #
  # Added for CoreDNS chart migration (2026-03). Uses autoscaling/v2 API.
  autoscaling = {
    mkHorizontalPodAutoscaler =
      {
        scaleTargetRef,
        minReplicas ? 1,
        maxReplicas,
        metrics ? [],
        metadata ? {},
        ...
      }:
      self.mkResource {
        apiVersion = "autoscaling/v2";
        kind = "HorizontalPodAutoscaler";
        inherit metadata;
        spec = {
          inherit scaleTargetRef minReplicas maxReplicas metrics;
        };
      };
  };

  # Pod disruption budgets control how many pods can be unavailable during
  # voluntary disruptions (node drains, rolling updates, etc.).
  #
  # Added for valkey chart migration (2026-03).
  policy = {
    mkPodDisruptionBudget =
      {
        selector,
        maxUnavailable ? null,
        minAvailable ? null,
        metadata ? { },
        ...
      }:
      self.mkResource {
        apiVersion = "policy/v1";
        kind = "PodDisruptionBudget";
        metadata = metadata;
        spec = {
          inherit selector maxUnavailable minAvailable;
        };
      };
  };

  # Prometheus Operator custom resources for monitoring.
  #
  # Added for valkey chart migration (2026-03).
  monitoring = {
    mkServiceMonitor =
      {
        endpoints,
        selector,
        namespaceSelector ? null,
        metadata ? { },
        ...
      }:
      self.mkResource {
        apiVersion = "monitoring.coreos.com/v1";
        kind = "ServiceMonitor";
        metadata = metadata;
        spec = {
          inherit endpoints selector namespaceSelector;
        };
      };

    # PodMonitor — like ServiceMonitor but targets pods directly (no Service needed).
    # Uses podMetricsEndpoints instead of endpoints.
    #
    # Added for Valkey chart migration (2026-03). Valkey's Helm chart offers
    # both ServiceMonitor and PodMonitor as monitoring options.
    mkPodMonitor =
      {
        podMetricsEndpoints,
        selector,
        namespaceSelector ? null,
        metadata ? {},
        ...
      }:
      self.mkResource {
        apiVersion = "monitoring.coreos.com/v1";
        kind = "PodMonitor";
        inherit metadata;
        spec = {
          inherit podMetricsEndpoints selector namespaceSelector;
        };
      };

    # PrometheusRule — defines alerting/recording rules for Prometheus.
    #
    # Added for Valkey chart migration (2026-03).
    mkPrometheusRule =
      {
        groups,
        metadata ? {},
        ...
      }:
      self.mkResource {
        apiVersion = "monitoring.coreos.com/v1";
        kind = "PrometheusRule";
        inherit metadata;
        spec = {
          inherit groups;
        };
      };
  };

  configMap = {
    mkConfigMap =
      {
        data ? { },
        immutable ? null,
        metadata ? { },
        ...
      }@args:
      self.mkResource (args // {
        kind = "ConfigMap";
        inherit data immutable metadata;
      });

    withEntry =
      key: value: configMap:
      lib.recursiveUpdate configMap {
        data = (configMap.data or { }) // {
          "${key}" = value;
        };
      };

    # Fixed: the original used `with pair; withEntry key value cm` which relied
    # on `withEntry` being in scope via closure. Replaced with explicit
    # `self.configMap.withEntry` to avoid potential scoping bugs.
    withEntries =
      entries: configMap:
      lib.foldl' (cm: pair: self.configMap.withEntry pair.key pair.value cm) configMap entries;

    # Turn a ConfigMap resource into a volume spec for use in pod templates.
    # `name` is the volume name (used in volumeMounts). Defaults to the
    # ConfigMap's resourceName, but can be overridden for Helm parity
    # (e.g., Helm's CoreDNS chart hardcodes "config-volume").
    asVolume =
      {
        items ? null,
        name ? null,
      }:
      configMap:
      let volumeName = if name != null then name else self.resourceName configMap;
      in {
        name = volumeName;
        configMap = {
          name = self.resourceName configMap;
          items = items;
        };
      };
  };
})

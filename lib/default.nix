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
#   workload: StatefulSet, DaemonSet, Job, CronJob
#   networking: Ingress, NetworkPolicy
#   rbac: Role, RoleBinding (namespace-scoped)
#   config: Secret
#   storage: PersistentVolumeClaim
#   policy: PodDisruptionBudget
#   autoscaling: HorizontalPodAutoscaler
#   monitoring: ServiceMonitor, PrometheusRule

{
  pkgs,
  lib,
  ...
}:

lib.makeExtensible (self: {
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
        ...
      }:
      self.mkResource {
        kind = "ServiceAccount";
        metadata = metadata;
        imagePullSecrets = imagePullSecrets;
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

    # Sets serviceAccountName on a Deployment's pod template.
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

  configMap = {
    mkConfigMap =
      {
        data ? { },
        immutable ? null,
        ...
      }:
      self.mkResource {
        kind = "ConfigMap";
        data = data;
        immutable = immutable;
      };

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

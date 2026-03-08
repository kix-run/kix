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
#    Store path hashes could still appear in annotations for traceability.
#
# 2. RESOURCES AS ATTRSETS (not derivations)
#    All mk* builders return plain attrsets, not store derivations.
#    config.manifests also stores raw attrsets — serialization (removeNulls →
#    toJSON → writeText via mkManifest) is deferred to mkManifests in
#    flake.nix, the output boundary. This keeps structured data available
#    throughout the module system for cross-resource validation, behavioral
#    invariants, and any module that needs to inspect other charts' resources.
#    The old `rbac.bind` returned a derivation directly which blocked
#    composition — all mk* builders now return attrsets.
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
# 6. RBAC BATCH GENERATION
#    `rbac.mkRoleSet` creates multiple roles and their bindings in one call,
#    eliminating the repeated subjects/binding boilerplate. Returns
#    { roles, bindings, toManifestList } — the last is a convenience function
#    for generating manifestList entries. Subject helpers (`rbac.subjects.sa`,
#    `rbac.subjects.group`) further reduce boilerplate.
#
# 7. removeNulls STRIPS EMPTY COLLECTIONS (known issue)
#    See inline comment. Kubernetes distinguishes absent vs empty in some cases.
#    The original kix repo had 5 different removeNulls implementations trying to
#    solve this — we've settled on one for now with a documented workaround.
#
# All common resource types are now covered. Add more as needed during
# chart migrations (e.g., PersistentVolumeClaim, StorageClass).

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

  # Marker that preserves a value through removeNulls.
  #
  # Use `kixlib.explicit []` or `kixlib.explicit {}` when you need Kubernetes
  # to see an explicit empty value rather than an absent field. For example,
  # `tolerations: []` means "tolerate nothing" while absent `tolerations` means
  # "use defaults."
  #
  # Example: `spec.tolerations = kixlib.explicit [];`
  # This produces `"tolerations": []` in the JSON output.
  explicit = value: { __kixExplicit = true; __value = value; };

  # Strips null values recursively from an attrset before JSON serialization.
  #
  # Also strips empty lists [] and empty attrsets {} UNLESS wrapped in
  # `kixlib.explicit`. Kubernetes distinguishes absent vs empty in some cases
  # (e.g., `tolerations: []` vs no `tolerations` field).
  removeNulls =
    attrs:
    builtins.mapAttrs
      (
        _: v:
        let
          cleanValue =
            # Unwrap explicit markers — these survive removeNulls.
            if builtins.isAttrs v && v ? __kixExplicit then
              v.__value
            else if builtins.isAttrs v && !(lib.isDerivation v) && !(v ? type) then
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
          # Explicit markers always pass through — they represent intentional empties.
          && (
            (builtins.isAttrs v && v ? __kixExplicit)
            || !(
              (builtins.isAttrs v && !(lib.isDerivation v) && !(v ? type) && v == { })
              || (builtins.isList v && v == [ ])
            )
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
  # The pipeline: validate → set name → strip nulls → run preprocessors → strip nulls again → toJSON
  # (second removeNulls catches any nulls introduced by preprocessors)
  #
  # Phase 6 validation: every resource MUST have kind, apiVersion, and a resolvable name.
  # These catch structural bugs at build time rather than at deploy time.
  mkManifest =
    resource:
    assert resource ? kind
      || throw "mkManifest: resource missing 'kind' — did you forget to use a mk* builder?";
    assert resource ? apiVersion
      || throw "mkManifest: resource missing 'apiVersion'";
    let
      name = self.resourceName resource;
    in
    assert name != "unnamed"
      || throw "mkManifest: resource of kind ${resource.kind} has no name — set metadata.name or use withMetadata";
    let
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
      { clusterRole, serviceAccount, subjects ? null, metadata ? {} }:
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
        metadata = metadata // {
          namespace = null;
        };
        roleRef = {
          apiGroup = lib.elemAt (lib.strings.split "/" clusterRole.apiVersion) 0;
          kind = clusterRole.kind;
          name = self.resourceName clusterRole;
        };
        subjects = if subjects != null then subjects else autoSubjects;
      };

    # Creates a namespace-scoped Role.
    #
    # Unlike ClusterRole, Roles keep the namespace from withMetadata (or explicit
    # metadata.namespace). Same structure otherwise — rules list, passthrough.
    #
    # Added for cert-manager migration (2026-03). Cert-manager uses Roles for
    # leader election (kube-system), webhook dynamic-serving, and startup check.
    mkRole =
      {
        rules,
        ...
      }@r:
      self.mkResource (
        lib.recursiveUpdate r {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          rules = rules;
        }
      );

    # Creates a namespace-scoped RoleBinding linking a Role (or ClusterRole) to a ServiceAccount.
    #
    # Accepts either a Role or ClusterRole as the first argument — reads `role.kind`
    # dynamically to set the roleRef correctly. This handles the common pattern where
    # a RoleBinding references a ClusterRole to grant namespace-scoped permissions
    # from a cluster-wide role.
    #
    # Added for cert-manager migration (2026-03).
    mkRoleBinding =
      role: serviceAccount:
      self.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        roleRef = {
          apiGroup = lib.elemAt (lib.strings.split "/" role.apiVersion) 0;
          kind = role.kind;
          name = self.resourceName role;
        };
        subjects = [
          {
            kind = serviceAccount.kind;
            name = self.resourceName serviceAccount;
            namespace = serviceAccount.metadata.namespace or "default";
          }
        ];
      };

    # Like mkRoleBinding but takes a single attrset, allowing explicit subjects
    # override and metadata override (e.g., to put the binding in a different
    # namespace than the default).
    #
    # Added for cert-manager migration (2026-03).
    mkRoleBindingWith =
      { role, serviceAccount, subjects ? null, metadata ? {} }:
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
        kind = "RoleBinding";
        inherit metadata;
        roleRef = {
          apiGroup = lib.elemAt (lib.strings.split "/" role.apiVersion) 0;
          kind = role.kind;
          name = self.resourceName role;
        };
        subjects = if subjects != null then subjects else autoSubjects;
      };

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

    # --- Subject helpers ---
    # Convenience constructors for the `subjects` field in role bindings.
    # Eliminates the repeated `[{ kind = "ServiceAccount"; name = ...; namespace = ...; }]`
    # pattern that appears ~15 times in cert-manager alone.
    subjects = {
      sa = { name, namespace ? "default" }: [{
        kind = "ServiceAccount";
        inherit name namespace;
      }];
      group = name: [{
        kind = "Group";
        inherit name;
        apiGroup = "rbac.authorization.k8s.io";
      }];
    };

    # --- Batch role + binding generation ---
    # Creates multiple roles and their bindings in one call. Dramatically reduces
    # RBAC boilerplate for charts like cert-manager that have 8+ ClusterRoles all
    # bound to the same ServiceAccount.
    #
    # Returns { roles, bindings, toManifestList }:
    #   - roles: attrset of name → role resource
    #   - bindings: attrset of name → binding resource
    #   - toManifestList: function (enable) → list of manifestList entries
    #
    # Example:
    #   controllerRbac = kixlib'.rbac.mkRoleSet {
    #     subjects = kixlib.rbac.subjects.sa { name = "cert-manager"; namespace = cfg.namespace; };
    #     roles = {
    #       "cert-manager-controller-issuers" = { rules = [ ... ]; };
    #       "cert-manager-controller-certificates" = { rules = [ ... ]; };
    #     };
    #   };
    #   # In manifestList: controllerRbac.toManifestList cfg.rbac.create
    mkRoleSet =
      {
        roles,           # attrset: name → { rules, metadata?, ... }
        subjects,        # list of subject entries (use rbac.subjects.sa etc.)
        scope ? "cluster", # "cluster" for ClusterRole/Binding, "namespace" for Role/Binding
        metadata ? {},   # base metadata merged into all roles and bindings
      }:
      let
        mkRole = if scope == "cluster" then self.rbac.mkClusterRole else self.rbac.mkRole;
        mkBinding = if scope == "cluster"
          then (role: self.mkResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRoleBinding";
            metadata = (metadata // { namespace = null; }) // { name = self.resourceName role; };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = role.kind;
              name = self.resourceName role;
            };
            inherit subjects;
          })
          else (role: self.mkResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            metadata = metadata // { name = self.resourceName role; };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = role.kind;
              name = self.resourceName role;
            };
            inherit subjects;
          });

        builtRoles = lib.mapAttrs (name: args:
          mkRole ((args // { metadata = (metadata // (args.metadata or {})) // { name = name; }; }))
        ) roles;

        builtBindings = lib.mapAttrs (_: role: mkBinding role) builtRoles;
      in {
        roles = builtRoles;
        bindings = builtBindings;
        # Convenience: flatten roles + bindings into a manifestList fragment.
        # Uses the role name as prefix for both role and binding entries.
        toManifestList = enable:
          (lib.mapAttrsToList (n: role:
            { name = n; resource = role; inherit enable; }
          ) builtRoles)
          ++ (lib.mapAttrsToList (n: binding:
            { name = "${n}-binding"; resource = binding; inherit enable; }
          ) builtBindings);
      };
  };

  pod = {
    # Wraps containers + volumes into a pod template spec.
    # Currently a passthrough with validation — returns its arguments unchanged
    # after asserting the spec has at least one container.
    #
    # Phase 6 validation: spec.containers must be non-empty. A pod template
    # without containers is always a bug.
    mkPodTemplate =
      args@{
        metadata ? { },
        spec,
        ...
      }:
      assert (spec.containers or []) != []
        || throw "mkPodTemplate: spec.containers must be non-empty";
      args;

    # Creates a container spec.
    #
    # IMPORTANT: this is a passthrough — it returns ALL arguments as-is.
    # The old version destructured specific fields (name, image, env, ports, etc.)
    # and re-assembled them, which silently dropped any field not in the explicit
    # list. This meant lifecycle hooks, startupProbes, envFrom, workingDir, and
    # other valid container fields were silently lost. Now everything passes through.
    #
    # Phase 6 validation: name and image must be non-empty strings.
    mkContainer =
      {
        name,
        image,
        ...
      }@args:
      assert name != ""
        || throw "mkContainer: name must be non-empty";
      assert image != ""
        || throw "mkContainer: image must be non-empty";
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
    # Phase 6 validation: spec.ports must be non-empty.
    mkService =
      {
        metadata ? { },
        spec,
        ...
      }:
      assert (spec.ports or []) != []
        || throw "mkService: spec.ports must be non-empty";
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

    # Creates an Ingress resource.
    #
    # networking.k8s.io/v1 Ingress with rules, tls, and ingressClassName.
    # Phase 8: added as missing builder.
    mkIngress =
      {
        rules ? [],
        tls ? null,
        ingressClassName ? null,
        defaultBackend ? null,
        metadata ? {},
        ...
      }:
      assert rules != [] || defaultBackend != null
        || throw "mkIngress: must have at least one rule or a defaultBackend";
      self.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        inherit metadata;
        spec = {
          inherit rules tls ingressClassName defaultBackend;
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
    # Phase 6 validation: template.spec.containers must be non-empty.
    mkDeployment =
      {
        replicas ? 1,
        strategy ? null,
        metadata ? { },
        template,
        selectorLabels ? null,
        ...
      }:
      assert (template.spec.containers or []) != []
        || throw "mkDeployment: template.spec.containers must be non-empty";
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
    # Phase 6 validation: serviceName required, containers must be non-empty.
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
      assert serviceName != ""
        || throw "mkStatefulSet: serviceName is required (headless Service for pod DNS)";
      assert (template.spec.containers or []) != []
        || throw "mkStatefulSet: template.spec.containers must be non-empty";
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

    # Creates a Job resource.
    #
    # Uses batch/v1 API. Accepts template (pod template spec) and passthrough
    # for backoffLimit, completions, parallelism, etc.
    #
    # Added for cert-manager migration (2026-03). Cert-manager uses a Job for
    # startup API check — verifies the API server has the CRDs installed.
    # Phase 6 validation: template.spec.containers must be non-empty.
    mkJob =
      {
        template,
        backoffLimit ? null,
        completions ? null,
        parallelism ? null,
        metadata ? { },
        ...
      }:
      assert (template.spec.containers or []) != []
        || throw "mkJob: template.spec.containers must be non-empty";
      self.mkResource {
        apiVersion = "batch/v1";
        kind = "Job";
        inherit metadata;
        spec = {
          inherit template backoffLimit completions parallelism;
        };
      };

    # Creates a DaemonSet resource.
    #
    # Like Deployment but runs exactly one pod per node (or per matching node).
    # No replicas — scheduling is controlled by nodeSelector/tolerations.
    # Phase 8: added as missing builder.
    mkDaemonSet =
      {
        template,
        selectorLabels ? null,
        updateStrategy ? null,
        metadata ? { },
        ...
      }:
      assert (template.spec.containers or []) != []
        || throw "mkDaemonSet: template.spec.containers must be non-empty";
      self.mkResource {
        inherit metadata;
        apiVersion = "apps/v1";
        kind = "DaemonSet";
        spec = {
          inherit template updateStrategy;
          selector.matchLabels =
            if selectorLabels != null then selectorLabels
            else template.metadata.labels;
        };
      };

    # Creates a CronJob resource.
    #
    # Runs Jobs on a cron schedule. The `jobTemplate` contains the Job spec
    # (which itself contains a pod template).
    # Phase 8: added as missing builder.
    mkCronJob =
      {
        schedule,
        jobTemplate,
        concurrencyPolicy ? null,
        successfulJobsHistoryLimit ? null,
        failedJobsHistoryLimit ? null,
        suspend ? null,
        metadata ? { },
        ...
      }:
      self.mkResource {
        apiVersion = "batch/v1";
        kind = "CronJob";
        inherit metadata;
        spec = {
          inherit schedule jobTemplate concurrencyPolicy
            successfulJobsHistoryLimit failedJobsHistoryLimit suspend;
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
      );
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

  # Admission webhook configurations for validating/mutating K8s API requests.
  #
  # Added for cert-manager migration (2026-03). Cert-manager registers both
  # mutating and validating webhooks to intercept cert-manager CRD operations.
  #
  # These are cluster-scoped resources (namespace = null). The webhooks list is
  # passed through — each entry has its own rules, clientConfig, failurePolicy, etc.
  # caBundle is typically empty at deploy time and filled by cainjector at runtime.
  admission = {
    mkMutatingWebhookConfiguration =
      {
        webhooks,
        metadata ? { },
        ...
      }:
      self.mkResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "MutatingWebhookConfiguration";
        metadata = metadata // { namespace = null; };
        inherit webhooks;
      };

    mkValidatingWebhookConfiguration =
      {
        webhooks,
        metadata ? { },
        ...
      }:
      self.mkResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingWebhookConfiguration";
        metadata = metadata // { namespace = null; };
        inherit webhooks;
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

  # Secret builder — v1 Secret with data, stringData, and type.
  # Phase 8: added as missing builder.
  #
  # Use `stringData` for plaintext values (K8s base64-encodes them automatically).
  # Use `data` for pre-encoded values. `type` defaults to "Opaque".
  secret = {
    mkSecret =
      {
        data ? null,
        stringData ? null,
        type ? "Opaque",
        immutable ? null,
        metadata ? {},
        ...
      }:
      assert data != null || stringData != null
        || throw "mkSecret: must provide 'data' or 'stringData'";
      self.mkResource {
        kind = "Secret";
        inherit metadata data stringData type immutable;
      };
  };

  # --- mkChartModule: the contract for chart modules ---
  #
  # Every chart module follows the same pattern:
  #   1. Declare options under services.<name> (+ enable/namespace/clusterDomain)
  #   2. Create kixlib' with chart metadata
  #   3. Build resources, serialize via manifestList
  #   4. Wire registry, monitoring, networkPolicies into config
  #   5. Gate everything on cfg.enable
  #
  # mkChartModule formalizes this pattern as a contract. Charts provide:
  #   - chartOptions: function returning chart-specific option declarations
  #   - resources: function returning manifestList + extraConfig
  #
  # mkChartModule handles the mechanical parts:
  #   - Adding enable/namespace/clusterDomain options (no more `// opts.mkChartOptions`)
  #   - Creating kixlib' and labels
  #   - Wiring clusterDomain default from cluster.domain
  #   - Gating all config on cfg.enable
  #   - Serializing manifestList to config.manifests
  #   - Asserting manifest name uniqueness within the chart
  #
  # Multi-component handling: The resources function receives both kixlib (unadorned)
  # and kixlib' (chart-scoped). Multi-component charts create additional label sets
  # and kixlib instances inside the resources function. Individual manifestList entries
  # can carry their own `kixlib` attribute for component-scoped serialization.
  #
  # Usage:
  #   # pkgs/coredns/default.nix
  #   { lib, pkgs, config, kixlib, ... }:
  #   kixlib.mkChartModule {
  #     name = "coredns";
  #     inherit lib pkgs config kixlib;
  #     chartOptions = import ./options.nix;
  #     resources = import ./resources.nix;
  #   }
  mkChartModule =
    {
      name,
      lib,
      pkgs,
      config,
      kixlib,

      # Function: { lib, kixlib, opts } -> attrset of option declarations.
      # Returns chart-specific options only — enable/namespace/clusterDomain
      # are added automatically by mkChartModule.
      chartOptions,

      # Function: { lib, pkgs, config, kixlib, kixlib', cfg, labels } -> {
      #   manifestList: list of { name, resource, enable, kixlib? }
      #   extraConfig: attrset merged into module config (registry, monitoring, etc.)
      # }
      resources,
    }:
    let
      opts = kixlib.options;
      cfg = config.services.${name};

      # Standard label hierarchy — charts can extend via their resources function.
      chartLabels = kixlib.mkLabels {
        chart = name;
        clusterLabels = config.cluster.labels;
      };

      # Chart-scoped kixlib with default metadata (namespace, labels, name).
      chartKixlib = kixlib.withMetadata {
        namespace = cfg.namespace;
        labels = chartLabels.all;
        inherit name;
      };

      # Evaluate the resources function.
      result = resources {
        inherit lib pkgs config kixlib cfg;
        kixlib' = chartKixlib;
        labels = chartLabels;
      };

      # Assert no duplicate names in manifestList.
      # Duplicates would silently overwrite each other in listToAttrs.
      enabledManifests = builtins.filter (r: r.enable) result.manifestList;
      manifestNames = map (r: r.name) enabledManifests;
      uniqueNames = lib.unique manifestNames;
      hasDuplicates = builtins.length manifestNames != builtins.length uniqueNames;

      # Store raw attrsets in config.manifests — serialization is deferred
      # to the output boundary (mkManifests in flake.nix). This keeps
      # structured data available throughout the module system for
      # cross-resource validation, behavioral invariants, and any module
      # that needs to inspect other charts' resources.
      #
      # Previously, this called mkManifest here, serializing to JSON store
      # paths and losing the structured data before the module system was
      # done with it. Now mkResource (called by each builder) already
      # merges _defaultMetadata at construction time, so the attrsets
      # stored here have correct metadata.name, labels, and namespace.
      manifests =
        assert !hasDuplicates
          || throw "mkChartModule(${name}): duplicate manifest names: ${builtins.toJSON manifestNames}";
        lib.listToAttrs (
          map (r: lib.nameValuePair r.name r.resource)
          enabledManifests
        );
    in
    {
      options.services.${name} =
        (chartOptions { inherit lib kixlib opts; })
        // {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable ${name}.";
          };
          namespace = lib.mkOption {
            type = lib.types.str;
            default = "default";
            description = "Kubernetes namespace for ${name} resources.";
          };
          clusterDomain = lib.mkOption {
            type = lib.types.str;
            default = "cluster.local";
            description = "Kubernetes cluster domain for DNS resolution.";
          };
        };

      config = lib.mkIf cfg.enable (
        {
          # Consume cluster-wide domain — per-chart override still wins.
          services.${name}.clusterDomain = lib.mkDefault config.cluster.domain;
          inherit manifests;
        }
        // (result.extraConfig or {})
      );
    };
})

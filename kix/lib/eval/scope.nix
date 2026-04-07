# Scope — per-instance context injected into packages.
# Contains mkResource, mkClusterResource, workload builders, CRD support.

{
  lib,
  k8s,
  rbac,
  crd,
}:

let
  inherit (k8s) clusterScoped;

  # Capability check helpers. Called at resource construction time.
  # `throw` for hard failures (resource will definitely not work),
  # `builtins.trace` for warnings (resource works but may not behave as expected).
  checkCapability =
    {
      capabilities,
      cap,
      message,
    }:
    if capabilities == { } then
      # No capabilities provided (e.g. tests, standalone scope) — skip checks
      null
    else if !(capabilities.${cap} or true) then
      throw message
    else
      null;

  checkCapabilityNotNull =
    {
      capabilities,
      cap,
      message,
    }:
    if capabilities == { } then
      null
    else if (capabilities.${cap} or null) == null then
      throw message
    else
      null;
in

rec {
  # Per-instance context injected into packages.
  mkScope =
    {
      instanceName,
      namespaceName,
      namespaceResource,
      namespaces ? { },
      clusterLabels ? { },
      labelStyle ? "kix",
      selectorLabelsOverride ? null,
      clusterDomain ? "cluster.local",
      capabilities ? { },
    }:
    let
      selectorLabels =
        if selectorLabelsOverride != null then
          selectorLabelsOverride
        else if labelStyle == "helm" then
          {
            app = instanceName;
            release = instanceName;
          }
        else
          {
            "app.kubernetes.io/name" = instanceName;
            "app.kubernetes.io/instance" = instanceName;
          };

      instanceLabels =
        if labelStyle == "helm" then
          {
            release = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          }
        else
          {
            "app.kubernetes.io/instance" = instanceName;
            "app.kubernetes.io/managed-by" = "kix";
          };

      # --- Capability checks (evaluated lazily via builtins.seq) ---

      checkLoadBalancer =
        args:
        let
          specType = args.spec.type or (args.extra.spec.type or null);
        in
        if (args.kind or "") == "Service" && specType == "LoadBalancer" then
          checkCapability {
            inherit capabilities;
            cap = "loadBalancer";
            message =
              "[${instanceName}] Service '${args.name or "unknown"}' uses type=LoadBalancer "
              + "but cluster.capabilities.loadBalancer is false. "
              + "Use type=ClusterIP or NodePort, install a LoadBalancer controller, "
              + "or set cluster.capabilities.loadBalancer = true.";
          }
        else
          null;

      checkPrivileged =
        templateSpec:
        let
          containers = templateSpec.containers or [ ];
          initContainers = templateSpec.initContainers or [ ];
          allContainers = containers ++ initContainers;
          hasPrivileged = builtins.any (c: (c.securityContext.privileged or false) == true) allContainers;
          hasHostNetwork = templateSpec.hostNetwork or false;
          hasHostPID = templateSpec.hostPID or false;
          reason =
            if hasHostNetwork then
              "hostNetwork: true"
            else if hasHostPID then
              "hostPID: true"
            else
              "securityContext.privileged: true";
        in
        if hasPrivileged || hasHostNetwork || hasHostPID then
          checkCapability {
            inherit capabilities;
            cap = "privilegedContainers";
            message =
              "[${instanceName}] Workload uses ${reason} "
              + "but cluster.capabilities.privilegedContainers is false. "
              + "This cluster (e.g. GKE Autopilot, OpenShift) restricts privileged workloads.";
          }
        else
          null;

      scopeMkResource =
        {
          labels ? { },
          ...
        }@args:
        builtins.seq (checkLoadBalancer args) (
          k8s.mkResource (
            removeAttrs args [ "labels" ]
            // {
              namespace = namespaceResource;
              inherit clusterDomain;
              labels = clusterLabels // instanceLabels // labels;
            }
          )
          // {
            packageLabels = labels;
          }
        );

      # WARNING: StatefulSet.spec.serviceName must use .name (plain string),
      # NOT .out.name (context-carrying). Using .out.name creates a store DAG
      # edge to the Service. If the Service also has `requires` pointing back
      # to the StatefulSet, this causes infinite recursion during evaluation.
      # The serviceName field is a plain K8s name match, not a dependency.
      checkDaemonSet =
        kind:
        if kind == "DaemonSet" then
          checkCapability {
            inherit capabilities;
            cap = "daemonSets";
            message =
              "[${instanceName}] DaemonSet cannot be deployed — "
              + "cluster.capabilities.daemonSets is false. "
              + "This cluster (e.g. GKE Autopilot) does not support DaemonSets.";
          }
        else
          null;

      # Validate that all secret references in a pod spec are DI-tracked.
      # A reference is tracked if its string carries Nix string context (i.e.,
      # it came from secret.out.name, secret.out.envFrom, secret.out.keyRef,
      # or kix.untrackedRef). Plain string literals have no context and fail.
      checkSecretRefs =
        templateSpec:
        let
          allContainers = (templateSpec.containers or [ ]) ++ (templateSpec.initContainers or [ ]);

          validateName =
            fieldDesc: secretName:
            if builtins.getContext secretName == { } then
              throw "[${instanceName}] Untracked secret reference in ${fieldDesc}: "
              + "\"${builtins.unsafeDiscardStringContext secretName}\". "
              + "Use secret.out.name, secret.out.envFrom, secret.out.keyRef, "
              + "or kix.untrackedRef to opt out explicitly."
            else
              null;

          volumeChecks = builtins.concatMap (
            v: if v ? secret then [ (validateName "volumes[].secret.secretName" v.secret.secretName) ] else [ ]
          ) (templateSpec.volumes or [ ]);

          envFromChecks = builtins.concatMap (
            c:
            builtins.concatMap (
              ef:
              if ef ? secretRef then
                [
                  (validateName "envFrom[].secretRef.name in container '${c.name}'" ef.secretRef.name)
                ]
              else
                [ ]
            ) (c.envFrom or [ ])
          ) allContainers;

          keyRefChecks = builtins.concatMap (
            c:
            builtins.concatMap (
              e:
              if (e ? valueFrom) && (e.valueFrom ? secretKeyRef) then
                [
                  (validateName "env '${e.name}' secretKeyRef in container '${c.name}'" e.valueFrom.secretKeyRef.name)
                ]
              else
                [ ]
            ) (c.env or [ ])
          ) allContainers;

          allChecks = volumeChecks ++ envFromChecks ++ keyRefChecks;
        in
        builtins.foldl' (acc: check: builtins.seq check acc) null allChecks;

      mkWorkload =
        apiVersion: kind: attrs:
        let
          spec = attrs.spec or { };
          selector =
            spec.selector.matchLabels
              or (throw "mkWorkload (${kind}): spec.selector.matchLabels is required — use scope.selectorLabels");
          templateMeta = spec.template.metadata or { };
          templateSpec = spec.template.spec or { };
        in
        builtins.seq (checkDaemonSet kind) (
          builtins.seq (checkPrivileged templateSpec) (
            builtins.seq (checkSecretRefs templateSpec) (
              scopeMkResource (
                removeAttrs attrs [ "spec" ]
                // {
                  inherit apiVersion kind;
                  spec =
                    removeAttrs spec [
                      "selector"
                      "template"
                    ]
                    // {
                      selector.matchLabels = selector;
                      template = {
                        metadata = templateMeta // {
                          labels = templateMeta.labels or selector;
                        };
                        spec = templateSpec;
                      };
                    };
                }
              )
            )
          )
        );

      scopeMkClusterResource =
        {
          labels ? { },
          ...
        }@args:
        k8s.mkResource (
          removeAttrs args [ "labels" ]
          // {
            namespace = clusterScoped;
            inherit clusterDomain;
            labels = clusterLabels // instanceLabels // labels;
          }
        )
        // {
          packageLabels = labels;
        };

      # ── CRD support ──────────────────────────────────────────────────

      # Create a CRD resource from a K8s-native spec shape.
      # Returns a resource (usable in requires, etc.) with .out.{cr, mkCR}.
      #
      # Accepts the same structure as a real CRD manifest's spec, plus an
      # optional top-level `labels` for the CRD resource metadata.
      # Use crd.fromKind and other transforms to build the input.
      #
      # Example:
      #   crd.fromKind "SGCluster" { spec.group = "stackgres.io"; }
      #   |> crd.withShortNames [ "sgclu" ]
      #   |> scope.mkCRD
      mkCRD =
        attrs:
        let
          crdSpec = attrs.spec or (throw "mkCRD: spec is required");
          labels = attrs.labels or { };
          crKind = crdSpec.names.kind;
          group = crdSpec.group;
          plural = crdSpec.names.plural;
          version = (builtins.head crdSpec.versions).name;
          crdScope = crdSpec.scope or "Namespaced";

          crdResource = scopeMkClusterResource {
            apiVersion = "apiextensions.k8s.io/v1";
            kind = "CustomResourceDefinition";
            name = "${plural}.${group}";
            inherit labels;
            extra.spec = crdSpec;
          };

          builders = k8s.mkCRDBuilders {
            crdOrRef = crdResource;
            group = group;
            kind = crKind;
            inherit version crdScope;
          };
        in
        crdResource
        // {
          out = crdResource.out // builders;
        };

      # Create a CRD reference for externally-managed CRDs (installed by an
      # operator's INSTALL_CRDS bootstrap, helm, or pre-existing on the cluster).
      #
      # Emits a real k8s-resource — a PackageInstance import marker in the
      # caller's namespace with kix.dev/mode=import annotations describing the
      # expected CRD. The CLI deploy engine's readiness check for import
      # markers polls the cluster until the described CRD is Established,
      # which naturally gates the wave containing any CR built via `.out.mkCR`.
      #
      # Dependency wiring is per-CR: `mkCRDBuilders` auto-adds this marker to
      # every CR's `requires`, so the wave graph places the marker before
      # consuming CRs via the standard forward-closure walker. No `root.requires`
      # plumbing, no special case in wave ordering.
      #
      # Same .out.{cr, mkCR} interface as mkCRD.
      mkCRDRef =
        {
          group,
          kind,
          plural,
          version ? "v1",
          crdScope ? "Namespaced",
          installedBy ? null,
        }:
        let
          crdName = "${plural}.${group}";
          # Sanitize group dots for a k8s-valid name.
          groupSlug = builtins.replaceStrings [ "." ] [ "-" ] group;
          markerName = "crd-ref-${plural}-${groupSlug}";

          marker = scopeMkResource {
            apiVersion = "kix.dev/v1alpha1";
            kind = "PackageInstance";
            name = markerName;
            annotations = {
              "kix.dev/mode" = "import";
              "kix.dev/import-kind" = "CustomResourceDefinition";
              "kix.dev/import-apiversion" = "apiextensions.k8s.io/v1";
              "kix.dev/import-name" = crdName;
            };
            # The PackageInstance CRD must exist before the marker can be
            # applied. When `installedBy` is provided, also require that
            # resource directly — this orders the marker AFTER its installer
            # (e.g. operator Deployment) in the wave graph and classifies
            # the marker as an inverse dep of root (no orphan warning).
            requires = [ k8s.kixCRDs.packageInstance ] ++ lib.optional (installedBy != null) installedBy;
            extra.spec = {
              instanceName = markerName;
              namespaceName = namespaceName;
              mode = "import";
            };
          };

          builders = k8s.mkCRDBuilders {
            crdOrRef = marker;
            inherit
              group
              kind
              version
              crdScope
              ;
          };
        in
        marker
        // {
          out = marker.out // builders;
        };

      # Scope-side CRD builder: reads the CRD's scope and auto-routes.
      # Uses scopeObj (lazy self-reference) so crd.out.mkCR gets the full scope.
      mkCR = crd: args: crd.out.mkCR scopeObj args;

      # ── Secret support ──────────────────────────────────────────────

      # Create a kix-managed Secret resource with enriched out API.
      # Accepts inline stringData (for dev/config-derived secrets) or
      # source + hash (for SOPS-encrypted secrets, kix-deploy hydrates).
      #
      # The out API provides: keyRef, mkEnv, envFrom, volume — all with
      # build-time key validation and automatic dependency tracking.
      #
      # Usage:
      #   creds = scope.mkSecret {
      #     name = "db-credentials";
      #     keys = [ "username" "password" ];
      #     stringData = { username = "admin"; password = "s3cret"; };
      #   };
      #   env = creds.out.mkEnv { DB_USER = "username"; DB_PASS = "password"; };
      mkSecret =
        {
          name,
          keys ? null,
          type ? "Opaque",
          stringData ? { },
          source ? null,
          hash ? null,
          meta ? { },
          labels ? { },
          annotations ? { },
          requires ? [ ],
          extra ? { },
        }:
        let
          effectiveKeys =
            if keys != null then
              keys
            else if stringData != { } then
              builtins.attrNames stringData
            else
              throw "mkSecret \"${name}\": either 'keys' or 'stringData' must be provided";

          resource = scopeMkResource {
            apiVersion = "v1";
            kind = "Secret";
            inherit
              name
              labels
              requires
              ;
            annotations =
              annotations
              // {
                "kix.dev/secret-keys" = builtins.concatStringsSep "," effectiveKeys;
              }
              // lib.optionalAttrs (source != null) {
                "kix.dev/sops-source" = toString source;
              }
              // lib.optionalAttrs (hash != null) {
                "kix.dev/content-hash" = hash;
              }
              // lib.optionalAttrs (meta ? classification) {
                "kix.dev/classification" = meta.classification;
              }
              // lib.optionalAttrs (meta ? rotationPolicy) {
                "kix.dev/rotation-policy" = meta.rotationPolicy;
              };
            extra = {
              inherit type;
            }
            // lib.optionalAttrs (stringData != { }) { inherit stringData; }
            // extra;
          };

          resourceCtx = builtins.getContext "${resource}";
          attachCtx = value: builtins.appendContext (toString value) resourceCtx;

          secretHelpers = k8s.mkSecretHelpers {
            inherit name type attachCtx;
            keys = effectiveKeys;
          };
        in
        resource // { out = resource.out // secretHelpers; };

      # Reference an externally-managed secret (Vault, ESO, cert-manager, bootstrap).
      # No manifest produced — creates a store path for dependency tracking only.
      # Same out API as mkSecret: keyRef, mkEnv, envFrom, volume.
      #
      # Usage:
      #   creds = scope.mkSecretRef {
      #     name = "vault-db-creds";
      #     keys = [ "username" "password" ];
      #   };
      #   env = creds.out.mkEnv { DB_USER = "username"; };
      mkSecretRef =
        {
          name,
          keys,
          type ? "Opaque",
          requires ? [ ],
        }:
        let
          refPath = builtins.toFile "secret-ref-${name}" (
            builtins.toJSON {
              inherit
                name
                keys
                type
                ;
            }
          );
          refCtx = builtins.getContext "${refPath}";
          attachCtx = value: builtins.appendContext (toString value) refCtx;

          secretHelpers = k8s.mkSecretHelpers {
            inherit
              name
              keys
              type
              attachCtx
              ;
          };
        in
        {
          _type = "secret-ref";
          outPath = refPath;
          inherit requires;
          out = {
            name = attachCtx name;
          }
          // secretHelpers;
        };

      # The scope object — self-referencing via Nix laziness so mkCR can pass
      # the full scope to crd.out.mkCR.
      scopeObj = {
        inherit
          instanceName
          namespaceName
          selectorLabels
          labelStyle
          namespaces
          ;
        namespace = namespaceResource;

        mkResource = scopeMkResource;

        forNamespace =
          nsName:
          let
            nsRes =
              namespaces.${nsName}
                or (throw "scope.forNamespace: namespace '${nsName}' does not exist in the cluster");
          in
          mkScope {
            inherit
              instanceName
              namespaces
              clusterLabels
              labelStyle
              capabilities
              ;
            namespaceName = nsName;
            namespaceResource = nsRes;
          };

        mkClusterResource = scopeMkClusterResource;

        inherit rbac;

        mkDeployment = mkWorkload "apps/v1" "Deployment";
        mkStatefulSet = mkWorkload "apps/v1" "StatefulSet";
        mkDaemonSet = mkWorkload "apps/v1" "DaemonSet";

        inherit
          crd
          mkCRD
          mkCRDRef
          mkCR
          mkSecret
          mkSecretRef
          ;
      };
    in
    scopeObj;
}

# Scope — per-instance context injected into packages.
# Contains mkResource, mkClusterResource, workload builders, CRD support.

{
  lib,
  k8s,
  rbac,
}:

let
  inherit (k8s) clusterScoped;
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

      scopeMkResource =
        {
          labels ? { },
          ...
        }@args:
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
        };

      # WARNING: StatefulSet.spec.serviceName must use .name (plain string),
      # NOT .out.name (context-carrying). Using .out.name creates a store DAG
      # edge to the Service. If the Service also has `requires` pointing back
      # to the StatefulSet, this causes infinite recursion during evaluation.
      # The serviceName field is a plain K8s name match, not a dependency.
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

      # Create a CRD resource with auto-attached CR builders on .out.
      # Returns a resource (usable in requires, etc.) with .out.{cr, mkCR}.
      mkCRD =
        {
          group,
          kind,
          plural,
          singular,
          listKind,
          version ? "v1",
          crdScope ? "Namespaced",
          labels ? { },
          shortNames ? [ ],
          categories ? [ ],
          printerColumns ? [ ],
          schema ?
            builtins.trace
              "mkCRD: no schema provided for ${kind}, using permissive default — consider adding an OpenAPI schema"
              {
                type = "object";
                "x-kubernetes-preserve-unknown-fields" = true;
              },
        }:
        let
          crdResource = scopeMkClusterResource {
            apiVersion = "apiextensions.k8s.io/v1";
            kind = "CustomResourceDefinition";
            name = "${plural}.${group}";
            inherit labels;
            extra.spec = {
              inherit group;
              scope = crdScope;
              names = {
                inherit
                  kind
                  listKind
                  plural
                  singular
                  ;
              }
              // lib.optionalAttrs (shortNames != [ ]) { inherit shortNames; }
              // lib.optionalAttrs (categories != [ ]) { inherit categories; };
              versions = [
                (
                  {
                    name = version;
                    served = true;
                    storage = true;
                    subresources.status = { };
                    schema.openAPIV3Schema = {
                      type = "object";
                      properties = {
                        apiVersion = {
                          type = "string";
                        };
                        kind = {
                          type = "string";
                        };
                        metadata = {
                          type = "object";
                        };
                        spec = schema;
                        status = {
                          type = "object";
                          "x-kubernetes-preserve-unknown-fields" = true;
                        };
                      };
                    };
                  }
                  // lib.optionalAttrs (printerColumns != [ ]) {
                    additionalPrinterColumns = printerColumns;
                  }
                )
              ];
            };
          };

          builders = k8s.mkCRDBuilders {
            crdOrRef = crdResource;
            inherit
              group
              kind
              version
              crdScope
              ;
          };
        in
        crdResource
        // {
          out = crdResource.out // builders;
        };

      # Create a CRD reference for externally-managed CRDs (Helm, pre-existing).
      # Has its own store path for dependency tracking but produces no deployable manifest.
      # Same .out.{cr, mkCR} interface as mkCRD.
      mkCRDRef =
        {
          group,
          kind,
          plural,
          version ? "v1",
          crdScope ? "Namespaced",
          requires ? [ ],
        }:
        let
          refPath = builtins.toFile "crd-ref-${kind}" (
            builtins.toJSON {
              inherit
                group
                kind
                version
                crdScope
                ;
            }
          );
          ref = {
            _type = "crd-ref";
            outPath = refPath;
            inherit requires;
            out = {
              name = "${plural}.${group}";
            }
            // builders;
          };
          builders = k8s.mkCRDBuilders {
            crdOrRef = ref;
            inherit
              group
              kind
              version
              crdScope
              ;
          };
        in
        ref;

      # Scope-side CRD builder: reads the CRD's scope and auto-routes.
      # Uses scopeObj (lazy self-reference) so crd.out.mkCR gets the full scope.
      mkCR = crd: args: crd.out.mkCR scopeObj args;

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
              ;
            namespaceName = nsName;
            namespaceResource = nsRes;
          };

        mkClusterResource = scopeMkClusterResource;

        inherit rbac;

        mkDeployment = mkWorkload "apps/v1" "Deployment";
        mkStatefulSet = mkWorkload "apps/v1" "StatefulSet";
        mkDaemonSet = mkWorkload "apps/v1" "DaemonSet";

        inherit mkCRD mkCRDRef mkCR;
      };
    in
    scopeObj;
}

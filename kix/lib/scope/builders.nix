{ lib, k8s }:

let
  inherit (k8s) clusterScoped;
in
{
  mkBuilders =
    {
      instanceName,
      namespaceName,
      namespaceResource,
      clusterLabels,
      clusterDomain,
      instanceLabels,
      validators,
      edgeAnalysis,
      workloadInterceptors,
      peekedPackageMeta,
      clusterCtx,
      # cluster.factBehavior, keyed "group/Kind": operator override (wins
      # over the CRD-declared behavior arriving via mkCR) and fallback for
      # builder-less CRs (helm-rendered, raw mkResource)
      factBehaviorOverrides ? { },
      # scopeObj is the enclosing mkScope fixpoint — only consume lazily (interceptor ctx, mkCR); forcing it while default.nix constructs it would recurse
      scopeObj,
    }:
    rec {
      scopeMkResource =
        {
          labels ? { },
          ...
        }@args:
        let
          behavior = resolveFactBehavior args;
          # a terminate-declared CR dials out (via its operands) — it waits
          # on DNS like any dialing workload would. Conservative: spliced
          # even when this particular CR absorbed no endpoint (harmless).
          dnsRequires = lib.optional (
            behavior != null && behavior.endpoint == "terminate" && edgeAnalysis.dnsRoot != null
          ) edgeAnalysis.dnsRoot;
        in
        builtins.seq (validators.checkRawPvc args) (
          builtins.seq (validators.checkLoadBalancer args) (
            k8s.mkResource (
              removeAttrs args [ "labels" ]
              // {
                namespace = namespaceResource;
                inherit clusterDomain;
                labels = clusterLabels // instanceLabels // labels;
                factBehavior = behavior;
                requires = (args.requires or [ ]) ++ dnsRequires;
              }
            )
            // {
              packageLabels = labels;
            }
          )
        );

      # Behavior is a property of the CRD: it normally arrives in args via
      # the typed builder chain (mkCRD/mkCRDRef → mkCRDBuilders.cr → mkCR).
      # The cluster override (keyed "group/Kind") wins; it also covers
      # builder-less CRs (helm-rendered, raw mkResource by kind string).
      resolveFactBehavior =
        args:
        let
          apiVersion = args.apiVersion or "";
          group = if lib.hasInfix "/" apiVersion then builtins.head (lib.splitString "/" apiVersion) else "";
          key = "${group}/${args.kind or ""}";
        in
        factBehaviorOverrides.${key} or (args.factBehavior or null);

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
            factBehavior = resolveFactBehavior args;
          }
        )
        // {
          packageLabels = labels;
        };

      _expandServiceAccount =
        templateSpec:
        if !(templateSpec ? serviceAccount) then
          templateSpec
        else
          let
            sa = templateSpec.serviceAccount;
            saNs =
              if (sa.namespace._type or "") == "k8s-cluster-scoped" then null else sa.namespace.name or null;
            existingKix = templateSpec._kix or { };
          in
          if sa == null then
            removeAttrs templateSpec [ "serviceAccount" ]
          else
            (removeAttrs templateSpec [ "serviceAccount" ])
            // {
              serviceAccountName = sa.out.name;
              _kix =
                existingKix
                // lib.optionalAttrs (saNs != null) {
                  serviceAccountNamespace = saNs;
                };
            };

      _expandHeadlessService =
        spec:
        if !(spec ? headlessService) then
          spec
        else
          let
            svc = spec.headlessService;
            svcNs =
              if (svc.namespace._type or "") == "k8s-cluster-scoped" then null else svc.namespace.name or null;
          in
          if svc == null then
            removeAttrs spec [ "headlessService" ]
          else if (svc._type or "") != "k8s-resource" || svc.kind or "" != "Service" then
            throw "[${instanceName}] mkStatefulSet headlessService must be a Service resource "
            + "(got ${svc._type or "non-resource"}, kind=${svc.kind or "?"})"
          else if svcNs != null && svcNs != namespaceName then
            throw "[${instanceName}] StatefulSet headlessService '${svc.name}' is in namespace "
            + "\"${svcNs}\" but the StatefulSet is in namespace \"${namespaceName}\"."
          else
            (removeAttrs spec [ "headlessService" ])
            // {
              # plain svc.name (no string context): a context-carrying serviceName would create a Service→StatefulSet store edge that recurses when the Service requires the StatefulSet
              serviceName = svc.name;
            };

      # The emission facade handed to hooks: sealing capability only, never
      # the authoring scope. `mkResource` seals in this instance's namespace
      # with instance labels and validators; `inNamespace` parents a resource
      # into another namespace while keeping this instance as owner. If a
      # plugin needs more than this, extend the facade deliberately (design
      # doc first) — do not hand hooks the scope object.
      emit = {
        mkResource = scopeMkResource;
        mkClusterResource = scopeMkClusterResource;
        inNamespace = nsName: {
          mkResource = (scopeObj.forNamespace nsName).mkResource;
        };
      };

      sealWorkload =
        {
          workloadInput,
          workloadKind,
          selector,
          hostNetwork,
        }:
        let
          edgeReport = edgeAnalysis.edgesFor workloadInput;
          edges = edgeReport.edges;
          # DNS ordering uses the conservative edge set: naming a Service is
          # weak dial evidence, and a spurious DNS wait is harmless
          dnsDeps =
            if edgeReport.dnsEdges != [ ] && edgeAnalysis.dnsRoot != null then
              [ edgeAnalysis.dnsRoot ]
            else
              [ ];
          interceptorResults = map (
            interceptor:
            interceptor {
              inherit
                workloadInput
                workloadKind
                selector
                hostNetwork
                edges
                emit
                instanceName
                namespaceName
                ;
              inherit (edgeAnalysis) serviceRegistry serviceRefRegistry;
              packageMeta = peekedPackageMeta;
              cluster = clusterCtx;
            }
          ) workloadInterceptors;
          interceptorRequires = builtins.concatMap (r: r.requires or [ ]) interceptorResults;
          interceptorResources = builtins.concatMap (r: r.resources or [ ]) interceptorResults;
          interceptorWarnings = builtins.concatMap (r: r.warnings or [ ]) interceptorResults;
          # Splice order contract: author-declared requires, then plugin
          # requires, then core DNS deps. kix.dev/depends-on stamps entries
          # in list order, so this order is content-addressed into the
          # manifest — change it only as a deliberate output change.
          workload = scopeMkResource (
            removeAttrs workloadInput [ "_helmNetworkDeps" ]
            // {
              requires = (workloadInput.requires or [ ]) ++ interceptorRequires ++ dnsDeps;
            }
          );
        in
        # Trace warnings anchored on outPath, NOT on the whole attrset:
        # edge-lint warnings force toJSON(workloadInput) — serializing
        # `requires` whose sealed manifests may reference this workload's
        # rawSelector (e.g. a webhook config embedding the admission
        # Service's out.name, whose selector reads rawSelector). rawSelector
        # must stay reachable without forcing edge analysis; outPath is
        # forced at every embedding anyway, so no warning is lost.
        workload
        // {
          outPath = builtins.foldl' (acc: warning: builtins.trace warning acc) workload.outPath (
            interceptorWarnings ++ map (w: "[${instanceName}] ${w}") edgeReport.warnings
          );
          _injectedResources = interceptorResources;
          rawSelector = selector;
        };

      mkWorkload =
        apiVersion: kind: attrs:
        let
          rawSpec = attrs.spec or { };
          spec = if kind == "StatefulSet" then _expandHeadlessService rawSpec else rawSpec;
          selector =
            spec.selector.matchLabels
              or (throw "mkWorkload (${kind}): spec.selector.matchLabels is required — use scope.selectorLabels");
          templateMeta = spec.template.metadata or { };
          rawTemplateSpec = spec.template.spec or { };
          templateSpec = _expandServiceAccount rawTemplateSpec;

          userSuppliedLabels = templateMeta ? labels;
          effectiveTemplateLabels = if userSuppliedLabels then templateMeta.labels else selector;

          hostNetwork = templateSpec.hostNetwork or false;

          finalSpec =
            removeAttrs spec [
              "selector"
              "template"
            ]
            // {
              selector.matchLabels = selector;
              template = {
                metadata = templateMeta // {
                  labels = effectiveTemplateLabels;
                };
                spec = templateSpec;
              };
            };

          baseArgs = removeAttrs attrs [ "spec" ] // {
            inherit apiVersion kind;
            spec = finalSpec;
          };
        in
        builtins.seq (validators.checkDaemonSet kind) (
          builtins.seq (validators.checkPrivileged templateSpec) (
            builtins.seq
              (
                if userSuppliedLabels then
                  validators.checkSelectorSubset selector templateMeta.labels kind
                else
                  null
              )
              (
                builtins.seq (validators.checkNamespacedRefs templateSpec) (
                  builtins.seq (validators.checkNamedPorts templateSpec) (
                    builtins.seq (validators.checkContainerResources templateSpec) (
                      builtins.seq (validators.checkDuplicateNames templateSpec) (
                        builtins.seq (validators.checkFieldRefs templateSpec) (sealWorkload {
                          workloadInput = baseArgs;
                          workloadKind = kind;
                          inherit selector hostNetwork;
                        })
                      )
                    )
                  )
                )
              )
          )
        );

      mkJob =
        attrs:
        let
          kind = "Job";
          apiVersion = "batch/v1";
          rawSpec = attrs.spec or { };
          selector =
            rawSpec.selector.matchLabels or rawSpec.template.metadata.labels
              or (throw "mkJob: spec.selector.matchLabels or spec.template.metadata.labels is required");
          templateMeta = rawSpec.template.metadata or { };
          rawTemplateSpec = rawSpec.template.spec or { };
          templateSpec = _expandServiceAccount rawTemplateSpec;

          hostNetwork = templateSpec.hostNetwork or false;

          effectiveTemplateLabels = templateMeta.labels or selector;

          finalSpec =
            removeAttrs rawSpec [
              "selector"
              "template"
            ]
            // lib.optionalAttrs (rawSpec ? selector) {
              selector.matchLabels = selector;
            }
            // {
              template = {
                metadata = templateMeta // {
                  labels = effectiveTemplateLabels;
                };
                spec = templateSpec;
              };
            };

          baseArgs = removeAttrs attrs [ "spec" ] // {
            inherit apiVersion kind;
            spec = finalSpec;
          };
        in
        builtins.seq (validators.checkPrivileged templateSpec) (
          builtins.seq (validators.checkNamespacedRefs templateSpec) (
            builtins.seq (validators.checkContainerResources templateSpec) (
              builtins.seq (validators.checkDuplicateNames templateSpec) (
                builtins.seq (validators.checkFieldRefs templateSpec) (sealWorkload {
                  workloadInput = baseArgs;
                  workloadKind = kind;
                  inherit selector hostNetwork;
                })
              )
            )
          )
        );

      mkHelmWorkload =
        attrs:
        let
          kind = attrs.kind or (throw "mkHelmWorkload: kind is required");
          apiVersion = attrs.apiVersion or "apps/v1";
          rawSpec = attrs.spec or { };
          selector =
            rawSpec.selector.matchLabels or rawSpec.template.metadata.labels
              or (throw "mkHelmWorkload (${kind}): spec.selector.matchLabels or spec.template.metadata.labels is required");
          hostNetwork = rawSpec.template.spec.hostNetwork or false;

          # _helmNetworkDeps stays in workloadInput so edge detection sees its store-path context; sealWorkload strips it before mkResource
          workloadInput = attrs // {
            inherit apiVersion kind;
          };
        in
        sealWorkload {
          inherit workloadInput selector hostNetwork;
          workloadKind = kind;
        };

      mkOptional =
        cond: builder:
        if cond then (if builtins.isFunction builder then builder null else builder) else null;

      mkWebhookService =
        {
          name,
          selector,
          port ? 443,
          targetPort ? "webhook",
          caBundle ? null,
          validating ? [ ],
          mutating ? [ ],
          extraServiceSpec ? { },
        }:
        let
          svc = scopeMkResource {
            apiVersion = "v1";
            kind = "Service";
            inherit name;
            spec = {
              inherit selector;
              ports = [
                {
                  name = "webhook";
                  inherit port targetPort;
                  protocol = "TCP";
                }
              ];
            }
            // extraServiceSpec;
          };

          clientConfigFor =
            hook:
            {
              service = {
                name = svc.out.name;
                namespace = namespaceName;
                path = hook.path;
                inherit port;
              };
            }
            // lib.optionalAttrs (caBundle != null) { inherit caBundle; };

          buildHook = hook: {
            name = hook.name;
            admissionReviewVersions = hook.admissionReviewVersions or [ "v1" ];
            sideEffects = hook.sideEffects or "None";
            failurePolicy = hook.failurePolicy or "Fail";
            matchPolicy = hook.matchPolicy or "Equivalent";
            timeoutSeconds = hook.timeoutSeconds or 10;
            rules = map (rule: {
              apiGroups = rule.apiGroups or [ "*" ];
              apiVersions = rule.apiVersions or [ "*" ];
              operations =
                rule.operations or [
                  "CREATE"
                  "UPDATE"
                ];
              resources = rule.resources;
              scope = rule.scope or "*";
            }) (hook.rules or [ ]);
            clientConfig = clientConfigFor hook;
          };

          validatingRes =
            if validating == [ ] then
              null
            else
              scopeMkClusterResource {
                apiVersion = "admissionregistration.k8s.io/v1";
                kind = "ValidatingWebhookConfiguration";
                name = "${name}-validating";
                extra.webhooks = map buildHook validating;
              };

          mutatingRes =
            if mutating == [ ] then
              null
            else
              scopeMkClusterResource {
                apiVersion = "admissionregistration.k8s.io/v1";
                kind = "MutatingWebhookConfiguration";
                name = "${name}-mutating";
                extra.webhooks = map buildHook mutating;
              };
        in
        {
          service = svc;
        }
        // lib.optionalAttrs (validatingRes != null) { validatingConfiguration = validatingRes; }
        // lib.optionalAttrs (mutatingRes != null) { mutatingConfiguration = mutatingRes; };

      mkCRD =
        attrs:
        let
          crdSpec = attrs.spec or (throw "mkCRD: spec is required");
          labels = attrs.labels or { };
          annotations = attrs.annotations or { };
          crKind = crdSpec.names.kind;
          group = crdSpec.group;
          plural = crdSpec.names.plural;
          version = (builtins.head crdSpec.versions).name;
          crdScope = crdSpec.scope or "Namespaced";
          factBehavior =
            if attrs ? factBehavior && attrs.factBehavior != null then
              k8s.facts.validateBehavior "mkCRD ${instanceName}" "${group}/${crKind}" attrs.factBehavior
            else
              null;

          crdResource = scopeMkClusterResource {
            apiVersion = "apiextensions.k8s.io/v1";
            kind = "CustomResourceDefinition";
            name = "${plural}.${group}";
            inherit labels;
            extra = {
              spec = crdSpec;
            }
            // lib.optionalAttrs (annotations != { }) {
              metadata = { inherit annotations; };
            };
          };

          crdBuilders = k8s.mkCRDBuilders {
            crdOrRef = crdResource;
            group = group;
            kind = crKind;
            inherit version crdScope factBehavior;
          };
        in
        crdResource
        // {
          out = crdResource.out // crdBuilders;
        };

      mkImportMarker =
        {
          markerName,
          importKind,
          importApiVersion,
          importName,
          extraAnnotations ? { },
          extraRequires ? [ ],
        }:
        scopeMkResource {
          apiVersion = "kix.dev/v1alpha1";
          kind = "PackageInstance";
          name = markerName;
          annotations = {
            "kix.dev/mode" = "import";
            "kix.dev/import-kind" = importKind;
            "kix.dev/import-apiversion" = importApiVersion;
            "kix.dev/import-name" = importName;
          }
          // extraAnnotations;
          requires = [ k8s.kixCRDs.packageInstance ] ++ extraRequires;
          extra.spec = {
            instanceName = markerName;
            namespaceName = namespaceName;
            mode = "import";
          };
        };

      mkCRDRef =
        {
          group,
          kind,
          plural,
          version ? "v1",
          crdScope ? "Namespaced",
          installedBy ? null,
          # controller semantics of this kind (see core/facts.nix): declared
          # here because behavior is a property of the CRD, and this is where
          # the CRD-owning package reifies the kind. Threads through mkCR
          # into every CR's seal.
          factBehavior ? null,
        }:
        let
          _validatedBehavior =
            if factBehavior != null then
              k8s.facts.validateBehavior "mkCRDRef ${instanceName}" "${group}/${kind}" factBehavior
            else
              null;
          crdName = "${plural}.${group}";
          groupSlug = builtins.replaceStrings [ "." ] [ "-" ] group;
          markerName = "crd-ref-${plural}-${groupSlug}";

          installedByList =
            if installedBy == null then
              [ ]
            else if builtins.isList installedBy then
              installedBy
            else
              [ installedBy ];

          marker = mkImportMarker {
            inherit markerName;
            importKind = "CustomResourceDefinition";
            importApiVersion = "apiextensions.k8s.io/v1";
            importName = crdName;
            extraRequires = installedByList;
          };

          crdBuilders = k8s.mkCRDBuilders {
            crdOrRef = marker;
            factBehavior = _validatedBehavior;
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
          out = marker.out // crdBuilders;
        };

      mkCR = crd: args: crd.out.mkCR scopeObj args;

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

          realizedSource =
            if source == null then
              null
            else
              builtins.path {
                path = source;
                # toFile-style name cannot carry string context — baseNameOf + discard keeps it plain
                name = baseNameOf (builtins.unsafeDiscardStringContext (toString source));
              };

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
                "kix.dev/sops-source" = toString realizedSource;
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
            namespace = namespaceName;
          };
        in
        resource // { out = resource.out // secretHelpers; };

      mkSecretRef =
        {
          name,
          keys,
          type ? "Opaque",
          requires ? [ ],
          reflect ? false,
        }:
        let
          _ =
            if !(builtins.isList keys) then
              throw "mkSecretRef \"${name}\": 'keys' must be a list of strings (got ${builtins.typeOf keys})"
            else
              null;

          markerName = "secret-ref-${instanceName}-${name}";

          marker = builtins.seq _ (mkImportMarker {
            inherit markerName;
            importKind = "Secret";
            importApiVersion = "v1";
            importName = name;
            extraAnnotations = {
              "kix.dev/secret-type" = type;
            }
            // lib.optionalAttrs (keys != [ ]) {
              "kix.dev/import-secret-keys" = builtins.concatStringsSep "," keys;
            };
            extraRequires = requires;
          });

          resourceCtx = builtins.getContext "${marker}";
          attachCtx = value: builtins.appendContext (toString value) resourceCtx;

          secretHelpers = k8s.mkSecretHelpers {
            inherit
              name
              keys
              type
              attachCtx
              ;
            namespace = namespaceName;
            reflected = reflect;
          };
        in
        marker
        // {
          out = {
            name = attachCtx name;
          }
          // secretHelpers;
        };

      mkServiceRef =
        {
          name,
          selector,
          ports,
          requires ? [ ],
        }:
        let
          markerName = "service-ref-${instanceName}-${name}";

          marker = mkImportMarker {
            inherit markerName;
            importKind = "Service";
            importApiVersion = "v1";
            importName = name;
            extraAnnotations = {
              "kix.dev/service-selector" = builtins.toJSON selector;
              "kix.dev/service-ports" = builtins.toJSON ports;
            };
            extraRequires = requires;
          };

          resourceCtx = builtins.getContext "${marker}";
          attachCtx = value: builtins.appendContext (toString value) resourceCtx;

          # the ref knows selector+ports explicitly — mint the endpoint fact
          # from the declaration, same channel as a managed Service's seal
          endpointFactCtx = k8s.facts.mkFact "endpoint" {
            inherit name selector ports;
            namespace = namespaceName;
          };
          attachConnectCtx = value: builtins.appendContext (toString value) (resourceCtx // endpointFactCtx);

          fqdn = "${name}.${namespaceName}.svc";
        in
        marker
        // {
          factTokens = {
            endpoint = endpointFactCtx;
          };
          out = {
            name = attachCtx name;
            fqdn = attachConnectCtx fqdn;
            port = attachConnectCtx (toString (builtins.head ports).port);
            ports = ports;
            inherit selector;
          };
        };
    };
}

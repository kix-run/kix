{ lib, k8s }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  availabilityLib = import ../core/availability.nix { inherit lib; };
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
      availability,
      # Overrides keyed by "group/Kind" take precedence over CRD declarations
      # and also cover custom resources without typed builders.
      factBehaviorOverrides ? { },
      # scopeObj is the enclosing mkScope fixpoint. Access it only from lazy
      # interceptor and mkCR paths to avoid recursion while building the scope.
      scopeObj,
      # `<namespace>/<instance>` of the instance this scope builds for. Every
      # sealed resource carries it as `_builtBy`, outside the manifest, so the
      # cluster can list a resource that several instances hold under the one
      # that built it.
      builtBy,
    }:
    rec {
      # Workload kinds must use their typed builders so pod validation, edge
      # analysis, and workload interceptors run before sealing. sealWorkload
      # calls sealResource after that processing.
      workloadKinds = [
        "Deployment"
        "StatefulSet"
        "DaemonSet"
        "Job"
        "CronJob"
      ];
      builderFor = {
        Deployment = "scope.mkDeployment";
        StatefulSet = "scope.mkStatefulSet";
        DaemonSet = "scope.mkDaemonSet";
        Job = "scope.mkJob";
        CronJob = "scope.mkCronJob";
      };
      checkNotRawWorkload =
        args:
        let
          kind = args.kind or "";
        in
        if builtins.elem kind workloadKinds then
          fail {
            instance = builtBy;
            message =
              "${kind} '${args.name or "?"}' is built with scope.mkResource, which skips workload-specific processing: "
              + "pod validation, automatic replica placement and PodDisruptionBudgets, and network "
              + "policy dependencies.";
            fix = "Build it with ${builderFor.${kind}} instead (drop apiVersion and kind; keep the other attributes).";
          }
        else
          null;

      scopeMkResource = args: builtins.seq (checkNotRawWorkload args) (sealResource args);

      # `holdsData` is a fact about a kind, so it is declared once on the
      # kind's mkCRD or mkCRDRef and reaches each custom resource through mkCR.
      checkNoHoldsData =
        args:
        if args ? holdsData then
          fail {
            instance = builtBy;
            message = "${args.kind or "?"} '${args.name or "?"}' sets holdsData on one object. holdsData is declared once per kind.";
            fix = "Set holdsData on the scope.mkCRD or scope.mkCRDRef of the kind and build the resource with scope.mkCR. Kix decides whether a built-in object holds data from its shape.";
          }
        else
          null;

      sealResource =
        {
          labels ? { },
          ...
        }@args:
        let
          behavior = resolveFactBehavior args;
          # A terminating custom resource represents pods that connect to
          # endpoints, so order it after DNS when a DNS provider exists.
          dnsRequires = lib.optional (
            behavior != null && behavior.endpoint == "terminate" && edgeAnalysis.dnsRoot != null
          ) edgeAnalysis.dnsRoot;
        in
        builtins.seq (checkNoHoldsData args) (
          builtins.seq (validators.checkResourceName args) (
            builtins.seq (validators.checkRawPvc args) (
              builtins.seq (validators.checkLoadBalancer args) (
                builtins.seq (validators.checkHorizontalPodAutoscaler args) (
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
                    _builtBy = builtBy;
                  }
                )
              )
            )
          )
        );

      # Prefer the cluster's "group/Kind" override to behavior passed through
      # a typed CRD builder. The override also covers untyped custom resources.
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
        builtins.seq (checkNoHoldsData args) (
          k8s.mkResource (
            removeAttrs args [ "labels" ]
            // {
              namespace = clusterScoped;
              inherit clusterDomain;
              labels = clusterLabels // instanceLabels // labels;
              factBehavior = resolveFactBehavior args;
            }
          )
        )
        // {
          packageLabels = labels;
          _builtBy = builtBy;
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
            fail {
              instance = builtBy;
              message = "mkStatefulSet headlessService must be a Service resource (got ${svc._type or "non-resource"}, kind=${svc.kind or "?"}).";
            }
          else if svcNs != null && svcNs != namespaceName then
            fail {
              instance = builtBy;
              message = "StatefulSet headlessService '${svc.name}' is in namespace \"${svcNs}\" but the StatefulSet is in namespace \"${namespaceName}\".";
            }
          else
            (removeAttrs spec [ "headlessService" ])
            // {
              # Keep serviceName free of string context. A dependency from the
              # Service back to this StatefulSet would otherwise recurse.
              serviceName = svc.name;
            };

      # Hooks receive only the resource constructors they need. mkResource
      # uses this instance's namespace, labels, and validators; inNamespace
      # emits into another namespace while retaining this instance as owner.
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
          # Highest availability level this workload supports (checked by
          # workloadCeilingOf), or null.
          workloadCeiling ? null,
        }:
        let
          # Apply a builder ceiling to this workload only. Keep the package's
          # availability argument unchanged because other workloads in the
          # same package may support the requested level.
          capped =
            workloadCeiling != null
            && availabilityLib.rank availability.level > availabilityLib.rank workloadCeiling;
          packageCeiling = availability.ceiling or null;
          # The lower of the builder and package ceilings. On a tie the
          # package is named, because a partsOverlays entry that drops the
          # builder's availability.max still leaves the package ceiling.
          builderIsLower =
            workloadCeiling != null
            && (
              packageCeiling == null || availabilityLib.rank workloadCeiling < availabilityLib.rank packageCeiling
            );
          effectiveCeiling = if builderIsLower then workloadCeiling else packageCeiling;
          ceilingFrom =
            if builderIsLower then
              "builder"
            else if packageCeiling != null then
              "package"
            else
              null;
          # The availability plugin reads `ceiling` and `ceilingFrom` after
          # sealing, so they are set whether or not the builder ceiling caps.
          workloadAvailability =
            (
              if capped then
                availability
                // {
                  level = workloadCeiling;
                  capped = true;
                  warnings = [ ];
                }
              else
                availability
            )
            // {
              ceiling = effectiveCeiling;
              inherit ceilingFrom;
            };
          cappedConsequence =
            {
              none = "is a single point of failure: a pod crash, a rolling update, or a node loss causes downtime";
              pod = "does not survive the loss of its node";
              node = "does not survive the loss of a zone";
            }
            .${workloadCeiling} or "";
          ceilingWarnings = lib.optional capped (
            "[${namespaceName}/${instanceName}] ${workloadKind} '${workloadInput.name or "?"}' supports at most "
            + "\"${workloadCeiling}\" (availability.max on its builder call), so under availability "
            + "\"${availability.level}\" it ${cappedConsequence}. This is a limit of the package; "
            + "the instance's other workloads run at \"${availability.level}\"."
          );
          edgeReport = edgeAnalysis.edgesFor workloadInput;
          edges = edgeReport.edges;
          # Use conservative connection evidence for DNS ordering so Helm
          # workloads whose address facts were lost still wait for DNS.
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
              availability = workloadAvailability;
            }
          ) workloadInterceptors;
          interceptorRequires = builtins.concatMap (r: r.requires or [ ]) interceptorResults;
          interceptorResources = builtins.concatMap (r: r.resources or [ ]) interceptorResults;
          interceptorWarnings = builtins.concatMap (r: r.warnings or [ ]) interceptorResults;
          # Merge interceptor podSpec fields before sealing so they affect the
          # workload identity. Author fields override interceptor fields; an
          # earlier interceptor wins conflicts between interceptors.
          interceptorPodSpec = builtins.foldl' (acc: r: (r.podSpec or { }) // acc) { } interceptorResults;
          # Keep the conditional merge inside spec. Selecting between whole
          # workload values here would force interceptors when rawSelector is
          # read, which can recurse through ConfigMap and Service references.
          patchedInput = workloadInput // {
            spec =
              if interceptorPodSpec == { } then
                workloadInput.spec
              else
                workloadInput.spec
                // {
                  template = workloadInput.spec.template // {
                    spec = interceptorPodSpec // (workloadInput.spec.template.spec or { });
                  };
                };
          };
          # Preserve dependency order: author requirements, interceptor
          # requirements, then DNS. kix.run/depends-on retains list order, so
          # changing it changes the manifest identity.
          workload = sealResource (
            removeAttrs patchedInput [ "_helmNetworkDeps" ]
            // {
              requires = (workloadInput.requires or [ ]) ++ interceptorRequires ++ dnsDeps;
            }
          );
        in
        # Attach warnings to outPath so reading rawSelector does not force edge
        # analysis. Edge analysis may traverse a dependency whose Service
        # selector reads this workload's rawSelector, causing recursion.
        workload
        // {
          outPath = builtins.foldl' (acc: warning: builtins.trace warning acc) workload.outPath (
            interceptorWarnings ++ ceilingWarnings ++ map (w: "[${instanceName}] ${w}") edgeReport.warnings
          );
          _injectedResources = interceptorResources;
          rawSelector = selector;
          # Resolved level used by instance processors after sealing.
          _availability = workloadAvailability;
        };

      # Validate the `availability` argument of a workload builder and return its
      # `max` ceiling, or null when unset.
      workloadCeilingOf =
        kind: attrs:
        let
          where = "${namespaceName}/${instanceName}";
          subject = "${kind} '${attrs.name or "?"}'";
          a = attrs.availability;
          unknown = builtins.attrNames (removeAttrs a [ "max" ]);
        in
        if !(attrs ? availability) then
          null
        else if kind == "DaemonSet" then
          fail {
            instance = where;
            message = "${subject} sets availability, but a DaemonSet runs one pod per node, so availability.max has no effect on it.";
            fix = "Remove it.";
          }
        else if !builtins.isAttrs a then
          fail {
            instance = where;
            message = "${subject} availability is a ${builtins.typeOf a}.";
            fix = "Write availability.max = \"<level>\".";
          }
        else if unknown != [ ] then
          fail {
            instance = where;
            message = "${subject} availability has unknown key(s) ${lib.concatStringsSep ", " unknown}. The only key is max.";
          }
        else if (a.max or null) == null then
          null
        else
          availabilityLib.checkCeiling {
            value = a.max;
            inherit where;
            what = "${subject} availability.max";
          };

      # Force pod validation through outPath so rawSelector remains available
      # without sealing the workload. Validation can traverse ConfigMap and
      # Service references that lead back to rawSelector. Every emitted
      # resource forces outPath, so each check still runs.
      withChecks =
        checks: res:
        res
        // {
          outPath = builtins.foldl' (acc: c: builtins.seq c acc) res.outPath checks;
        };

      mkWorkload =
        apiVersion: kind: attrs:
        let
          rawSpec = attrs.spec or { };
          spec = if kind == "StatefulSet" then _expandHeadlessService rawSpec else rawSpec;
          selector =
            spec.selector.matchLabels or (fail {
              message = "${namespaceName}/${instanceName}: ${kind} '${attrs.name or "?"}' (built with ${builderFor.${kind}}) is missing spec.selector.matchLabels.";
              fix = "set `spec.selector.matchLabels = scope.selectorLabels;` in the ${builderFor.${kind}} call.";
            });
          templateMeta = spec.template.metadata or { };
          rawTemplateSpec = spec.template.spec or { };
          templateSpec = _expandServiceAccount rawTemplateSpec;

          userSuppliedLabels = templateMeta ? labels;
          # Workload metadata gets the selector labels, overridden by explicit
          # workload labels. A selector that follows upstream (`app`, `name`)
          # lacks `app.kubernetes.io/name`, so it defaults to the instance name.
          # Pod template labels get the same value unless the author sets it
          # there. `spec.selector` is left alone because it is immutable once
          # applied.
          workloadLabels = {
            "app.kubernetes.io/name" = instanceName;
          }
          // selector
          // (attrs.labels or { });
          effectiveTemplateLabels = {
            "app.kubernetes.io/name" = workloadLabels."app.kubernetes.io/name";
          }
          // (if userSuppliedLabels then templateMeta.labels else selector);

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

          workloadCeiling = workloadCeilingOf kind attrs;

          baseArgs =
            removeAttrs attrs [
              "spec"
              "availability"
            ]
            // {
              inherit apiVersion kind;
              spec = finalSpec;
              labels = workloadLabels;
            };
        in
        withChecks
          [
            workloadCeiling
            (validators.checkDaemonSet kind)
            (validators.checkSpreadFeasible {
              inherit kind;
              name = attrs.name or "?";
              spec = finalSpec;
            })
            (validators.checkPrivileged templateSpec)
            (
              if userSuppliedLabels then
                validators.checkSelectorSubset selector templateMeta.labels kind
              else
                null
            )
            (validators.checkNamespacedRefs templateSpec)
            (validators.checkNamedPorts templateSpec)
            (validators.checkContainerResources templateSpec)
            (validators.checkDuplicateNames templateSpec)
            (validators.checkFieldRefs templateSpec)
          ]
          (sealWorkload {
            workloadInput = baseArgs;
            workloadKind = kind;
            inherit selector hostNetwork workloadCeiling;
          });

      # Process a CronJob's nested pod template through the same validation,
      # DNS ordering, and network-policy path as other workloads.
      mkCronJob =
        attrs:
        let
          kind = "CronJob";
          apiVersion = "batch/v1";
          rawSpec = attrs.spec or { };
          jobSpec = rawSpec.jobTemplate.spec or { };
          templateMeta = jobSpec.template.metadata or { };
          rawTemplateSpec = jobSpec.template.spec or { };
          templateSpec = _expandServiceAccount rawTemplateSpec;

          hostNetwork = templateSpec.hostNetwork or false;

          # CronJobs have no selector, so use pod-template labels to identify
          # their pods during network-policy analysis.
          selector =
            templateMeta.labels or (fail {
              instance = builtBy;
              message = "mkCronJob: spec.jobTemplate.spec.template.metadata.labels is required.";
              fix = "Use scope.selectorLabels.";
            });

          finalSpec = rawSpec // {
            jobTemplate = (rawSpec.jobTemplate or { }) // {
              spec = jobSpec // {
                template = {
                  metadata = templateMeta // {
                    labels = selector;
                  };
                  spec = templateSpec;
                };
              };
            };
          };

          workloadCeiling = workloadCeilingOf kind attrs;

          baseArgs =
            removeAttrs attrs [
              "spec"
              "availability"
            ]
            // {
              inherit apiVersion kind;
              spec = finalSpec;
              labels = selector // (attrs.labels or { });
            };
        in
        withChecks
          [
            workloadCeiling
            (validators.checkPrivileged templateSpec)
            (validators.checkNamespacedRefs templateSpec)
            (validators.checkContainerResources templateSpec)
            (validators.checkDuplicateNames templateSpec)
            (validators.checkFieldRefs templateSpec)
          ]
          (sealWorkload {
            workloadInput = baseArgs;
            workloadKind = kind;
            inherit selector hostNetwork workloadCeiling;
          });

      mkJob =
        attrs:
        let
          kind = "Job";
          apiVersion = "batch/v1";
          rawSpec = attrs.spec or { };
          selector =
            rawSpec.selector.matchLabels or rawSpec.template.metadata.labels or (fail {
              instance = builtBy;
              message = "mkJob: spec.selector.matchLabels or spec.template.metadata.labels is required.";
            });
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

          workloadCeiling = workloadCeilingOf kind attrs;

          baseArgs =
            removeAttrs attrs [
              "spec"
              "availability"
            ]
            // {
              inherit apiVersion kind;
              spec = finalSpec;
              labels = selector // (attrs.labels or { });
            };
        in
        withChecks
          [
            workloadCeiling
            (validators.checkPrivileged templateSpec)
            (validators.checkNamespacedRefs templateSpec)
            (validators.checkContainerResources templateSpec)
            (validators.checkDuplicateNames templateSpec)
            (validators.checkFieldRefs templateSpec)
          ]
          (sealWorkload {
            workloadInput = baseArgs;
            workloadKind = kind;
            inherit selector hostNetwork workloadCeiling;
          });

      # Apply workload validation to chart output. Skip checkNamespacedRefs
      # because chart ConfigMap and Secret names lack DI context; cross-resource
      # validation resolves them later. Chart validation permits duplicate env
      # names through checkDuplicateNamesChart.
      mkHelmWorkload =
        attrs:
        let
          kind =
            attrs.kind or (fail {
              instance = builtBy;
              message = "mkHelmWorkload: kind is required.";
            });
          apiVersion = attrs.apiVersion or "apps/v1";
          rawSpec = attrs.spec or { };
          selector =
            rawSpec.selector.matchLabels or rawSpec.template.metadata.labels or (fail {
              instance = builtBy;
              message = "mkHelmWorkload (${kind}): spec.selector.matchLabels or spec.template.metadata.labels is required.";
            });
          templateMeta = rawSpec.template.metadata or { };
          templateSpec = rawSpec.template.spec or { };
          hostNetwork = templateSpec.hostNetwork or false;

          # Keep _helmNetworkDeps through edge analysis, then remove it before
          # sealing so its store context does not enter the manifest.
          workloadInput = attrs // {
            inherit apiVersion kind;
          };
        in
        builtins.seq (validators.checkDaemonSet kind) (
          builtins.seq
            (validators.checkSpreadFeasible {
              inherit kind;
              name = attrs.name or attrs.metadata.name or "?";
              spec = rawSpec;
            })
            (
              builtins.seq (validators.checkPrivileged templateSpec) (
                builtins.seq
                  (
                    if rawSpec ? selector.matchLabels && templateMeta ? labels then
                      validators.checkSelectorSubset selector templateMeta.labels kind
                    else
                      null
                  )
                  (
                    builtins.seq (validators.checkNamedPorts templateSpec) (
                      builtins.seq (validators.checkContainerResources templateSpec) (
                        builtins.seq (validators.checkDuplicateNamesChart templateSpec) (
                          builtins.seq (validators.checkFieldRefs templateSpec) (sealWorkload {
                            inherit workloadInput selector hostNetwork;
                            workloadKind = kind;
                          })
                        )
                      )
                    )
                  )
              )
            )
        );

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
          crdSpec =
            attrs.spec or (fail {
              instance = builtBy;
              message = "mkCRD: spec is required.";
            });
          labels = attrs.labels or { };
          annotations = attrs.annotations or { };
          crKind = crdSpec.names.kind;
          group = crdSpec.group;
          plural = crdSpec.names.plural;
          # Prefer the CRD storage version; served versions are not necessarily
          # listed in stability order. Fall back to the first version for
          # single-version CRDs or CRDs that omit the storage flag.
          storageVersions = builtins.filter (v: v.storage or false) crdSpec.versions;
          version =
            if storageVersions != [ ] then
              (builtins.head storageVersions).name
            else
              (builtins.head crdSpec.versions).name;
          servedVersions = map (v: v.name) (builtins.filter (v: v.served or true) crdSpec.versions);
          crdScope = crdSpec.scope or "Namespaced";
          factBehavior =
            if attrs ? factBehavior && attrs.factBehavior != null then
              k8s.facts.validateBehavior "mkCRD ${instanceName}" "${group}/${crKind}" attrs.factBehavior
            else
              null;
          # Force validation below so malformed declarations fail while
          # evaluating the CRD-owning package, even if no CR is built.
          readiness = k8s.validateReadiness "mkCRD ${instanceName}" "${group}/${crKind}" (
            attrs.readiness or null
          );

          crdResource = builtins.seq readiness (scopeMkClusterResource {
            apiVersion = "apiextensions.k8s.io/v1";
            kind = "CustomResourceDefinition";
            name = "${plural}.${group}";
            inherit labels;
            ownership = attrs.ownership or { };
            extra = {
              spec = crdSpec;
            }
            // lib.optionalAttrs (annotations != { }) {
              metadata = { inherit annotations; };
            };
          });

          crdBuilders = k8s.mkCRDBuilders {
            crdOrRef = crdResource;
            group = group;
            kind = crKind;
            declaredBy = "scope.mkCRD ${plural}.${group} in ${namespaceName}/${instanceName}";
            inherit
              version
              servedVersions
              crdScope
              factBehavior
              readiness
              ;
            usesAtLeast = attrs.usesAtLeast or null;
            holdsData = attrs.holdsData or null;
          };
        in
        crdResource
        // {
          out = crdResource.out // crdBuilders;
        };

      mkImportMarker = k8s.mkImportMarker {
        mkResource = scopeMkResource;
        inherit namespaceName;
      };

      mkCRDRef = k8s.mkCRDRefHandle {
        mkResource = scopeMkResource;
        inherit instanceName namespaceName;
      };

      mkCR = crd: args: crd.out.mkCR scopeObj args;

      mkSecret =
        {
          name,
          keys ? null,
          type ? "Opaque",
          stringData ? { },
          source ? null,
          # Refused. Kix computes the SOPS file's digest itself.
          hash ? null,
          # Keys whose value is in the manifest and is not a credential (a
          # username, a host). The security.secretSource rule accepts them
          # whatever `cluster.secrets.accept` lists.
          plainKeys ? [ ],
          meta ? { },
          labels ? { },
          annotations ? { },
          requires ? [ ],
          extra ? { },
        }:
        let
          valuedKeys = builtins.attrNames (stringData // (extra.data or { }) // (extra.stringData or { }));

          # Keys that are public by definition of the Secret type.
          typePlainKeys =
            {
              "kubernetes.io/basic-auth" = [ "username" ];
              "kubernetes.io/tls" = [
                "tls.crt"
                "ca.crt"
              ];
            }
            .${type} or [ ];

          unknownPlain = builtins.filter (k: !(builtins.elem k valuedKeys)) plainKeys;
          _plainCheck =
            if unknownPlain == [ ] then
              null
            else
              fail {
                instance = builtBy;
                message = "mkSecret \"${name}\": plainKeys lists ${builtins.concatStringsSep ", " unknownPlain}, which has no value in stringData or extra.data. plainKeys marks a key whose value is written in the manifest and is not a credential.";
              };

          declaredKeys =
            if keys != null then
              keys
            else if valuedKeys != [ ] then
              valuedKeys
            else
              fail {
                instance = builtBy;
                message = "mkSecret \"${name}\": either 'keys' or 'stringData' must be provided.";
              };

          # Every key with a value must be declared, or the stamp and the
          # security.secretSource rule would miss it.
          undeclared = builtins.filter (k: !(builtins.elem k declaredKeys)) valuedKeys;
          _declaredCheck =
            if undeclared == [ ] then
              null
            else
              fail {
                instance = builtBy;
                message = "mkSecret \"${name}\": key(s) ${builtins.concatStringsSep ", " undeclared} have a value in stringData or extra.data but are not in 'keys'.";
                fix = "List every key the Secret holds, or omit 'keys' to derive them from the values.";
              };

          # Without a SOPS source nothing fills a key at deploy, so a key with
          # no value here would be missing from the live Secret. Kubernetes
          # fills a service-account-token Secret itself.
          unvalued = builtins.filter (k: !(builtins.elem k valuedKeys)) declaredKeys;
          effectiveKeys =
            if source != null || type == "kubernetes.io/service-account-token" || unvalued == [ ] then
              declaredKeys
            else
              fail {
                instance = builtBy;
                message = "mkSecret \"${name}\": key(s) ${builtins.concatStringsSep ", " unvalued} have no value and there is no SOPS source, so the Secret would be created without them and a pod that reads them would not start.";
                fix = "Give the values in stringData, set source to a SOPS file that holds them, or use scope.mkSecretRef when something outside Kix creates this Secret.";
              };

          # Return the value source for a declared key. Keys without an inline
          # value are populated by SOPS at deploy time, or by Kubernetes for
          # service-account tokens.
          sourceOf =
            k:
            if builtins.elem k valuedKeys then
              (if builtins.elem k plainKeys || builtins.elem k typePlainKeys then "plain" else "inline")
            else if source != null then
              "sops"
            else
              "controller";
          secretSources =
            if effectiveKeys == [ ] then
              "*=controller"
            else
              builtins.concatStringsSep "," (map (k: "${k}=${sourceOf k}") effectiveKeys);
          _sourceChecks = builtins.seq _plainCheck _declaredCheck;

          _hashCheck =
            if hash == null then
              null
            else
              fail {
                id = "K4732";
                instance = builtBy;
                message = "mkSecret \"${name}\": `hash` was removed. Kix now computes a digest of the SOPS file itself.";
                fix = "Delete the `hash` line.";
              };

          # A digest of the encrypted file, so the deploy can check that the
          # file it decrypts is the one this build read.
          digest = if source == null then null else builtins.hashFile "sha256" source;

          realizedSource =
            if source == null then
              null
            else
              builtins.path {
                path = source;
                # `builtins.path` requires a store path name without string context.
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
                ${kixKeys.secretKeys} = builtins.concatStringsSep "," effectiveKeys;
                ${kixKeys.secretSources} = builtins.seq _hashCheck (builtins.seq _sourceChecks secretSources);
              }
              // lib.optionalAttrs (source != null) {
                ${kixKeys.sopsSource} = toString realizedSource;
                ${kixKeys.sopsDigest} = digest;
              }
              // lib.optionalAttrs (meta ? classification) {
                ${kixKeys.classification} = meta.classification;
              }
              // lib.optionalAttrs (meta ? rotationPolicy) {
                ${kixKeys.rotationPolicy} = meta.rotationPolicy;
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
        resource
        // {
          out =
            resource.out
            // secretHelpers
            # A package that needs the value in a second namespace renders
            # another Secret from the same file (kix.contracts.secret).
            // lib.optionalAttrs (source != null) {
              sops = {
                inherit source digest;
                hash = fail {
                  id = "K4732";
                  instance = builtBy;
                  message = "mkSecret \"${name}\": `out.sops.hash` was removed.";
                  fix = "Read `out.sops.digest`, the SHA-256 of the encrypted file, instead.";
                };
              };
            };
        };

      # Reference a Secret created outside Kix. `keys` lists the keys that pods
      # read by name, and deployment waits until the live Secret contains each of
      # them. Use `keys = [ ]` only when pods mount or import the whole Secret
      # without referencing individual keys.
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
              fail {
                instance = builtBy;
                message = "mkSecretRef \"${name}\": 'keys' must be a list of strings (got ${builtins.typeOf keys}).";
              }
            else
              null;

          markerName = "secret-ref-${instanceName}-${name}";

          marker = builtins.seq _ (mkImportMarker {
            inherit markerName;
            importKind = "Secret";
            importApiVersion = "v1";
            importName = name;
            extraAnnotations = {
              ${kixKeys.secretType} = type;
            }
            // lib.optionalAttrs (keys != [ ]) {
              ${kixKeys.importSecretKeys} = builtins.concatStringsSep "," keys;
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
          # `metadata.labels` on the external Service, such as an operator's
          # `operated-prometheus = "true"`. ServiceMonitors select Services by
          # these labels, so monitors targeting this ref use `out.labels` and
          # `monitorSelectorMatchesService` reads them from the marker.
          labels ? { },
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
              ${kixKeys.serviceSelector} = builtins.toJSON selector;
              ${kixKeys.servicePorts} = builtins.toJSON ports;
            }
            // lib.optionalAttrs (labels != { }) {
              ${kixKeys.serviceLabels} = builtins.toJSON labels;
            };
            extraRequires = requires;
          };

          resourceCtx = builtins.getContext "${marker}";
          attachCtx = value: builtins.appendContext (toString value) resourceCtx;

          # Mint an endpoint fact from the declared selector and ports so network
          # policy analysis treats the ref like a managed Service.
          endpointFactCtx = k8s.facts.mkFact "endpoint" {
            inherit name selector ports;
            namespace = namespaceName;
          };
          attachConnectCtx = value: builtins.appendContext (toString value) (resourceCtx // endpointFactCtx);

          fqdn = "${name}.${namespaceName}.svc.${clusterDomain}";
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
            # Attach the marker's string context so monitors built from
            # `out.labels` depend on the ref.
            labels = lib.mapAttrs (_: v: attachCtx v) labels;
          };
        };
    };
}

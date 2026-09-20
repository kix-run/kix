{ lib, k8s }:

let
  # Kix's own annotation keys and API names, spelled once in
  # core/annotations.nix.
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
      # cluster.factBehavior, keyed "group/Kind": operator override (wins
      # over the CRD-declared behavior arriving via mkCR) and fallback for
      # builder-less CRs (helm-rendered, raw mkResource)
      factBehaviorOverrides ? { },
      # scopeObj is the enclosing mkScope fixpoint — only consume lazily (interceptor ctx, mkCR); forcing it while default.nix constructs it would recurse
      scopeObj,
    }:
    rec {
      # A workload is sealed by its typed builder only: mkDeployment,
      # mkStatefulSet, mkDaemonSet, mkJob and mkHelmWorkload run the pod-spec
      # validators, the edge analysis and the interceptors (derived spread,
      # netpol) before the seal. A raw mkResource of one of these kinds used
      # to skip all of that without a word, so it is refused; sealWorkload
      # reaches the seal through sealResource below.
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
          throw (
            "[${instanceName}] ${kind} '${args.name or "?"}' is built with scope.mkResource, which skips workload-specific processing: "
            + "pod validation, automatic replica placement and PodDisruptionBudgets, and network "
            + "policy dependencies. Build it with ${builderFor.${kind}} instead (drop apiVersion and kind; "
            + "keep the other attributes)."
          )
        else
          null;

      scopeMkResource = args: builtins.seq (checkNotRawWorkload args) (sealResource args);

      sealResource =
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
        builtins.seq (validators.checkResourceName args) (
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
          # `availability.max` on the builder call: the largest level this
          # one workload can honour, or null.
          workloadCeiling ? null,
        }:
        let
          # The instance ceiling (meta.availability.max) lowers every
          # workload alike, which misstates a package with one single-replica
          # controller beside a quorum store that wants hard spread (openebs,
          # housekeeping 2026-09-19). A ceiling on the builder call lowers
          # this workload only. The package's `availability` argument is not
          # lowered: a replica count mapped from it belongs to the workload
          # that maps it, and the capped workload is the one that does not.
          capped =
            workloadCeiling != null
            && availabilityLib.rank availability.level > availabilityLib.rank workloadCeiling;
          workloadAvailability =
            if capped then
              availability
              // {
                level = workloadCeiling;
                ceiling = workloadCeiling;
                capped = true;
                warnings = [ ];
              }
            else
              availability;
          ceilingWarnings = lib.optional capped (
            "${workloadKind} '${workloadInput.name or "?"}' declares availability.max = "
            + "\"${workloadCeiling}\", so it runs at \"${workloadCeiling}\" under availability "
            + "\"${availability.level}\". The rest of the instance is unaffected."
          );
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
              availability = workloadAvailability;
            }
          ) workloadInterceptors;
          interceptorRequires = builtins.concatMap (r: r.requires or [ ]) interceptorResults;
          interceptorResources = builtins.concatMap (r: r.resources or [ ]) interceptorResults;
          interceptorWarnings = builtins.concatMap (r: r.warnings or [ ]) interceptorResults;
          # podSpec patches land in spec.template.spec before the seal, so
          # they are part of the workload's store-path identity. Author
          # fields win per top-level pod-spec field; between interceptors
          # the earlier one (lower priority) wins, which keeps the merge
          # deterministic and therefore content-addressed.
          interceptorPodSpec = builtins.foldl' (acc: r: (r.podSpec or { }) // acc) { } interceptorResults;
          # The choice sits inside `spec`, not around the whole input.
          # Reading `rawSelector` off the returned workload forces this
          # value's weak head normal form, and deciding out here would run
          # every interceptor to do it: the netpol edge analysis walks the
          # pod spec, reaches the ConfigMap the pod mounts and from there the
          # Service that is asking for the selector in the first place. That
          # is the cycle BEST-PRACTICES §7.3 offers `rawSelector` as the
          # escape from, so the escape must not force the seal
          # (housekeeping 2026-09-18).
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
          # Splice order contract: author-declared requires, then plugin
          # requires, then core DNS deps. kix.run/depends-on stamps entries
          # in list order, so this order is content-addressed into the
          # manifest — change it only as a deliberate output change.
          workload = sealResource (
            removeAttrs patchedInput [ "_helmNetworkDeps" ]
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
            interceptorWarnings ++ map (w: "[${instanceName}] ${w}") (ceilingWarnings ++ edgeReport.warnings)
          );
          _injectedResources = interceptorResources;
          rawSelector = selector;
          # The level this workload was sealed at, for the instance
          # processors that judge it after the fact.
          _availability = workloadAvailability;
        };

      # The pod-spec validators are anchored on the workload's outPath, not
      # on the workload's own evaluation. Checking a pod spec walks it, and
      # a pod spec can reach a ConfigMap that names a Service that is
      # waiting for this workload's `rawSelector` — the cycle
      # BEST-PRACTICES §7.3 offers `rawSelector` as the escape from, which
      # only works if reading it seals nothing (housekeeping 2026-09-18).
      # Every resource in a build forces its outPath, so no check is
      # skipped; each one runs a moment later than it used to.
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
            spec.selector.matchLabels
              or (throw "mkWorkload (${kind}): spec.selector.matchLabels is required. Use scope.selectorLabels");
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

          # The workload's own metadata carries its selector labels, so a
          # workload describes itself the way every other tool reads it:
          # `app.kubernetes.io/name` lived only in the selector and the pod
          # template before, and `governance.labelStandards` fired on every
          # workload the typed builders produced. A package's own `labels`
          # still win.
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
            inherit selector hostNetwork;
            workloadCeiling = (attrs.availability or { }).max or null;
          });

      # A CronJob's pods are pods. It slipped past `mkResource`'s refusal
      # list, so `kix/packages/stackgres-pgpass-perms-fix` built one raw and
      # its pods got no pod-spec validators, no DNS ordering and no
      # network-policy edges. The only structural difference from a Job is
      # that the pod template sits one level deeper, under
      # `spec.jobTemplate.spec.template`, so the seal is handed that.
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

          # A CronJob has no selector of its own: the Jobs it creates get
          # one from the controller. The pod template's labels are the only
          # identity its pods carry, and the seal needs something to key the
          # network-policy edges on.
          selector =
            templateMeta.labels
              or (throw "mkCronJob: spec.jobTemplate.spec.template.metadata.labels is required. Use scope.selectorLabels");

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
            (validators.checkPrivileged templateSpec)
            (validators.checkNamespacedRefs templateSpec)
            (validators.checkContainerResources templateSpec)
            (validators.checkDuplicateNames templateSpec)
            (validators.checkFieldRefs templateSpec)
          ]
          (sealWorkload {
            workloadInput = baseArgs;
            workloadKind = kind;
            inherit selector hostNetwork;
            workloadCeiling = (attrs.availability or { }).max or null;
          });

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

          # Same as mkWorkload: the Job's metadata carries its selector.
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
            (validators.checkPrivileged templateSpec)
            (validators.checkNamespacedRefs templateSpec)
            (validators.checkContainerResources templateSpec)
            (validators.checkDuplicateNames templateSpec)
            (validators.checkFieldRefs templateSpec)
          ]
          (sealWorkload {
            workloadInput = baseArgs;
            workloadKind = kind;
            inherit selector hostNetwork;
            workloadCeiling = (attrs.availability or { }).max or null;
          });

      # Chart-rendered workloads get the same pod-spec validators as
      # mkWorkload: capability gates, selector within template labels,
      # probe port names, limits >= requests, duplicate names, fieldRef
      # paths. Not checkNamespacedRefs: it wants DI-tracked names, and a
      # chart's ConfigMap and Secret names are plain strings (the
      # cross-resource checks in eval/validate.nix resolve those instead).
      # Duplicate env names are allowed here (see checkDuplicateNamesChart).
      mkHelmWorkload =
        attrs:
        let
          kind = attrs.kind or (throw "mkHelmWorkload: kind is required");
          apiVersion = attrs.apiVersion or "apps/v1";
          rawSpec = attrs.spec or { };
          selector =
            rawSpec.selector.matchLabels or rawSpec.template.metadata.labels
              or (throw "mkHelmWorkload (${kind}): spec.selector.matchLabels or spec.template.metadata.labels is required");
          templateMeta = rawSpec.template.metadata or { };
          templateSpec = rawSpec.template.spec or { };
          hostNetwork = templateSpec.hostNetwork or false;

          # _helmNetworkDeps stays in workloadInput so edge detection sees its store-path context; sealWorkload strips it before mkResource
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
          crdSpec = attrs.spec or (throw "mkCRD: spec is required");
          labels = attrs.labels or { };
          annotations = attrs.annotations or { };
          crKind = crdSpec.names.kind;
          group = crdSpec.group;
          plural = crdSpec.names.plural;
          # The storage version, not the first listed one. A vendored CRD
          # carries every version upstream still serves, and upstream does
          # not always list the storage version first: cdi lists v1alpha1
          # before v1beta1, so a CR built from this CRD targeted a
          # deprecated version the operator was about to drop. The package
          # hid that by filtering the version out of the vendored file.
          # Falling back to the first entry keeps a single-version CRD and
          # any hand-written spec that omits the flag working.
          storageVersions = builtins.filter (v: v.storage or false) crdSpec.versions;
          version =
            if storageVersions != [ ] then
              (builtins.head storageVersions).name
            else
              (builtins.head crdSpec.versions).name;
          crdScope = crdSpec.scope or "Namespaced";
          factBehavior =
            if attrs ? factBehavior && attrs.factBehavior != null then
              k8s.facts.validateBehavior "mkCRD ${instanceName}" "${group}/${crKind}" attrs.factBehavior
            else
              null;
          # Forced via the seq below so a malformed declaration fails HERE,
          # at the declaring package's eval — not at the first CR build.
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
            inherit
              version
              crdScope
              factBehavior
              readiness
              ;
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
          apiVersion = kixAnnotations.apiVersion;
          kind = "PackageInstance";
          name = markerName;
          annotations = {
            ${kixKeys.mode} = "import";
            ${kixKeys.importKind} = importKind;
            ${kixKeys.importApiVersion} = importApiVersion;
            ${kixKeys.importName} = importName;
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
          # readiness convention of this kind's controller — see
          # mkCRDBuilders in core/resource.nix. Stamped on every CR built
          # via mkCR as the `kix.run/readiness` annotation. Validated
          # eagerly (seq'd into the marker) like factBehavior.
          readiness ? null,
        }:
        let
          _validatedReadiness = k8s.validateReadiness "mkCRDRef ${instanceName}" "${group}/${kind}" readiness;
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

          marker = builtins.seq _validatedReadiness (mkImportMarker {
            inherit markerName;
            importKind = "CustomResourceDefinition";
            importApiVersion = "apiextensions.k8s.io/v1";
            importName = crdName;
            extraRequires = installedByList;
          });

          crdBuilders = k8s.mkCRDBuilders {
            crdOrRef = marker;
            factBehavior = _validatedBehavior;
            readiness = _validatedReadiness;
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
                ${kixKeys.secretKeys} = builtins.concatStringsSep "," effectiveKeys;
              }
              // lib.optionalAttrs (source != null) {
                ${kixKeys.sopsSource} = toString realizedSource;
              }
              // lib.optionalAttrs (hash != null) {
                ${kixKeys.contentHash} = hash;
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
          # metadata.labels the external Service carries (an operator's
          # `operated-prometheus: "true"`, for example). A ServiceMonitor
          # selects Services by these, so a self-monitor over a ref builds
          # its selector from `out.labels`; the monitorSelectorMatchesService
          # rule reads them off the marker.
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

          # the ref knows selector+ports explicitly — mint the endpoint fact
          # from the declaration, same channel as a managed Service's seal
          endpointFactCtx = k8s.facts.mkFact "endpoint" {
            inherit name selector ports;
            namespace = namespaceName;
          };
          attachConnectCtx = value: builtins.appendContext (toString value) (resourceCtx // endpointFactCtx);

          # Same form as a rendered Service's out.fqdn (core/resource.nix):
          # the short `.svc` form resolved only through the pod's search path.
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
            # Values carry the marker's context so a monitor built from them
            # depends on the ref, as one built from out.selector used to.
            labels = lib.mapAttrs (_: v: attachCtx v) labels;
          };
        };
    };
}

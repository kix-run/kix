{ lib }:

let
  # Kix's own annotation keys and API names, spelled once in
  # core/annotations.nix.
  kixAnnotations = import ../../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  core = import ../../core/default.nix { inherit lib; };

  inherit (import ../../eval/edges.nix { k8s = core; })
    isWorkload
    getWorkloadSelector
    isService
    ;
in
{
  buildWorkloadCnps =
    {
      emit,
      instanceName,
      namespaceName,
      workloadInput,
      workloadKind,
      wSelector,
      hostNetwork,
      edges,
      networkConfig,
      packageIntents ? { },
      networkPolicyEnforcer ? null,
    }:
    let
      cnps =
        if networkPolicyEnforcer == null || hostNetwork then
          [ ]
        else
          let
            enforcerApi = networkPolicyEnforcer.netpol;

            directions = networkConfig.directions or "both";
            doEgress = directions == "both" || directions == "egress";
            doIngress = directions == "both" || directions == "ingress";

            intentRules =
              if packageIntents != { } then
                enforcerApi.translateIntentRules { intents = packageIntents; }
              else
                {
                  egressRules = [ ];
                  ingressRules = [ ];
                };

            serviceRules = map (
              edge:
              enforcerApi.mkServiceEgressRule {
                selector = edge.targetSelector;
                namespace = edge.targetNamespace;
                sourceNamespace = namespaceName;
                ports = edge.ports;
              }
            ) edges;

            selfRules = enforcerApi.mkSelfRules { selector = wSelector; };
            selfEgress = lib.optional (workloadKind == "StatefulSet") (builtins.head selfRules.egress);

            egressRules = [
              enforcerApi.dnsEgressRule
            ]
            ++ serviceRules
            ++ selfEgress
            ++ intentRules.egressRules;

            selfIngress = lib.optional (workloadKind == "StatefulSet") (builtins.head selfRules.ingress);

            ingressRules = selfIngress ++ intentRules.ingressRules;

            wName = workloadInput.name or (throw "buildWorkloadCnps: workloadInput.name is required");

            # edges discovered through indirection or import-mode refs have
            # no producing resource in scope (service = null); the CNP's
            # ordering after the Service still holds via store-DAG
            # transitivity where a resource exists at all
            serviceDeps = builtins.filter (s: s != null) (map (e: e.service) edges);

            egressCnp =
              if !doEgress then
                null
              else
                enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower workloadKind}-${wName}-egress";
                    labels = {
                      ${kixKeys.derived} = "true";
                    };
                    spec = {
                      endpointSelector.matchLabels = wSelector;
                      egress = egressRules;
                    };
                    extraDeps = serviceDeps;
                  };
                };

            ingressCnp =
              if !doIngress || ingressRules == [ ] then
                null
              else
                enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower workloadKind}-${wName}-ingress";
                    labels = {
                      ${kixKeys.derived} = "true";
                    };
                    spec = {
                      endpointSelector.matchLabels = wSelector;
                      ingress = ingressRules;
                    };
                    extraDeps = [ ];
                  };
                };

            callerIngressCnps =
              if !doIngress then
                [ ]
              else
                map (
                  edge:
                  let
                    targetEmit = emit.inNamespace edge.targetNamespace;
                    ingressRule = enforcerApi.mkCallerIngressRule {
                      callerSelector = wSelector;
                      callerNamespace = namespaceName;
                      ports = edge.ports;
                    };
                  in
                  enforcerApi.mkPolicy {
                    mkResource = targetEmit.mkResource;
                    extraArgs = {
                      name = "${instanceName}-${lib.toLower workloadKind}-${wName}-to-${edge.name}-ingress";
                      labels = {
                        ${kixKeys.derived} = "true";
                        ${kixKeys.policyType} = "caller-ingress";
                      };
                      spec = {
                        endpointSelector.matchLabels = edge.targetSelector;
                        ingress = [ ingressRule ];
                      };
                      extraDeps = lib.optional (edge.service != null) edge.service;
                    };
                  }
                ) edges;

          in
          builtins.filter (c: c != null) (
            [
              egressCnp
              ingressCnp
            ]
            ++ callerIngressCnps
          );

    in
    {
      inherit cnps;
    };

  processInstance =
    {
      emit,
      instanceName,
      allPartResources,
      networkConfig,
      packageMeta,
      networkPolicyEnforcer ? null,
    }:
    let
      # left lazy: self-enforcer instances arrive with a null enforcer but must still produce warnings
      enforcerApi = networkPolicyEnforcer.netpol;

      directions = networkConfig.directions or "both";
      doEgress = directions == "both" || directions == "egress";
      doIngress = directions == "both" || directions == "ingress";

      workloads = builtins.filter isWorkload allPartResources;

      hostNetworkWorkloads = builtins.filter (
        w: w.rawManifest.spec.template.spec.hostNetwork or false
      ) workloads;

      bindings = builtins.filter (
        r:
        builtins.elem (r.kind or "") [
          "RoleBinding"
          "ClusterRoleBinding"
        ]
      ) allPartResources;

      boundSAKeys = builtins.concatMap (
        b:
        let
          subjects = b.rawManifest.subjects or [ ];
          bindingNs = b.rawManifest.metadata.namespace or null;
        in
        builtins.filter (k: k != null) (
          map (
            s:
            if (s.kind or "") == "ServiceAccount" then
              let
                ns = s.namespace or bindingNs;
                saName = s.name or null;
              in
              if ns == null || saName == null then null else "${ns}/${saName}"
            else
              null
          ) subjects
        )
      ) bindings;

      workloadNeedsApiserver =
        w:
        let
          saName = w.rawManifest.spec.template.spec.serviceAccountName or "default";
          wNs = w.rawManifest.metadata.namespace or null;
        in
        wNs != null && builtins.elem "${wNs}/${saName}" boundSAKeys;

      needsExternalIngress = builtins.any (
        r: isService r && (r.rawManifest.spec.type or "") == "LoadBalancer"
      ) allPartResources;

      apiServerSupplementPolicies =
        if !doEgress then
          [ ]
        else
          builtins.concatMap (
            w:
            let
              wSelector = getWorkloadSelector w;
              isHostNet = w.rawManifest.spec.template.spec.hostNetwork or false;
            in
            if isHostNet || !(workloadNeedsApiserver w) then
              [ ]
            else
              [
                (enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower w.kind}-${w.name}-apiserver-egress";
                    labels = {
                      ${kixKeys.derived} = "true";
                      ${kixKeys.policyType} = "apiserver-supplement";
                    };
                    spec = {
                      endpointSelector.matchLabels = wSelector;
                      egress = [ enforcerApi.apiServerEgressRule ];
                    };
                    extraDeps = [ ];
                  };
                })
              ]
          ) workloads;

      externalIngressSupplementPolicies =
        if !doIngress || !needsExternalIngress then
          [ ]
        else
          builtins.concatMap (
            w:
            let
              wSelector = getWorkloadSelector w;
              isHostNet = w.rawManifest.spec.template.spec.hostNetwork or false;
            in
            if isHostNet then
              [ ]
            else
              [
                (enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower w.kind}-${w.name}-external-ingress";
                    labels = {
                      ${kixKeys.derived} = "true";
                      ${kixKeys.policyType} = "external-ingress-supplement";
                    };
                    spec = {
                      endpointSelector.matchLabels = wSelector;
                      ingress = [
                        (enforcerApi.mkExternalIngressRule {
                          entities = packageMeta.network.externalIngressEntities or [ "world" ];
                        })
                      ];
                    };
                    extraDeps = [ ];
                  };
                })
              ]
          ) workloads;

      # terminate-declared CRs (meta.factBehavior): the controller dials the
      # endpoints absorbed by the CR spec, so the holes open for the OPERAND
      # pods named by the declaration's podSelector. The CR has no pods of
      # its own and never went through sealWorkload.
      # the resolved behavior rides on the resource itself (threaded through
      # the CRD builder chain or the cluster override at seal time, with no
      # index lookup needed here
      #
      # The policies do not require the CR. A CR whose readiness needs the
      # connection (a Velero BackupStorageLocation is Available only once
      # its store answers) would otherwise wait for policies that wait for
      # it, until the deploy times out.
      terminatingCrs =
        # Self-enforcer instances arrive with a null enforcer, so no policies
        if networkPolicyEnforcer == null then
          [ ]
        else
          builtins.filter (
            r:
            ((r.factBehavior or null) != null)
            && (r.factBehavior.endpoint or "") == "terminate"
            && (r.absorbedEndpointFacts or [ ]) != [ ]
          ) allPartResources;

      operandPolicies = builtins.concatMap (
        r:
        let
          beh = r.factBehavior;
          operandSelector =
            if builtins.isFunction beh.podSelector then beh.podSelector r.rawManifest else beh.podSelector;
          crNamespace = core.nsOf r;

          crEdges = map (f: {
            inherit (f.payload) name ports;
            targetSelector = f.payload.selector;
            targetNamespace = f.payload.namespace;
          }) r.absorbedEndpointFacts;

          egressCnp =
            if !doEgress then
              [ ]
            else
              [
                (enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower r.kind}-${r.name}-egress";
                    labels = {
                      ${kixKeys.derived} = "true";
                      ${kixKeys.policyType} = "cr-operand";
                    };
                    spec = {
                      endpointSelector.matchLabels = operandSelector;
                      egress = [
                        enforcerApi.dnsEgressRule
                      ]
                      ++ map (
                        edge:
                        enforcerApi.mkServiceEgressRule {
                          selector = edge.targetSelector;
                          namespace = edge.targetNamespace;
                          sourceNamespace = crNamespace;
                          ports = edge.ports;
                        }
                      ) crEdges;
                    };
                    extraDeps = [ ];
                  };
                })
              ];

          callerIngressCnps =
            if !doIngress then
              [ ]
            else
              map (
                edge:
                enforcerApi.mkPolicy {
                  mkResource = (emit.inNamespace edge.targetNamespace).mkResource;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower r.kind}-${r.name}-to-${edge.name}-ingress";
                    labels = {
                      ${kixKeys.derived} = "true";
                      ${kixKeys.policyType} = "caller-ingress";
                    };
                    spec = {
                      endpointSelector.matchLabels = edge.targetSelector;
                      ingress = [
                        (enforcerApi.mkCallerIngressRule {
                          callerSelector = operandSelector;
                          callerNamespace = crNamespace;
                          ports = edge.ports;
                        })
                      ];
                    };
                    extraDeps = [ ];
                  };
                }
              ) crEdges;
        in
        egressCnp ++ callerIngressCnps
      ) terminatingCrs;

      warnings =
        map (
          w:
          "[${instanceName}] workload '${w.kind}/${w.name}' uses hostNetwork, so CiliumNetworkPolicy does not control its traffic. Review network access on the host"
        ) hostNetworkWorkloads
        ++
          lib.optional (packageMeta.isHelm or false)
            "[${instanceName}] Kix may not detect every connection between workloads in this Helm chart. Review the generated network policies and add any missing rules";

    in
    {
      policies = apiServerSupplementPolicies ++ externalIngressSupplementPolicies ++ operandPolicies;
      inherit warnings;
    };

  generateDefaultDeny =
    {
      namespaceName,
      nsResource,
      directions,
      networkPolicyEnforcer ? null,
    }:
    let
      enforcerApi = networkPolicyEnforcer.netpol;
      denyIngress = directions == "both" || directions == "ingress";
      denyEgress = directions == "both" || directions == "egress";
    in
    enforcerApi.mkPolicy {
      mkResource = core.mkResource;
      extraArgs = {
        name = "${namespaceName}-default-deny";
        namespace = nsResource;
        labels = {
          ${kixKeys.derived} = "true";
          ${kixKeys.policyType} = "default-deny";
          "app.kubernetes.io/managed-by" = "kix";
        };
        spec = enforcerApi.mkDefaultDenySpec {
          inherit denyIngress denyEgress;
        };
      };
    };

  materializePlatformIntents =
    {
      networkConfig,
      networkPolicyEnforcer ? null,
      nsResources,
    }:
    if
      !networkConfig.enable || networkPolicyEnforcer == null || networkConfig.platformIntents == { }
    then
      [ ]
    else
      let
        enforcerApi = networkPolicyEnforcer.netpol;
      in
      lib.mapAttrsToList (
        intentName: intent:
        let
          nsName = intent.namespace or null;
          namespaceResource =
            if nsName != null && builtins.hasAttr nsName nsResources then nsResources.${nsName} else null;
        in
        enforcerApi.materializePlatformIntent {
          intent = intent // {
            name = intentName;
          };
          # Platform intents target pods outside any kix scope, so they are
          # sealed with the bare core constructor, which stamps no labels.
          # Mark them kix-managed here, once, whatever the enforcer is: the
          # cross-resource checks require the label and gc/health key on it.
          mkResource =
            args:
            core.mkResource (
              args
              // {
                labels = (args.labels or { }) // {
                  "app.kubernetes.io/managed-by" = "kix";
                };
              }
            );
          inherit namespaceResource;
          inherit (core) clusterScoped;
        }
      ) networkConfig.platformIntents;
}

{ lib }:

let
  inherit (import ../../core/error.nix { inherit lib; }) fail;
  kixAnnotations = import ../../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
  core = import ../../core/default.nix { inherit lib; };

  inherit
    (import ../../eval/edges.nix {
      inherit lib;
      k8s = core;
    })
    isWorkload
    getWorkloadSelector
    isService
    ;
  inherit (import ../../core/markers.nix { inherit lib; }) isProvidedLoadBalancerClass;
  inherit (import ../../core/pod-spec.nix { inherit lib; }) podSpecOf;
  inherit (import ./interface.nix { inherit lib; }) checkEntities checkIntentEntities;
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
      enforced,
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

            intentRules =
              if packageIntents != { } then
                enforcerApi.translateIntentRules {
                  intents = checkIntentEntities "${namespaceName}/${instanceName}: meta.network.intents" packageIntents;
                }
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

            wName = workloadInput.name or (fail "buildWorkloadCnps: workloadInput.name is required");

            # Edges from ServiceRef markers or indirect references have
            # `service = null`. When a backing Service resource exists,
            # store-path context still orders the policy after it.
            serviceDeps = builtins.filter (s: s != null) (map (e: e.service) edges);

            egressCnp =
              if !enforced.egress then
                null
              else
                enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  selector = wSelector;
                  egress = egressRules;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower workloadKind}-${wName}-egress";
                    labels = {
                      ${kixKeys.derived} = "true";
                    };
                    extraDeps = serviceDeps;
                  };
                };

            ingressCnp =
              if !enforced.ingress || ingressRules == [ ] then
                null
              else
                enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  selector = wSelector;
                  ingress = ingressRules;
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower workloadKind}-${wName}-ingress";
                    labels = {
                      ${kixKeys.derived} = "true";
                    };
                    extraDeps = [ ];
                  };
                };

            callerIngressCnps =
              if !enforced.ingress then
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
                    selector = edge.targetSelector;
                    ingress = [ ingressRule ];
                    extraArgs = {
                      name = "${instanceName}-${lib.toLower workloadKind}-${wName}-to-${edge.name}-ingress";
                      labels = {
                        ${kixKeys.derived} = "true";
                        ${kixKeys.policyType} = "caller-ingress";
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
      namespaceName,
      allPartResources,
      enforced,
      packageMeta,
      networkPolicyEnforcer ? null,
    }:
    let
      # Keep lazy because the enforcer instance itself has
      # `networkPolicyEnforcer = null` while still running warning checks.
      enforcerApi = networkPolicyEnforcer.netpol;

      workloads = builtins.filter isWorkload allPartResources;

      hostNetworkWorkloads = builtins.filter (
        w: (podSpecOf w.rawManifest).hostNetwork or false
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
          saName = (podSpecOf w.rawManifest).serviceAccountName or "default";
          wNs = w.rawManifest.metadata.namespace or null;
        in
        wNs != null && builtins.elem "${wNs}/${saName}" boundSAKeys;

      # A LoadBalancer Service served by a provider in the build (its class
      # comes from kix.providedLoadBalancerClass) is reached from that
      # provider's pods, which open the backend themselves, not from outside
      # the cluster.
      needsExternalIngress = builtins.any (
        r:
        isService r
        && (r.rawManifest.spec.type or "") == "LoadBalancer"
        && !(isProvidedLoadBalancerClass (r.rawManifest.spec.loadBalancerClass or null))
      ) allPartResources;

      apiServerSupplementPolicies =
        if !enforced.egress then
          [ ]
        else
          builtins.concatMap (
            w:
            let
              wSelector = getWorkloadSelector w;
              isHostNet = (podSpecOf w.rawManifest).hostNetwork or false;
            in
            if isHostNet || !(workloadNeedsApiserver w) then
              [ ]
            else
              [
                (enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  selector = wSelector;
                  egress = [ enforcerApi.apiServerEgressRule ];
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower w.kind}-${w.name}-apiserver-egress";
                    labels = {
                      ${kixKeys.derived} = "true";
                      ${kixKeys.policyType} = "apiserver-supplement";
                    };
                    extraDeps = [ ];
                  };
                })
              ]
          ) workloads;

      externalIngressSupplementPolicies =
        if !enforced.ingress || !needsExternalIngress then
          [ ]
        else
          builtins.concatMap (
            w:
            let
              wSelector = getWorkloadSelector w;
              isHostNet = (podSpecOf w.rawManifest).hostNetwork or false;
            in
            if isHostNet then
              [ ]
            else
              [
                (enforcerApi.mkPolicy {
                  mkResource = emit.mkResource;
                  selector = wSelector;
                  ingress = [
                    (enforcerApi.mkExternalIngressRule {
                      entities = checkEntities "${namespaceName}/${instanceName}: meta.network.externalIngressEntities" (
                        packageMeta.network.externalIngressEntities or [ "world" ]
                      );
                    })
                  ];
                  extraArgs = {
                    name = "${instanceName}-${lib.toLower w.kind}-${w.name}-external-ingress";
                    labels = {
                      ${kixKeys.derived} = "true";
                      ${kixKeys.policyType} = "external-ingress-supplement";
                    };
                    extraDeps = [ ];
                  };
                })
              ]
          ) workloads;

      # For custom resources with `factBehavior.endpoint = "terminate"`, the
      # operator's operand pods dial the endpoints referenced in the CR spec.
      # Open egress on the operand pods selected by `factBehavior.podSelector`
      # and caller ingress on the targets. These policies do not depend on the
      # CR because the CR may require the network path to become Ready.
      terminatingCrs =
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
          # `podNamespace` names where the operand pods run when that is not
          # the custom resource's namespace (a controller in its own
          # namespace serving every namespace, or a cluster-scoped kind).
          operandNamespace =
            if !(beh ? podNamespace) then
              crNamespace
            else if builtins.isFunction beh.podNamespace then
              beh.podNamespace r.rawManifest
            else
              beh.podNamespace;
          # A policy placed in another namespace carries this instance's
          # namespace in its name, so two instances of one name in different
          # namespaces do not collide there.
          policyPrefix =
            if operandNamespace == namespaceName then instanceName else "${namespaceName}-${instanceName}";

          crEdges = map (f: {
            inherit (f.payload) name ports;
            targetSelector = f.payload.selector;
            targetNamespace = f.payload.namespace;
          }) r.absorbedEndpointFacts;

          egressCnp =
            if !enforced.egress then
              [ ]
            else
              [
                (enforcerApi.mkPolicy {
                  mkResource =
                    if operandNamespace == namespaceName then
                      emit.mkResource
                    else
                      (emit.inNamespace operandNamespace).mkResource;
                  selector = operandSelector;
                  egress = [
                    enforcerApi.dnsEgressRule
                  ]
                  ++ map (
                    edge:
                    enforcerApi.mkServiceEgressRule {
                      selector = edge.targetSelector;
                      namespace = edge.targetNamespace;
                      sourceNamespace = operandNamespace;
                      ports = edge.ports;
                    }
                  ) crEdges;
                  extraArgs = {
                    name = "${policyPrefix}-${lib.toLower r.kind}-${r.name}-egress";
                    labels = {
                      ${kixKeys.derived} = "true";
                      ${kixKeys.policyType} = "cr-operand";
                    };
                    extraDeps = [ ];
                  };
                })
              ];

          callerIngressCnps =
            if !enforced.ingress then
              [ ]
            else
              map (
                edge:
                enforcerApi.mkPolicy {
                  mkResource = (emit.inNamespace edge.targetNamespace).mkResource;
                  selector = edge.targetSelector;
                  ingress = [
                    (enforcerApi.mkCallerIngressRule {
                      callerSelector = operandSelector;
                      callerNamespace = operandNamespace;
                      ports = edge.ports;
                    })
                  ];
                  extraArgs = {
                    name = "${policyPrefix}-${lib.toLower r.kind}-${r.name}-to-${edge.name}-ingress";
                    labels = {
                      ${kixKeys.derived} = "true";
                      ${kixKeys.policyType} = "caller-ingress";
                    };
                    extraDeps = [ ];
                  };
                }
              ) crEdges;
        in
        egressCnp ++ callerIngressCnps
      ) terminatingCrs;

      warnings =
        map (w: {
          object = { inherit (w) kind name; };
          message = "${w.kind}/${w.name} uses hostNetwork, so CiliumNetworkPolicy does not filter its traffic.";
          fix = "Restrict access to its ports on the node's host network.";
        }) hostNetworkWorkloads
        ++
          lib.optional (packageMeta.isHelm or false)
            "Kix may not detect every connection between workloads in this Helm chart. Review the generated network policies and add any missing rules";

    in
    {
      policies = apiServerSupplementPolicies ++ externalIngressSupplementPolicies ++ operandPolicies;
      inherit warnings;
    };

  generateDefaultDeny =
    {
      namespaceName,
      nsResource,
      enforced,
      networkPolicyEnforcer ? null,
    }:
    let
      enforcerApi = networkPolicyEnforcer.netpol;
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
          denyIngress = enforced.ingress;
          denyEgress = enforced.egress;
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
          intent =
            (checkIntentEntities "networkPolicy.platformIntents.${intentName}" { single = intent; }).single
            // {
              name = intentName;
            };
          # Platform intents target pods outside any Kix scope and use the bare
          # core constructor, which does not add scope labels. Add
          # `managed-by = "kix"` here because cross-resource checks, garbage
          # collection, and health checks require it.
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

# The network-policy enforcer rules of the cilium package: CiliumNetworkPolicy
# and CiliumClusterwideNetworkPolicy rule shapes (toEndpoints/fromEndpoints
# with matchLabels, toEntities/fromEntities for identities, and Cilium's
# k8s:-prefixed namespace label).
#
# Contract: kix/lib/plugins/netpol/interface.nix. `mkNetpolOut` binds the
# rules to the package's two CRD references and is what `out.netpol` holds.

{ lib }:

let
  failWith = (import ../../../lib/core/error.nix { inherit lib; }).fail;
  inherit (import ../../../lib/plugins/netpol/interface.nix { inherit lib; })
    checkEntities
    defaultDnsPeers
    ;

  # Return the rule set with the DNS rule built for `dnsPeers`.
  mkRules = dnsPeers: rec {
    # The kinds this enforcer emits. Rules that look for a policy in a
    # namespace accept these alongside the Kubernetes NetworkPolicy.
    policyKinds = [
      "CiliumNetworkPolicy"
      "CiliumClusterwideNetworkPolicy"
    ];

    # The cilium operator reports Valid=True once it has accepted a policy;
    # it sets no Ready or Available condition. Valid=False is its verdict on
    # the policy's rules, which it reaches again only when the policy
    # changes, so the deploy stops waiting as soon as it sees one. Declared
    # on the CRD refs so every policy carries it as the `kix.run/readiness`
    # annotation.
    policyReadiness = {
      condition = {
        type = "Valid";
        status = "True";
      };
      failed = [
        {
          condition = {
            type = "Valid";
            status = "False";
          };
        }
      ];
    };

    # Build a network-policy resource routed through the CNP CRD ref.
    # mkResource is the caller's scope.mkResource or k8s.mkResource.
    # `selector` is the matchLabels of the pods the policy selects, and
    # `ingress` and `egress` are rules from this contract's builders. An
    # empty list writes no section for that direction. Without `selector`,
    # `extraArgs.spec` is the whole Cilium spec, as `mkDefaultDenySpec`
    # builds it.
    mkPolicy =
      {
        crdRef,
        mkResource,
        extraArgs,
        selector ? null,
        ingress ? [ ],
        egress ? [ ],
      }:
      mkResource (
        crdRef.out.cr (
          if selector == null then
            extraArgs
          else if extraArgs ? spec then
            failWith {
              package = "cilium";
              message = "CiliumNetworkPolicy '${extraArgs.name or "<unnamed>"}' sets both `selector` and `extraArgs.spec`, so Kix rejected it.";
              fix = "Remove `extraArgs.spec` and pass rules in `ingress` and `egress` alongside `selector`.";
            }
          else
            extraArgs
            // {
              spec = {
                endpointSelector.matchLabels = selector;
              }
              // lib.optionalAttrs (ingress != [ ]) { inherit ingress; }
              // lib.optionalAttrs (egress != [ ]) { inherit egress; };
            }
        )
      );

    # Spec for a default-deny policy. One empty rule per direction: it
    # matches no peer, so the selected endpoints go into default deny for
    # that direction with nothing allowed. An empty list is not the same
    # thing: cilium 1.19 rejects it ("rule must have at least one of
    # Ingress, IngressDeny, Egress, EgressDeny") and enforces nothing.
    mkDefaultDenySpec =
      {
        denyIngress,
        denyEgress,
      }:
      {
        endpointSelector = { };
      }
      // lib.optionalAttrs denyIngress { ingress = [ { } ]; }
      // lib.optionalAttrs denyEgress { egress = [ { } ]; };

    # DNS egress: allow UDP+TCP 53 to the DNS pods. Cilium refuses a rule
    # that combines `toEndpoints` with `toCIDR`, and callers take this as
    # one rule, so a peer given by address is refused here.
    dnsEgressRule =
      let
        cidrPeers = builtins.filter (p: p ? cidr) dnsPeers;
        podPeers = builtins.filter (p: p ? podSelector) dnsPeers;
      in
      if cidrPeers != [ ] then
        failWith {
          package = "cilium";
          message = "The cluster's DNS peers (`meta.dnsPeers` of the `dns` provider) include IP ranges (${
            lib.concatMapStringsSep ", " (p: p.cidr) cidrPeers
          }). The `cilium` enforcer writes the DNS egress rule as one Cilium rule, and Cilium refuses a rule that combines pod selectors with IP ranges, so Kix stopped evaluation.";
          fix = "Replace the `{ cidr = ...; }` entries in the `dns` provider's `meta.dnsPeers` with pod selectors (`{ namespace = \"...\"; podSelector = { ... }; }`), or leave `meta.dnsPeers` unset to allow `k8s-app = \"kube-dns\"` pods in `kube-system`.";
        }
      else
        {
          toEndpoints = map (p: {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = p.namespace;
            }
            // p.podSelector;
          }) podPeers;
          toPorts = dnsToPorts;
        };

    dnsToPorts = [
      {
        ports = [
          {
            port = "53";
            protocol = "UDP";
          }
          {
            port = "53";
            protocol = "TCP";
          }
        ];
      }
    ];

    # API server egress: Cilium identity entity.
    # `host`/`remote-node` alongside `kube-apiserver`: when the apiserver is
    # host-networked (e.g. single-node k3s), its IP is the node IP, which
    # Cilium resolves to the reserved `host` identity (or `remote-node` for
    # other nodes) rather than `kube-apiserver`. Without these, a
    # default-deny CNP drops pod→apiserver traffic on such clusters
    # ("Policy denied" to host in `cilium monitor`).
    apiServerEgressRule = {
      toEntities = [
        "kube-apiserver"
        "remote-node"
        "host"
      ];
    };

    # External ingress (world / custom entities). Kix's entity names are
    # Cilium's, so they pass through unchanged.
    mkExternalIngressRule =
      {
        entities ? [ "world" ],
      }:
      {
        fromEntities = checkEntities "An external ingress rule" entities;
      };

    # External egress (world / custom entities).
    mkExternalEgressRule =
      {
        entities ? [ "world" ],
      }:
      {
        toEntities = checkEntities "An external egress rule" entities;
      };

    # Egress to a Service's backing pods.
    # Cross-namespace: stamps k8s:io.kubernetes.pod.namespace on the selector.
    mkServiceEgressRule =
      {
        selector,
        namespace,
        sourceNamespace,
        ports,
      }:
      let
        sel =
          if namespace == sourceNamespace then
            selector
          else
            selector
            // {
              "k8s:io.kubernetes.pod.namespace" = namespace;
            };
        cp = portsToCilium ports;
      in
      {
        toEndpoints = [ { matchLabels = sel; } ];
      }
      // lib.optionalAttrs (cp != [ ]) { toPorts = [ { ports = cp; } ]; };

    # Egress to host-network pods on any node. Cilium gives a node's
    # address the `host` identity on that node and `remote-node` elsewhere.
    mkHostNetworkEgressRule =
      { ports }:
      let
        cp = portsToCilium ports;
      in
      {
        toEntities = [
          "host"
          "remote-node"
        ];
      }
      // lib.optionalAttrs (cp != [ ]) { toPorts = [ { ports = cp; } ]; };

    # Self-communication rules for StatefulSet peer traffic.
    mkSelfRules =
      { selector }:
      {
        egress = [
          { toEndpoints = [ { matchLabels = selector; } ]; }
        ];
        ingress = [
          { fromEndpoints = [ { matchLabels = selector; } ]; }
        ];
      };

    # Ingress from a specific caller workload (inverted cross-namespace ingress).
    # Cilium resolves a named port on the receiving pod, so names pass
    # through here without the warning portsToCilium gives.
    mkCallerIngressRule =
      {
        callerSelector,
        callerNamespace,
        ports,
      }:
      let
        # Without a namespace Cilium matches the policy's own namespace
        # only, so a caller in any namespace is selected with Exists.
        fromEndpoint =
          if callerNamespace == null then
            {
              matchLabels = callerSelector;
              matchExpressions = [
                {
                  key = "k8s:io.kubernetes.pod.namespace";
                  operator = "Exists";
                }
              ];
            }
          else
            {
              matchLabels = callerSelector // {
                "k8s:io.kubernetes.pod.namespace" = callerNamespace;
              };
            };
        cp = ingressPortsToCilium ports;
      in
      {
        fromEndpoints = [ fromEndpoint ];
      }
      // lib.optionalAttrs (cp != [ ]) { toPorts = [ { ports = cp; } ]; };

    # Convert K8s Service ports to Cilium toPorts format.
    # Uses targetPort (pod port), not port (service port).
    # A named port here is a policy that drops traffic: cilium resolves
    # names on ingress rules but not on egress ones (verified on 1.19), and
    # the same port list feeds both. Services from `kix.service.fromWorkload`
    # arrive numeric; a Service defined directly with `targetPort = "http"`
    # gets this warning and its consumers get no egress.
    portsToCilium =
      ports:
      builtins.filter (p: p != null) (
        map (
          p:
          let
            tp = p.targetPort or p.port or null;
          in
          if tp == null then
            null
          else if builtins.isString tp && builtins.match "[0-9]+" tp == null then
            # A warning so the rule still renders; Cilium drops egress on a named port, so the
            # traffic is blocked at runtime. Candidate for an evaluation error.
            lib.warn
              "kix netpol: port '${tp}' is a name, and cilium drops egress on a named port; use the container port number as targetPort (numbers are what kix.service.fromWorkload writes)"
              {
                port = tp;
                protocol = p.protocol or "TCP";
              }
          else
            {
              port = toString tp;
              protocol = p.protocol or "TCP";
            }
        ) ports
      );

    # portsToCilium for an ingress rule, where a named port is valid.
    ingressPortsToCilium =
      ports:
      builtins.filter (p: p != null) (
        map (
          p:
          let
            tp = p.targetPort or p.port or null;
          in
          if tp == null then
            null
          else
            {
              port = toString tp;
              protocol = p.protocol or "TCP";
            }
        ) ports
      );

    # Wrap matchLabels into Cilium's endpointSelector.
    mkEndpointSelector = matchLabels: { endpointSelector.matchLabels = matchLabels; };

    # Translate declarative intent rules to Cilium-native rules.
    translateIntentRules =
      { intents }:
      let
        translateEgressRule =
          rule:
          let
            target =
              rule.to or (failWith {
                package = "cilium";
                message = "An egress intent rule must have a `to` field.";
              });
            baseRule =
              if target == "apiserver" then
                apiServerEgressRule
              else if target == "world" then
                mkExternalEgressRule { entities = rule.entities or [ "world" ]; }
              else if target == "dns" then
                dnsEgressRule
              # Cilium's `cluster` entity: every pod, and also the nodes
              # (host, remote-node) and the API server on them.
              else if target == "all-pods" then
                { toEntities = [ "cluster" ]; }
              # Pods only: an endpoint selector that matches any namespace.
              # Host-network pods and the nodes carry no namespace label, so
              # it leaves out the API server, the kubelet, and NodePorts.
              else if target == "pods" then
                {
                  toEndpoints = [
                    {
                      matchExpressions = [
                        {
                          key = "k8s:io.kubernetes.pod.namespace";
                          operator = "Exists";
                        }
                      ];
                    }
                  ];
                }
              else
                failWith {
                  package = "cilium";
                  message = "unknown egress intent target '${toString target}'.";
                  fix = "Set `to` to \"apiserver\", \"world\", \"dns\", \"pods\", \"all-pods\", or \"node-local\".";
                };
            withPorts =
              r:
              r
              // lib.optionalAttrs (rule ? ports) {
                toPorts = [
                  {
                    ports = portsToCilium rule.ports;
                  }
                ];
              };
          in
          if target == "dns" then
            [ baseRule ] # DNS rule already includes ports
          # An address on the pod's own node, such as a cloud metadata
          # server. Cilium matched node-bound link-local addresses with
          # `toCIDR` through 1.16 and gives them the `host` identity from
          # 1.17, so both rules are written. Cilium refuses one rule that
          # holds both.
          else if target == "node-local" then
            [
              (withPorts {
                toCIDR = [
                  (rule.cidr or (failWith {
                    package = "cilium";
                    message = "Egress intent rule with `to = \"node-local\"` is missing `cidr`, so Kix could not build the rule.";
                    fix = "Add `cidr` with the node-local IP range, such as `cidr = \"169.254.169.254/32\";`.";
                  })
                  )
                ];
              })
              (withPorts { toEntities = [ "host" ]; })
            ]
          else
            [ (withPorts baseRule) ];

        translateIngressRule =
          rule:
          let
            source =
              rule.from or (failWith {
                package = "cilium";
                message = "An ingress intent rule must have a `from` field.";
              });
            baseRule =
              if source == "all-pods" then
                { fromEntities = [ "cluster" ]; }
              else if source == "world" then
                mkExternalIngressRule { entities = rule.entities or [ "world" ]; }
              # The apiserver calling an admission webhook or an aggregated
              # API. The entities match apiServerEgressRule's, since a
              # host-networked apiserver arrives as `host` or `remote-node`.
              else if source == "apiserver" then
                { fromEntities = apiServerEgressRule.toEntities; }
              else
                failWith {
                  package = "cilium";
                  message = "Unknown ingress intent source '${toString source}'. The sources are all-pods, world, and apiserver.";
                };
          in
          baseRule
          // lib.optionalAttrs (rule ? ports) {
            toPorts = [
              {
                ports = portsToCilium rule.ports;
              }
            ];
          };

        allIntents = builtins.attrValues intents;
      in
      {
        egressRules = builtins.concatMap (
          i: builtins.concatMap translateEgressRule (i.egress or [ ])
        ) allIntents;
        ingressRules = builtins.concatMap (i: map translateIngressRule (i.ingress or [ ])) allIntents;
      };
  };

  rules = mkRules defaultDnsPeers;

  # Return the enforcer contract for `dnsPeers`, bound to the CRD references.
  mkBound =
    {
      cnpCrd,
      ccnpCrd,
      keys,
    }@crds:
    dnsPeers:
    let
      rules = mkRules dnsPeers;
    in
    rules
    // {
      withDnsPeers = mkBound crds;

      mkPolicy =
        args:
        rules.mkPolicy (
          args
          // {
            crdRef = cnpCrd;
          }
        );

      # A platform intent targets pods outside any Kix scope, so the caller
      # passes the namespace resource (or `clusterScoped`) explicitly. A
      # clusterwide intent becomes a CiliumClusterwideNetworkPolicy, with
      # `targetNamespace` added to its endpoint selector; any other intent
      # becomes a CiliumNetworkPolicy in `namespaceResource`.
      materializePlatformIntent =
        {
          intent,
          mkResource,
          namespaceResource ? null,
          clusterScoped,
        }:
        let
          isClusterwide = (intent.scope or "namespaced") == "clusterwide";
          translated = rules.translateIntentRules {
            intents = {
              _single = intent;
            };
          };
          basePodSelector = intent.podSelector or { };
          podSelector =
            if isClusterwide && intent ? targetNamespace then
              basePodSelector
              // {
                "k8s:io.kubernetes.pod.namespace" = intent.targetNamespace;
              }
            else
              basePodSelector;
          spec = {
            endpointSelector.matchLabels = podSelector;
          }
          // lib.optionalAttrs (translated.egressRules != [ ]) { egress = translated.egressRules; }
          // lib.optionalAttrs (translated.ingressRules != [ ]) { ingress = translated.ingressRules; };
          crdRef = if isClusterwide then ccnpCrd else cnpCrd;
        in
        mkResource (
          crdRef.out.cr {
            name = intent.name;
            labels = {
              ${keys.derived} = "true";
              ${keys.policyType} = "platform-intent";
            };
            inherit spec;
          }
          // {
            namespace = if isClusterwide then clusterScoped else namespaceResource;
          }
        );
    };
in
rules
// {
  inherit mkRules;

  # The enforcer contract, bound to the package's CRD references and built
  # for the default DNS peers. Kix rebuilds it for the cluster's peers
  # through `withDnsPeers`. `cnpCrd` and `ccnpCrd` are the
  # CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy handles from
  # scope.mkCRDRef; `keys` is kix.keys.
  mkNetpolOut = crds: mkBound crds defaultDnsPeers;
}

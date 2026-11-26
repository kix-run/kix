# The network policy enforcer rules for platforms that enforce the standard
# `networking.k8s.io/v1` NetworkPolicy, such as GKE Dataplane V2 and the
# Amazon VPC CNI. Contract: ./interface.nix. A flavour's
# `platform-network-policy` import publishes `mkNetpol` as `out.netpol`.
#
# A NetworkPolicy has no peer for the nodes, the API server, or "outside the
# cluster", and each platform matches an ipBlock against different addresses.
# The flavour passes those platform facts in `platform`, and the cluster's
# address ranges in `network` (`cluster.network`). Each rule then comes out
# in one of three ways:
#
# - the same traffic the Cilium enforcer allows;
# - more traffic, with the reason marked on the rule (`_widened`, ids from
#   ./widening.nix), which `mkPolicy` writes on the policy as
#   `kix.run/network-policy-widened` for the `networkPolicyWidened`
#   scorecard rule;
# - an evaluation error that names the cluster option which would let Kix
#   express the rule.
#
# Kix forces a rule only when a policy uses it, so a refusal stops only a
# cluster that needs the rule.

{ lib }:

let
  inherit (import ../../core/error.nix { inherit lib; }) fail;
  inherit (import ./interface.nix { inherit lib; }) checkEntities defaultDnsPeers;
  kixKeys = (import ../../core/annotations.nix).keys;

  linkLocal4 = "169.254.0.0/16";
  linkLocal6 = "fe80::/10";

  isIpv6 = cidr: lib.hasInfix ":" cidr;

  # Return the first host address of an IPv4 range as a /32, such as
  # "10.100.0.1/32" for "10.100.0.0/16", or null for an IPv6 range.
  firstAddress =
    cidr:
    let
      parts = lib.splitString "/" cidr;
      octets = map lib.toInt (lib.splitString "." (builtins.head parts));
      prefix = lib.toInt (lib.last parts);
      asInt = builtins.foldl' (acc: o: acc * 256 + o) 0 octets;
      size = builtins.foldl' (acc: _: acc * 2) 1 (lib.range 1 (32 - prefix));
      first = asInt - lib.mod asInt size + 1;
      octet = i: toString (lib.mod (first / (builtins.foldl' (acc: _: acc * 256) 1 (lib.range 1 i))) 256);
    in
    if isIpv6 cidr then null else "${octet 3}.${octet 2}.${octet 1}.${octet 0}/32";

  namespacePeer = namespace: {
    namespaceSelector.matchLabels."kubernetes.io/metadata.name" = namespace;
  };

  # Return the peer for a `{ namespace; podSelector; }` or `{ cidr; }` entry,
  # the shape of DNS peers and of `cluster.network.apiServer.sources`.
  peerOf =
    p:
    if p ? cidr then
      { ipBlock.cidr = p.cidr; }
    else
      namespacePeer p.namespace // { podSelector.matchLabels = p.podSelector; };

  # Return a NetworkPolicy port from a Service port or an intent port: the
  # pod port (`targetPort`, or `port` when unset), as a number when it is
  # one. A named port is valid in both directions of a NetworkPolicy.
  portOf =
    p:
    let
      tp = p.targetPort or p.port or null;
      number = if builtins.isString tp && builtins.match "[0-9]+" tp != null then lib.toInt tp else tp;
    in
    if tp == null then
      null
    else
      {
        port = number;
        protocol = p.protocol or "TCP";
      };

  portsOf = ports: builtins.filter (p: p != null) (map portOf ports);

  # Return a rule with these peers and widening ids. An empty peer list in a
  # NetworkPolicy rule matches every address, so it is an error here.
  mkRule =
    {
      direction,
      peers,
      ports ? [ ],
      widened ? [ ],
    }:
    let
      field = if direction == "egress" then "to" else "from";
    in
    if peers == [ ] then
      fail "kix netpol: a standard ${direction} rule was built with no peers, which would allow every address. This is a bug in Kix."
    else
      {
        ${field} = lib.unique peers;
      }
      // lib.optionalAttrs (ports != [ ]) { inherit ports; }
      // lib.optionalAttrs (widened != [ ]) { _widened = lib.unique widened; };

  # Return the rule with `ports` replaced, as an intent rule's ports do.
  withPorts =
    rule: ports:
    let
      converted = portsOf ports;
    in
    (removeAttrs rule [ "ports" ]) // lib.optionalAttrs (converted != [ ]) { ports = converted; };

  mkRules =
    {
      platform,
      network,
      dnsPeers,
    }:
    let
      apiServer = network.apiServer or { };
      nodeCidrs = network.nodeCidrs or [ ];
      podCidr = network.podCidr or null;
      serviceCidr = network.serviceCidr or null;
      sources = apiServer.sources or [ ];

      selectsPods = platform.ipBlockSelectsPods;
      selectsNodes = platform.ipBlockSelectsNodes;
      seesServiceAddress = platform.ipBlockSeesServiceAddress;
      podStartsBeforePolicy = platform.podStartsBeforePolicy or false;

      # Build a NetworkPolicy. `selector` is the matchLabels of the pods it
      # selects, and `ingress` and `egress` are rules from these builders.
      # `policyTypes` is always set, because a policy without it isolates
      # its pods for ingress even when it has only egress rules. Without
      # `selector`, `extraArgs.spec` is the whole spec, as `mkDefaultDenySpec`
      # builds it.
      mkPolicy =
        {
          mkResource,
          extraArgs,
          selector ? null,
          ingress ? [ ],
          egress ? [ ],
        }:
        let
          name = extraArgs.name or "<unnamed>";
          strip = map (r: removeAttrs r [ "_widened" ]);
          spec =
            if selector == null then
              if extraArgs ? spec && extraArgs.spec ? podSelector then
                extraArgs.spec
              else
                fail {
                  message = "Network policy '${name}' gives a Cilium `spec` (with `endpointSelector`), and this cluster's network policy enforcer (${platform.provider}) writes a standard NetworkPolicy, so Kix rejected it.";
                  fix = "Pass `selector`, `ingress`, and `egress` with rules from `scope.networkPolicyEnforcer.netpol` instead of `spec`.";
                }
            else if extraArgs ? spec then
              fail {
                message = "Network policy '${name}' sets both `selector` and `extraArgs.spec`, so Kix rejected it.";
                fix = "Remove `extraArgs.spec` and pass rules in `ingress` and `egress` alongside `selector`.";
              }
            else
              {
                podSelector.matchLabels = selector;
                policyTypes = lib.optional (ingress != [ ]) "Ingress" ++ lib.optional (egress != [ ]) "Egress";
              }
              // lib.optionalAttrs (ingress != [ ]) { ingress = strip ingress; }
              // lib.optionalAttrs (egress != [ ]) { egress = strip egress; };
          # Where the platform applies policy after a pod starts, every policy
          # that isolates egress is open for that moment.
          ids = lib.unique (
            builtins.concatMap (r: r._widened or [ ]) (ingress ++ egress)
            ++ lib.optional (
              podStartsBeforePolicy && builtins.elem "Egress" (spec.policyTypes or [ ])
            ) "pod-start-egress-open"
          );
          annotations =
            (extraArgs.annotations or { })
            // lib.optionalAttrs (ids != [ ]) {
              ${kixKeys.networkPolicyWidened} = lib.concatStringsSep "," ids;
            };
        in
        mkResource (
          removeAttrs extraArgs [ "spec" ]
          // {
            apiVersion = "networking.k8s.io/v1";
            kind = "NetworkPolicy";
            inherit spec;
          }
          // lib.optionalAttrs (annotations != { }) { inherit annotations; }
        );

      # Spec for a default-deny policy. A listed policy type with no rules
      # allows nothing in that direction.
      mkDefaultDenySpec =
        {
          denyIngress,
          denyEgress,
        }:
        {
          podSelector = { };
          policyTypes = lib.optional denyIngress "Ingress" ++ lib.optional denyEgress "Egress";
        };

      dnsPorts = [
        {
          port = 53;
          protocol = "UDP";
        }
        {
          port = 53;
          protocol = "TCP";
        }
      ];

      # DNS egress: UDP and TCP 53 to every DNS peer. One rule holds both pod
      # peers and address peers.
      dnsEgressRule = mkRule {
        direction = "egress";
        peers = map peerOf dnsPeers;
        ports = dnsPorts;
      };

      # The addresses a pod reaches the API server at. Where an ipBlock sees
      # the Service address, that is the `kubernetes` Service, the first
      # address of the Service range.
      apiServerCidrs =
        if apiServer.cidrs or [ ] != [ ] then
          apiServer.cidrs
        else if seesServiceAddress && serviceCidr != null && firstAddress serviceCidr != null then
          [ (firstAddress serviceCidr) ]
        else
          null;

      # Each refusal below is null when Kix can express the rule. A rule that
      # needs it returns the refusal itself, so the build stops only when a
      # policy uses that rule.
      apiServerCidrsProblem =
        if apiServerCidrs != null then
          null
        else
          fail {
            clusterOption = "cluster.network.apiServer.cidrs";
            message = "A workload in this cluster needs network policy egress to the API server, and `cluster.network.apiServer.cidrs` is empty. A standard NetworkPolicy (${platform.provider}) can only reach the API server by address, so Kix stopped the build.";
            fix =
              if seesServiceAddress then
                "Set `cluster.network.apiServer.cidrs` to the address of the `kubernetes` Service as a /32 (`kubectl get service kubernetes -n default -o jsonpath='{.spec.clusterIP}'`), or set `cluster.network.serviceCidr` and Kix uses its first address."
              else
                "Set `cluster.network.apiServer.cidrs` to the API server endpoint addresses as /32 ranges (`kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[*].endpoints[*].addresses[*]}'`). The address can change when the platform rotates the control plane's IP.";
          };

      apiServerPeers = map (c: { ipBlock.cidr = c; }) apiServerCidrs;

      # API server egress, on the API server's port.
      apiServerEgressRule =
        if apiServerCidrsProblem != null then
          apiServerCidrsProblem
        else
          mkRule {
            direction = "egress";
            peers = apiServerPeers;
            ports = [
              {
                port = apiServer.port or 443;
                protocol = "TCP";
              }
            ];
          };

      # Where admission webhook and aggregated API calls come from.
      badSources = builtins.filter (
        p:
        !(
          builtins.isAttrs p
          && (
            builtins.attrNames p == [ "cidr" ]
            ||
              builtins.attrNames p == [
                "namespace"
                "podSelector"
              ]
          )
        )
      ) sources;

      sourcesProblem =
        if badSources != [ ] then
          fail {
            clusterOption = "cluster.network.apiServer.sources";
            message = "`cluster.network.apiServer.sources` has entries Kix cannot read: ${builtins.toJSON badSources}.";
            fix = "Write each entry as `{ cidr = \"<cidr>\"; }` or `{ namespace = \"<namespace>\"; podSelector = { ... }; }`, with no other fields.";
          }
        else if sources == [ ] then
          fail {
            clusterOption = "cluster.network.apiServer.sources";
            message = "A workload in this cluster accepts calls from the API server (an admission webhook or an aggregated API), and `cluster.network.apiServer.sources` is empty. A standard NetworkPolicy (${platform.provider}) cannot name the API server, so Kix stopped the build.";
            fix = "Set `cluster.network.apiServer.sources` to where the API server's calls come from: `{ cidr = \"...\"; }` for an address range, such as the control plane's subnets, or `{ namespace = \"...\"; podSelector = { ... }; }` for proxy pods.";
          }
        else
          null;

      apiServerSources = {
        peers = map peerOf sources;
        widened = lib.optional (selectsPods && builtins.any (s: s ? cidr) sources) "apiserver-sources-pods";
      };

      nodesProblem =
        if !selectsNodes then
          fail {
            message = "A network policy rule in this cluster names the nodes (`host`, `remote-node`, `cluster`, or a target on the host network), and on ${platform.provider} an ipBlock cannot match node addresses, so Kix stopped the build.";
            fix = "Remove the rule that names the nodes, or use a network policy enforcer that can match them, such as Cilium.";
          }
        else if nodeCidrs == [ ] then
          fail {
            clusterOption = "cluster.network.nodeCidrs";
            message = "A network policy rule in this cluster names the nodes (`host`, `remote-node`, `cluster`, or a target on the host network), and `cluster.network.nodeCidrs` is empty. A standard NetworkPolicy (${platform.provider}) can only match the nodes by address, so Kix stopped the build.";
            fix = "Set `cluster.network.nodeCidrs` to the address ranges of the cluster's nodes, such as the node subnets.";
          }
        else
          null;

      nodes = {
        peers = map (c: { ipBlock.cidr = c; }) nodeCidrs;
        widened = lib.optional selectsPods "node-range-pods";
      };

      podsAnywhere = {
        peers = [
          {
            namespaceSelector = { };
            podSelector = { };
          }
        ];
        widened = [ ];
      };

      # Every address outside the cluster. The link-local ranges are always
      # left out, so a `world` rule never reaches a cloud metadata server
      # or a node-local agent. On egress, the pod, node, and Service ranges
      # are left out where an ipBlock would match them and the cluster
      # declares them, and the rule is marked wider where it does not.
      world =
        direction:
        let
          egress = direction == "egress";
          excluded =
            lib.optionals (egress && selectsPods && podCidr != null) [ podCidr ]
            ++ lib.optionals (egress && selectsNodes) nodeCidrs
            ++ lib.optionals (egress && seesServiceAddress && serviceCidr != null) [ serviceCidr ];
          v4 = [ linkLocal4 ] ++ builtins.filter (c: !(isIpv6 c)) excluded;
          v6 = [ linkLocal6 ] ++ builtins.filter isIpv6 excluded;
        in
        {
          peers = [
            {
              ipBlock = {
                cidr = "0.0.0.0/0";
                except = v4;
              };
            }
            {
              ipBlock = {
                cidr = "::/0";
                except = v6;
              };
            }
          ];
          widened =
            if egress then
              lib.optional (selectsPods && podCidr == null) "world-egress-pods"
              ++ lib.optional (selectsNodes && nodeCidrs == [ ]) "world-egress-nodes"
              ++ lib.optional (seesServiceAddress && serviceCidr == null) "world-egress-services"
            else
              lib.optional selectsPods "world-ingress-pods" ++ lib.optional selectsNodes "world-ingress-nodes";
        };

      apiServerSide =
        direction:
        if direction == "egress" then
          {
            peers = apiServerPeers;
            widened = [ ];
          }
        else
          apiServerSources;

      apiServerSideProblem =
        direction: if direction == "egress" then apiServerCidrsProblem else sourcesProblem;

      firstProblem = lib.findFirst (p: p != null) null;

      # Return the refusal for one entity name, or null.
      entityProblem =
        direction: name:
        if name == "host" || name == "remote-node" then
          nodesProblem
        else if name == "kube-apiserver" then
          apiServerSideProblem direction
        else if name == "cluster" || name == "all" then
          firstProblem [
            nodesProblem
            (apiServerSideProblem direction)
          ]
        else
          null;

      # Return the peers and widening ids for one entity name.
      entity =
        direction: name:
        if name == "world" then
          world direction
        else if name == "host" || name == "remote-node" then
          nodes
        else if name == "kube-apiserver" then
          apiServerSide direction
        else if name == "cluster" then
          merge [
            podsAnywhere
            nodes
            (apiServerSide direction)
          ]
        else if name == "all" then
          merge [
            (world direction)
            (entity direction "cluster")
          ]
        else
          fail "kix netpol: unknown entity '${name}' reached the standard renderer. This is a bug in Kix.";

      merge = parts: {
        peers = builtins.concatMap (p: p.peers) parts;
        widened = builtins.concatMap (p: p.widened) parts;
      };

      # `host` means the pod's own node to Cilium. A NetworkPolicy cannot
      # name one node, so `host` without `remote-node` allows every node.
      entitiesRule =
        direction: where: entities:
        let
          checked = checkEntities where entities;
          problem = firstProblem (map (entityProblem direction) checked);
          parts = merge (map (entity direction) checked);
          hostOnly = builtins.elem "host" checked && !(builtins.elem "remote-node" checked);
        in
        if problem != null then
          problem
        else
          mkRule {
            inherit direction;
            inherit (parts) peers;
            widened = parts.widened ++ lib.optional hostOnly "host-all-nodes";
          };

      mkExternalIngressRule =
        {
          entities ? [ "world" ],
        }:
        entitiesRule "ingress" "An external ingress rule" entities;

      mkExternalEgressRule =
        {
          entities ? [ "world" ],
        }:
        entitiesRule "egress" "An external egress rule" entities;

      # Egress to a Service's backing pods, on the pod ports. Every platform
      # matches a pod selector after Service address translation.
      mkServiceEgressRule =
        {
          selector,
          namespace,
          sourceNamespace,
          ports,
        }:
        mkRule {
          direction = "egress";
          peers = [
            (
              (if namespace == sourceNamespace then { } else namespacePeer namespace)
              // {
                podSelector.matchLabels = selector;
              }
            )
          ];
          ports = portsOf ports;
        };

      # Egress to pods on the host network of any node: the node ranges.
      mkHostNetworkEgressRule =
        { ports }:
        if nodesProblem != null then
          nodesProblem
        else
          mkRule {
            direction = "egress";
            inherit (nodes) peers widened;
            ports = portsOf ports;
          };

      # Peer traffic between the pods of one workload.
      mkSelfRules =
        { selector }:
        {
          egress = [
            (mkRule {
              direction = "egress";
              peers = [ { podSelector.matchLabels = selector; } ];
            })
          ];
          ingress = [
            (mkRule {
              direction = "ingress";
              peers = [ { podSelector.matchLabels = selector; } ];
            })
          ];
        };

      # Ingress from a caller's pods, in `callerNamespace` or in any
      # namespace when it is null.
      mkCallerIngressRule =
        {
          callerSelector,
          callerNamespace,
          ports,
        }:
        mkRule {
          direction = "ingress";
          peers = [
            (
              (if callerNamespace == null then { namespaceSelector = { }; } else namespacePeer callerNamespace)
              // {
                podSelector.matchLabels = callerSelector;
              }
            )
          ];
          ports = portsOf ports;
        };

      # The interface's name for converting Service ports to this enforcer's
      # port list.
      portsToCilium = portsOf;

      mkEndpointSelector = matchLabels: { podSelector.matchLabels = matchLabels; };

      translateIntentRules =
        { intents }:
        let
          translateEgressRule =
            rule:
            let
              target =
                rule.to or (fail {
                  message = "An egress intent rule must have a `to` field.";
                });
              base =
                if target == "apiserver" then
                  apiServerEgressRule
                else if target == "world" then
                  mkExternalEgressRule { entities = rule.entities or [ "world" ]; }
                else if target == "dns" then
                  dnsEgressRule
                # Pods in every namespace. Cilium's `cluster` entity, which
                # Cilium writes for `all-pods`, also holds the nodes and the
                # API server; a NetworkPolicy namespace selector holds pods only.
                else if target == "all-pods" || target == "pods" then
                  mkRule {
                    direction = "egress";
                    inherit (podsAnywhere) peers;
                  }
                # An address on the pod's own node, such as a cloud metadata
                # server or a credential agent.
                else if target == "node-local" then
                  mkRule {
                    direction = "egress";
                    peers = [
                      {
                        ipBlock.cidr =
                          rule.cidr or (fail {
                            message = "Egress intent rule with `to = \"node-local\"` is missing `cidr`, so Kix could not build the rule.";
                            fix = "Add `cidr` with the node-local IP range, such as `cidr = \"169.254.169.254/32\";`.";
                          });
                      }
                    ];
                  }
                else
                  fail {
                    message = "unknown egress intent target '${toString target}'.";
                    fix = "Set `to` to \"apiserver\", \"world\", \"dns\", \"pods\", \"all-pods\", or \"node-local\".";
                  };
            in
            if target == "dns" || !(rule ? ports) then base else withPorts base rule.ports;

          translateIngressRule =
            rule:
            let
              source =
                rule.from or (fail {
                  message = "An ingress intent rule must have a `from` field.";
                });
              base =
                if source == "all-pods" then
                  mkRule {
                    direction = "ingress";
                    inherit (podsAnywhere) peers;
                  }
                else if source == "world" then
                  mkExternalIngressRule { entities = rule.entities or [ "world" ]; }
                else if source == "apiserver" then
                  if sourcesProblem != null then
                    sourcesProblem
                  else
                    mkRule {
                      direction = "ingress";
                      inherit (apiServerSources) peers widened;
                    }
                else
                  fail {
                    message = "Unknown ingress intent source '${toString source}'. The sources are all-pods, world, and apiserver.";
                  };
            in
            if rule ? ports then withPorts base rule.ports else base;

          allIntents = builtins.attrValues intents;
        in
        {
          egressRules = builtins.concatMap (i: map translateEgressRule (i.egress or [ ])) allIntents;
          ingressRules = builtins.concatMap (i: map translateIngressRule (i.ingress or [ ])) allIntents;
        };

      # A platform intent becomes a NetworkPolicy in `namespaceResource`. A
      # NetworkPolicy is always namespaced, so a clusterwide intent is
      # refused.
      materializePlatformIntent =
        {
          intent,
          mkResource,
          namespaceResource ? null,
          clusterScoped,
        }:
        let
          translated = translateIntentRules {
            intents._single = intent;
          };
        in
        if (intent.scope or "namespaced") == "clusterwide" then
          fail {
            clusterOption = "networkPolicy.platformIntents.${intent.name}";
            message = "Platform intent '${intent.name}' has `scope = \"clusterwide\"`, and this cluster's network policy enforcer (${platform.provider}) writes only namespaced NetworkPolicies, so Kix stopped the build.";
            fix = "Set `namespace` on the intent and remove `scope`, with one intent for each namespace the pods run in.";
          }
        else
          mkPolicy {
            inherit mkResource;
            selector = intent.podSelector or { };
            ingress = translated.ingressRules;
            egress = translated.egressRules;
            extraArgs = {
              inherit (intent) name;
              namespace = namespaceResource;
              labels = {
                ${kixKeys.derived} = "true";
                ${kixKeys.policyType} = "platform-intent";
              };
            };
          };
    in
    {
      policyKinds = [ "NetworkPolicy" ];
      inherit
        mkPolicy
        mkDefaultDenySpec
        dnsEgressRule
        apiServerEgressRule
        mkExternalIngressRule
        mkExternalEgressRule
        mkServiceEgressRule
        mkHostNetworkEgressRule
        mkSelfRules
        mkCallerIngressRule
        portsToCilium
        mkEndpointSelector
        translateIntentRules
        materializePlatformIntent
        ;
    };

  # Return the enforcer contract for `dnsPeers`. Kix reads it through the
  # import's `out`, whose plain attribute sets it walks for references, and
  # some rules here stop the build when forced, so `_type` keeps that walk
  # out.
  mkBound =
    args: dnsPeers:
    mkRules (args // { inherit dnsPeers; })
    // {
      _type = "kix-netpol-enforcer";
      withDnsPeers = mkBound args;
    };
in
{
  inherit mkRules firstAddress;

  # Return `out.netpol` for a platform. `platform` holds `provider` (the
  # name in messages) and the facts `ipBlockSelectsPods`,
  # `ipBlockSelectsNodes`, `ipBlockSeesServiceAddress`, and
  # `podStartsBeforePolicy`. `network` is `cluster.network`.
  mkNetpol = { platform, network }: mkBound { inherit platform network; } defaultDnsPeers;
}

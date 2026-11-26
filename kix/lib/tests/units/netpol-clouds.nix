# Tests for the parts of generated network policy that managed clouds need:
# the missing-enforcer error where the platform owns the pod network, and the
# enforcer-neutral arguments of `kix.operandPolicy` (`selector`, `ingress`,
# `egress`) and the closed list of entity names.

{
  lib,
  mkCluster,
  netpolOn,
  manifests,
  byName,
  evalFails,
  containerBase,
  ...
}:

let
  helpers = import ../caught.nix { inherit lib; };

  # The netpol module loaded so that `kix.fail` returns
  # `{ thrown = <sentences>; }`, which lets a test read the error text.
  netpolModule = helpers.loadCaught ../../plugins/netpol/module.nix;

  # Return the text of the missing-enforcer error for a cluster whose `cni`
  # role has these settings, or null when the check passes.
  missingEnforcerError =
    cniRole:
    let
      m = netpolModule {
        inherit lib;
        config = {
          networkPolicy = {
            enable = true;
            defaultDeny = true;
            enforced = {
              ingress = true;
              egress = true;
            };
            platformIntents = { };
          };
          cluster.roles = lib.optionalAttrs (cniRole != null) { cni = cniRole; };
        };
      };
      result = m.config.content.hooks.clusterProcessors.netpol {
        cluster.findRoleProvider = _: null;
        nsResources = { };
        realNsNames = [ ];
        resources = [ ];
      };
    in
    (builtins.head result.checks).thrown or null;

  # A package whose `peers` part is `kix.operandPolicy` called with `args`
  # (scope and name added), next to a ConfigMap standing in for the custom
  # resource an operator would read.
  operandPackage =
    args:
    { kix, ... }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          cr = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "operand-cr";
          };
          peers = kix.operandPolicy (
            {
              inherit scope;
              name = "operand-peers";
            }
            // args scope
          );
          root = {
            resource = self.cr;
            requires = lib.optional (self.peers != null) self.peers;
          };
        };
    };

  # Rules read from the enforcer, so the arguments stay lazy when the scope
  # has none.
  peerRules = scope: {
    selector.app = "operand";
    ingress = (scope.networkPolicyEnforcer.netpol.mkSelfRules { selector.app = "operand"; }).ingress;
    egress = [ scope.networkPolicyEnforcer.netpol.dnsEgressRule ];
  };

  operandCluster =
    modules: args:
    mkCluster (
      [
        { instances.app.operand.package = operandPackage args; }
      ]
      ++ modules
    );
  operandPolicyIn = cluster: byName "operand-peers" (manifests cluster);

  # A package with one Deployment whose `meta.network` is `network`, and a
  # LoadBalancer Service in front of it when `loadBalancer` is true.
  intentPackage = network: loadBalancer: {
    meta = {
      version = "test";
      inherit network;
    };
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkDeployment {
          name = "web";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                (
                  {
                    name = "web";
                    image = "example/web:1";
                  }
                  // containerBase
                )
              ];
            };
          };
        };
        service =
          if loadBalancer then
            scope.mkResource {
              apiVersion = "v1";
              kind = "Service";
              name = "web";
              spec = {
                type = "LoadBalancer";
                selector = scope.selectorLabels;
                ports = [ { port = 80; } ];
              };
            }
          else
            null;
        root = self.deployment;
      };
  };
  intentCluster =
    network: loadBalancer:
    mkCluster [
      netpolOn
      { instances.app.web.package = intentPackage network loadBalancer; }
    ];
in
{
  # Where the platform owns the pod network, a `cilium` instance is refused,
  # so the error does not recommend one and names the pod network instead.
  netpol-clouds-missing-enforcer-exclusive-cni =
    let
      exclusive = missingEnforcerError {
        binding = "exclusive";
        provider = "gke-native (dataplane v2)";
      };
      shadowable = missingEnforcerError {
        binding = "shadowable";
        provider = "cilium (environment)";
      };
      unset = missingEnforcerError null;
    in
    (
      exclusive != null
      && !(lib.hasInfix "Declare a `cilium` instance" exclusive)
      && lib.hasInfix "`gke-native (dataplane v2)`" exclusive
      && lib.hasInfix "networkPolicy.enable = false" exclusive
      && lib.hasInfix "Declare a `cilium` instance" shadowable
      && lib.hasInfix "Declare a `cilium` instance" unset
    )
    || throw "missing-enforcer error: exclusive ${toString exclusive}; shadowable ${toString shadowable}; unset ${toString unset}";

  # `selector`, `ingress`, and `egress` render the same Cilium spec as the
  # older `spec` form. Without an enforcer the helper returns null and never
  # reads the rules.
  netpol-clouds-operand-policy-selector =
    let
      off = operandPolicyIn (operandCluster [ ] peerRules);
      on = operandPolicyIn (operandCluster [ netpolOn ] peerRules);
    in
    (
      off == null
      && on.spec.endpointSelector.matchLabels == { app = "operand"; }
      &&
        on.spec.ingress == [
          {
            stubRule = "self-ingress";
            selector.app = "operand";
          }
        ]
      && on.spec.egress == [ { stubRule = "dns-egress"; } ]
    )
    || throw "kix.operandPolicy selector: without enforcer ${builtins.toJSON off}, with enforcer ${builtins.toJSON on}";

  # Rules for a direction the cluster does not enforce are dropped, and a
  # policy left with no rules is null.
  netpol-clouds-operand-policy-selector-directions =
    let
      policyWith =
        directions: args:
        operandPolicyIn (
          operandCluster [
            netpolOn
            { networkPolicy.directions = directions; }
          ] args
        );
      egressOnly = policyWith "egress" peerRules;
      ingressOnly = policyWith "ingress" peerRules;
      dropped = policyWith "egress" (scope: removeAttrs (peerRules scope) [ "egress" ]);
    in
    (
      !(egressOnly.spec ? ingress)
      && egressOnly.spec ? egress
      && ingressOnly.spec ? ingress
      && !(ingressOnly.spec ? egress)
      && dropped == null
    )
    || throw "kix.operandPolicy directions: egress ${builtins.toJSON egressOnly}, ingress ${builtins.toJSON ingressOnly}, dropped ${builtins.toJSON dropped}";

  # A call with both `selector` and `spec`, or with neither, is refused.
  netpol-clouds-operand-policy-selector-refusals =
    let
      both = operandCluster [ netpolOn ] (
        scope:
        peerRules scope
        // {
          spec.endpointSelector.matchLabels.app = "operand";
        }
      );
      neither = operandCluster [ netpolOn ] (scope: removeAttrs (peerRules scope) [ "selector" ]);
      fine = operandCluster [ netpolOn ] peerRules;
    in
    (evalFails both && evalFails neither && !(evalFails fine))
    || throw "kix.operandPolicy refusals: both ${toString (evalFails both)}, neither ${toString (evalFails neither)}, fine ${toString (evalFails fine)}";

  # An intent rule may name only the entities Kix knows, and so may
  # `externalIngressEntities`.
  netpol-clouds-entities-closed-list =
    let
      withEntities = entities: {
        intents.peers.egress = [
          {
            to = "world";
            inherit entities;
          }
        ];
      };
      known = intentCluster (withEntities [
        "host"
        "remote-node"
      ]) false;
      unknownIntent = intentCluster (withEntities [ "health" ]) false;
      knownExternal = intentCluster { externalIngressEntities = [ "all" ]; } true;
      unknownExternal = intentCluster { externalIngressEntities = [ "ingress" ]; } true;
    in
    (
      !(evalFails known)
      && evalFails unknownIntent
      && !(evalFails knownExternal)
      && evalFails unknownExternal
    )
    || throw "entities: known ${toString (evalFails known)}, unknown intent ${toString (evalFails unknownIntent)}, known external ${toString (evalFails knownExternal)}, unknown external ${toString (evalFails unknownExternal)}";
}

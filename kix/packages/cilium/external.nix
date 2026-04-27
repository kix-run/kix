# Cilium (externally managed) — CNP CRD ref marker + netpol API.
#
# Inline package for clusters where cilium is installed out-of-band
# (e.g. k3s with cilium helm-installed by a bootstrap script, or kind
# with deploy-ludo-kind.sh). Emits only the CiliumNetworkPolicy CRD ref
# marker so kix/lib/netpol.nix can route generated CNPs through it.
#
# Does NOT deploy cilium itself. The CLI deploy engine polls for the
# externally-installed CRD and waits for `Established=True` before any
# dependent CNP wave runs.
#
# Exposes the same `out.netpol` API as the full cilium package so
# packages can emit CNPs for operator-managed workloads.
#
# Usage:
#   instances.kube-system.cilium = {
#     package = import ./kix/packages/cilium/external.nix;
#   };

let
  ciliumNetpol = import ./netpol-rules.nix { lib = import <nixpkgs/lib>; };
in

{
  meta = {
    version = "external";
    description = "Cilium (externally managed) — CNP CRD ref marker only";
    provides = [
      "network-policy-enforcer"
      "cilium"
    ];
  };

  build =
    { scope, lib, ... }:
    let
      # Re-import with the lib that's available in scope.
      rules = import ./netpol-rules.nix { inherit lib; };

      crdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumNetworkPolicy";
        plural = "ciliumnetworkpolicies";
        version = "v2";
        crdScope = "Namespaced";
      };
    in
    {
      cnpCrdRef = crdRef;

      root = {
        resource = crdRef;
        requires = [ ];
        out = {
          cnpCrdRef = crdRef;
          # Network-policy rule builder API — same as the full cilium
          # package. Bind `mkPolicy` to this package's cnpCrdRef.
          netpol = rules // {
            mkPolicy =
              { mkResource, extraArgs }:
              rules.mkPolicy {
                crdRef = crdRef;
                inherit mkResource extraArgs;
              };

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
                enriched = crdRef.out.cr {
                  name = intent.name;
                  labels = {
                    "kix.dev/derived" = "true";
                    "kix.dev/policy-type" = "platform-intent";
                  };
                  inherit spec;
                };
              in
              mkResource (
                enriched
                // {
                  namespace = if isClusterwide then clusterScoped else namespaceResource;
                }
              );
          };
        };
      };
    };
}

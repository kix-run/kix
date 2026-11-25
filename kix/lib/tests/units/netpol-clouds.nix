# Tests for network policy on clusters whose platform owns the pod network:
# the missing-enforcer error.

{
  lib,
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
}

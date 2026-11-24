# Define the contract of the `gatewayApi` role: the Gateway API CRDs
# (gateway.networking.k8s.io) that Gateway API implementations build their
# GatewayClass and Gateway from (`kix.contracts.experimental.gatewayApi`).
#
# The gateway-api package passes its `root.out` through `check`. A platform
# `kix.mkImport` that claims the role answers it with `out.version` and the
# `crds` entries a consumer needs. A consumer reads the handles through
# `helpers.crdsFor`, which refuses a missing provider, a kind the provider
# does not declare, a version older than the consumer's minimum, and a
# GatewayClass or Gateway handle without the readiness the deploy waits on.
{
  lib,
  mkContract,
  ...
}:
let
  inherit (import ../../lib/core/error.nix { inherit lib; }) failOf refuseWho;
  kixKeys = (import ../../lib/core/annotations.nix).keys;

  fields = {
    crds = {
      required = true;
      shape = "an attribute set of CRD handles keyed by kind, such as crds.Gateway";
      test = builtins.isAttrs;
    };
    version = {
      required = true;
      shape = "a Gateway API version string such as \"1.6.1\"";
      test = v: builtins.isString v && builtins.match "v?[0-9]+(\\.[0-9]+)*" v != null;
    };
  };

  # The condition a kind must declare, so that the deploy waits until the
  # implementation has accepted a GatewayClass and programmed a Gateway.
  readinessOf = {
    GatewayClass = "Accepted";
    Gateway = "Programmed";
  };

  hasReadiness =
    handle:
    let
      probe = handle.out.cr {
        name = "readiness-probe";
        spec = { };
      };
    in
    (probe.annotations or { }) ? ${kixKeys.readiness};
in
mkContract {
  name = "Gateway API";
  alias = "gatewayApi";
  remedyNoun = "Gateway API provider";
  inherit fields;

  helpers = rec {
    # Return the errors, as `scope.fail` takes them, that `crdsFor` raises
    # for these arguments, or [ ] when the provider serves the consumer.
    errorsFor =
      {
        who ? null,
        gatewayApi,
        kinds,
        minVersion,
      }:
      let
        out = gatewayApi.out or { };
        problems = builtins.concatMap (
          field:
          let
            f = fields.${field};
          in
          if !(out ? ${field}) then
            [ "out.${field} is missing (${f.shape})" ]
          else if !(f.test out.${field}) then
            [ "out.${field} is not ${f.shape}" ]
          else
            [ ]
        ) (builtins.attrNames fields);
        version = lib.removePrefix "v" out.version;
        missingKinds = builtins.filter (k: !(out.crds ? ${k})) kinds;
        unready = builtins.filter (
          k: readinessOf ? ${k} && out.crds ? ${k} && !(hasReadiness out.crds.${k})
        ) kinds;
        provider =
          if gatewayApi ? _meta then
            "${gatewayApi._meta.namespaceName or "?"}/${gatewayApi._meta.instanceName or "?"}"
          else
            "the gatewayApi provider";
        error = e: [ ({ dependency = "gatewayApi"; } // e) ];
      in
      if who != null then
        refuseWho {
          helper = "contracts.experimental.gatewayApi.helpers.errorsFor";
          reason = "The `scope.fail` that reports the errors names the instance and its package.";
          fix = "Remove `who`.";
        }
      else if gatewayApi == null then
        error {
          id = "K5531";
          message = "this instance requires the Kubernetes Gateway API CRDs (gateway.networking.k8s.io), but nothing in the cluster provides the 'gatewayApi' role.";
          fix =
            "Add a `gateway-api` instance to your cluster definition:\n"
            + "  instances.gateway-system.gateway-api.package = packages.experimental.gateway-api;\n"
            + "If your Kubernetes provider already installs these CRDs, set `cluster.roles.gatewayApi.binding = \"exclusive\";` and declare them with `kix.mkImport`, setting `roles = [ \"gatewayApi\" ]`, `out.version`, and `crds` entries for ${lib.concatStringsSep ", " kinds}.";
        }
      else if problems != [ ] then
        error {
          message = "${provider} provides the gatewayApi role, but ${lib.concatStringsSep "; " problems}.";
          fix = "In a `kix.mkImport`, set `out.version` (for example, `out.version = \"${minVersion}\";`) and declare the CRDs in `crds`. In a package, publish `out.version` and `out.crds` on `root`.";
        }
      else if missingKinds != [ ] then
        error {
          message = "${provider} does not declare the ${lib.concatStringsSep ", " missingKinds} CRD${
            lib.optionalString (builtins.length missingKinds != 1) "s"
          } required by this instance.";
          fix = "Add ${
            if builtins.length missingKinds == 1 then
              "a `crds` entry for ${builtins.head missingKinds}"
            else
              "`crds` entries for ${lib.concatStringsSep ", " missingKinds}"
          } to ${provider} with `group = \"gateway.networking.k8s.io\"` and `version` set to the served API version (such as `\"v1\"`).";
        }
      else if lib.versionOlder version minVersion then
        error {
          message = "${provider} provides Gateway API ${version}, but this instance requires ${minVersion} or later.";
          fix = "Upgrade the cluster's Gateway API CRDs to ${minVersion} or later, then update `out.version` on ${provider} to match.";
        }
      else if unready != [ ] then
        error {
          message =
            if builtins.length unready == 1 then
              "the ${builtins.head unready} CRD entry in ${provider} has no readiness condition, so `kix deploy` would not wait for the ${builtins.head unready} to become ready."
            else
              "the ${lib.concatStringsSep " and " unready} CRD entries in ${provider} have no readiness conditions, so `kix deploy` would not wait for them to become ready.";
          fix = lib.concatMapStringsSep " " (
            k:
            "Set `readiness.condition = { type = \"${readinessOf.${k}}\"; status = \"True\"; };` on the ${k} entry in ${provider}'s `crds`."
          ) unready;
        }
      else
        [ ];

    # Return `gatewayApi.out.crds` for a Gateway API implementation that
    # builds or watches `kinds` and needs Gateway API `minVersion` or later,
    # or fail with the first of `errorsFor`. `scope` is the consumer's.
    # `gatewayApi` is the consumer's dependency, null when nothing answers
    # the role.
    crdsFor =
      {
        scope ? null,
        who ? null,
        ...
      }@args:
      let
        scopeFail = failOf "contracts.experimental.gatewayApi.helpers.crdsFor" { inherit scope who; };
        errors = errorsFor (removeAttrs args [ "scope" ]);
      in
      if builtins.seq scopeFail errors == [ ] then
        args.gatewayApi.out.crds
      else
        scopeFail (builtins.head errors);
  };
}

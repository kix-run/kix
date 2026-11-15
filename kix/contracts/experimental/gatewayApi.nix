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
  inherit (import ../../lib/core/error.nix { inherit lib; }) fail;
  kixKeys = (import ../../lib/core/annotations.nix).keys;

  fields = {
    crds = {
      required = true;
      shape = "an attribute set of CRD handles keyed by kind, such as crds.Gateway";
      test = builtins.isAttrs;
    };
    version = {
      required = true;
      shape = "the Gateway API release of the CRDs, such as \"1.6.1\"";
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
    # Return the errors, as `kix.fail` takes them, that `crdsFor` raises for
    # these arguments, or [ ] when the provider serves the consumer.
    errorsFor =
      {
        who,
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
        error = e: [
          (
            {
              instance = who;
              dependency = "gatewayApi";
            }
            // e
          )
        ];
      in
      if gatewayApi == null then
        error {
          id = "K5531";
          message = "this instance requires the Kubernetes Gateway API CRDs (gateway.networking.k8s.io), and nothing in the cluster provides the 'gatewayApi' role.";
          fix =
            "Add a `gateway-api` instance to your cluster definition:\n"
            + "  instances.gateway-system.gateway-api.package = packages.experimental.gateway-api;\n"
            + "If your Kubernetes provider already installs the Gateway API CRDs, set `cluster.roles.gatewayApi.binding = \"exclusive\";` and declare them with a `kix.mkImport` that sets `roles = [ \"gatewayApi\" ]`, `out.version`, and a `crds` entry for each of: ${lib.concatStringsSep ", " kinds}.";
        }
      else if problems != [ ] then
        error {
          message = "${provider} answers the gatewayApi role, but ${lib.concatStringsSep "; " problems}.";
          fix = "Set them on that instance's out. A kix.mkImport sets `out.version` and lists the CRDs in `crds`.";
        }
      else if missingKinds != [ ] then
        error {
          message = "${provider} declares no CRD for ${lib.concatStringsSep ", " missingKinds}, which this instance builds or watches.";
          fix = "Add a `crds` entry for each of them to the kix.mkImport that claims the gatewayApi role, with the group gateway.networking.k8s.io and the version the CRD serves.";
        }
      else if lib.versionOlder version minVersion then
        error {
          message = "${provider} provides Gateway API ${version}, and this instance needs ${minVersion} or later.";
          fix = "Install Gateway API ${minVersion} or later, and set `out.version` on the provider to match.";
        }
      else if unready != [ ] then
        error {
          message = "the ${lib.concatStringsSep " and " unready} CRD from ${provider} declares no readiness, so the deploy would not wait for the controller to accept or program it.";
          fix = lib.concatMapStringsSep " " (
            k:
            "Add `readiness.condition = { type = \"${readinessOf.${k}}\"; status = \"True\"; };` to the ${k} entry of the import's `crds`."
          ) unready;
        }
      else
        [ ];

    # Return `gatewayApi.out.crds` for a Gateway API implementation that
    # builds or watches `kinds` and needs Gateway API `minVersion` or later,
    # or fail with the first of `errorsFor`. `who` names the consumer
    # instance as <namespace>/<name>. `gatewayApi` is the consumer's
    # dependency, null when nothing answers the role.
    crdsFor =
      args:
      let
        errors = errorsFor args;
      in
      if errors == [ ] then args.gatewayApi.out.crds else fail (builtins.head errors);
  };
}

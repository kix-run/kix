# cert-manager's six CustomResourceDefinitions, vendored from the release's
# cert-manager.crds.yaml (crds/sources.txt).
#
# The validating webhook admits every object of these kinds with
# failurePolicy Fail and refuses writes until cainjector has injected its CA
# into the webhook configuration. Each handle's `cr` and `mkCR` therefore add
# the API-check Job (startupapicheck.nix) to the custom resource's requires.
# Certificate, Issuer, and ClusterIssuer also declare their Ready condition,
# so a deploy waits for them and reports cert-manager's message on failure.

{ self, scope, ... }:
let
  vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;

  ready.condition = {
    type = "Ready";
    status = "True";
  };

  withCheck = args: args // { requires = (args.requires or [ ]) ++ [ self.apiCheck ]; };

  gate =
    crd:
    crd
    // {
      out = crd.out // {
        cr = args: crd.out.cr (withCheck args);
        mkCR = consumerScope: args: crd.out.mkCR consumerScope (withCheck args);
      };
    };
in
{
  crds = {
    certificates = gate (
      scope.mkCRD {
        spec = vendored "certificates.cert-manager.io.json";
        readiness = ready;
      }
    );
    certificateRequests = gate (
      scope.mkCRD { spec = vendored "certificaterequests.cert-manager.io.json"; }
    );
    challenges = gate (scope.mkCRD { spec = vendored "challenges.acme.cert-manager.io.json"; });
    clusterIssuers = gate (
      scope.mkCRD {
        spec = vendored "clusterissuers.cert-manager.io.json";
        readiness = ready;
      }
    );
    issuers = gate (
      scope.mkCRD {
        spec = vendored "issuers.cert-manager.io.json";
        readiness = ready;
      }
    );
    orders = gate (scope.mkCRD { spec = vendored "orders.acme.cert-manager.io.json"; });
  };
}

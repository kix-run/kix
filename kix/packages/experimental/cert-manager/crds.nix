# cert-manager's six CustomResourceDefinitions, vendored from the release's
# cert-manager.crds.yaml (crds/sources.txt).
#
# The validating webhook admits every object of these kinds with
# failurePolicy Fail and refuses writes until cainjector has injected its CA
# into the webhook configuration. Each definition therefore lists the
# API-check Job (startupapicheck.nix) in `crRequires`. Every kind also names
# the cert-manager controller Deployment as its `controller`, which
# reconciles all six and removes their finalizers.
# Certificate, CertificateRequest, Issuer, and ClusterIssuer also declare
# their Ready condition, so a deploy waits for them and reports
# cert-manager's message on failure. Order and Challenge report a
# `status.state` and no conditions.

{ self, scope, ... }:
let
  vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;

  ready.condition = {
    type = "Ready";
    status = "True";
  };

  checked = [ self.apiCheck ];
in
# A certificate can be issued again, so no cert-manager kind holds data.
# No kind but Challenge runs pods; an HTTP01 Challenge runs a solver pod.
{
  crds = {
    certificates = scope.mkCRD {
      spec = vendored "certificates.cert-manager.io.json";
      readiness = ready;
      holdsData = false;
      crRequires = checked;
      controller = self.controllerDeployment;
      usesAtLeast = _: { };
    };
    certificateRequests = scope.mkCRD {
      spec = vendored "certificaterequests.cert-manager.io.json";
      readiness = ready;
      holdsData = false;
      crRequires = checked;
      controller = self.controllerDeployment;
      usesAtLeast = _: { };
    };
    challenges = scope.mkCRD {
      spec = vendored "challenges.acme.cert-manager.io.json";
      holdsData = false;
      crRequires = checked;
      controller = self.controllerDeployment;
    };
    clusterIssuers = scope.mkCRD {
      spec = vendored "clusterissuers.cert-manager.io.json";
      readiness = ready;
      holdsData = false;
      crRequires = checked;
      controller = self.controllerDeployment;
      usesAtLeast = _: { };
    };
    issuers = scope.mkCRD {
      spec = vendored "issuers.cert-manager.io.json";
      readiness = ready;
      holdsData = false;
      crRequires = checked;
      controller = self.controllerDeployment;
      usesAtLeast = _: { };
    };
    orders = scope.mkCRD {
      spec = vendored "orders.acme.cert-manager.io.json";
      holdsData = false;
      crRequires = checked;
      controller = self.controllerDeployment;
      usesAtLeast = _: { };
    };
  };
}

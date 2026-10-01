# Values the cert-manager component files share.

{ lib }:

let
  # The upstream release. meta.version and every image tag default read it,
  # and crds/sources.txt fetches the CRDs of the same tag.
  release = "v1.21.2";

  minorOf = tag: builtins.match "v?([0-9]+)\\.([0-9]+)([^0-9].*)?" tag;
  releaseMinor = lib.take 2 (minorOf release);
in
{
  inherit release;

  who = scope: "cert-manager ${scope.namespaceName}/${scope.instanceName}";

  ports = {
    metrics = 9402;
    controllerHealthz = 9403;
    webhookHealthz = 6080;
  };

  # The three Deployment label sets are their immutable
  # spec.selector.matchLabels.
  labels = instanceName: {
    controller = {
      "app.kubernetes.io/name" = "cert-manager";
      "app.kubernetes.io/instance" = instanceName;
      "app.kubernetes.io/component" = "controller";
    };
    webhook = {
      "app.kubernetes.io/name" = "webhook";
      "app.kubernetes.io/instance" = instanceName;
      "app.kubernetes.io/component" = "webhook";
    };
    cainjector = {
      "app.kubernetes.io/name" = "cainjector";
      "app.kubernetes.io/instance" = instanceName;
      "app.kubernetes.io/component" = "cainjector";
    };
    startupapicheck = {
      "app.kubernetes.io/name" = "startupapicheck";
      "app.kubernetes.io/instance" = instanceName;
      "app.kubernetes.io/component" = "startupapicheck";
    };
  };

  controllerServiceName = instanceName: instanceName;
  webhookServiceName = instanceName: "${instanceName}-webhook";
  # The webhook writes its serving CA here; cainjector copies it into the
  # webhook configurations.
  caSecretName = instanceName: "${instanceName}-webhook-ca";

  # Returns `tag` when its major.minor is the release's. The CRDs and RBAC
  # are vendored from `release`, so a controller of another minor release
  # may need objects or permissions this package does not render.
  checkRelease =
    who: tag:
    let
      m = minorOf tag;
    in
    if m != null && lib.take 2 m == releaseMinor then
      tag
    else
      throw (
        "${who}: image.tag \"${tag}\" is not a v${lib.concatStringsSep "." releaseMinor} release, "
        + "and the CRDs and RBAC in kix/packages/cert-manager are vendored from ${release}. To move "
        + "to another release, change release in kix/packages/cert-manager/common.nix and run "
        + "uv run scripts/vendor-crds.py cert-manager."
      );

  podSecurityContext = {
    runAsNonRoot = true;
    seccompProfile.type = "RuntimeDefault";
  };

  containerSecurityContext = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
    readOnlyRootFilesystem = true;
  };
}

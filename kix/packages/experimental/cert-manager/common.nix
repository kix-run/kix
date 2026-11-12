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

  webhookServiceName = instanceName: "${instanceName}-webhook";
  # The webhook writes its serving CA here; cainjector copies it into the
  # webhook configurations.
  caSecretName = instanceName: "${instanceName}-webhook-ca";

  # Returns the image option at `path` (such as [ "webhook" "image" ]) of
  # the instance's config when its tag and the controller's `image.tag`
  # have the release's major.minor. The CRDs and RBAC are vendored from
  # `release`, and a component of another minor release may need objects
  # or permissions this package does not render. `image.tag` is checked
  # first, so a follower that inherits a bad tag reports `image.tag`.
  checkRelease =
    who: config: path:
    let
      minor = "v${lib.concatStringsSep "." releaseMinor}";
      check =
        option: rawTag:
        let
          tag = builtins.unsafeDiscardStringContext rawTag;
          m = minorOf tag;
          fix =
            if option == "image.tag" then
              "Set image.tag to a ${minor}.x tag such as ${release}."
            else
              "Set ${option} to a ${minor}.x tag such as ${release}, or remove it so it follows image.tag.";
        in
        if m != null && lib.take 2 m == releaseMinor then
          true
        else
          throw (
            "${who}: ${option} \"${tag}\" is not a ${minor} release, and the CRDs and RBAC in "
            + "kix/packages/experimental/cert-manager are vendored from ${release}. ${fix} To move the package to "
            + "another release, change release in kix/packages/experimental/cert-manager/common.nix and run "
            + "uv run scripts/vendor-crds.py cert-manager."
          );
      image = lib.getAttrFromPath path config;
    in
    assert check "image.tag" config.image.tag;
    assert check "${lib.concatStringsSep "." path}.tag" image.tag;
    image;

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

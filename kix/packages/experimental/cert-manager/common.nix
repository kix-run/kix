# Values the cert-manager component files share.

{ lib }:

let
  # The upstream release. meta.version and every image tag default read it,
  # and crds/sources.txt fetches the CRDs of the same tag.
  release = "v1.21.3";
in
{
  inherit release;

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

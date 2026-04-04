# Shared constants for cert-manager components.

{ instanceName }:
{
  controllerLabels = {
    "app.kubernetes.io/name" = "cert-manager";
    "app.kubernetes.io/instance" = instanceName;
    "app.kubernetes.io/component" = "controller";
  };

  webhookLabels = {
    "app.kubernetes.io/name" = "webhook";
    "app.kubernetes.io/instance" = instanceName;
    "app.kubernetes.io/component" = "webhook";
  };

  cainjectorLabels = {
    "app.kubernetes.io/name" = "cainjector";
    "app.kubernetes.io/instance" = instanceName;
    "app.kubernetes.io/component" = "cainjector";
  };

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

# cert-manager admission webhook configurations.
#
# Mutating and validating webhooks for cert-manager CRDs.
# These are long declarative structures that clutter the main resources.nix.

{
  kixlib',
  cfg,
  helpers,
  ...
}:

let
  inherit (helpers) webhookLabels;
in
{
  mutating = kixlib'.admission.mkMutatingWebhookConfiguration {
    metadata = {
      name = "cert-manager-webhook";
      labels = webhookLabels.all;
      annotations = {
        "cert-manager.io/inject-ca-from-secret" = "${cfg.namespace}/cert-manager-webhook-ca";
      };
    };
    webhooks = [
      {
        name = "webhook.cert-manager.io";
        rules = [
          {
            apiGroups = [ "cert-manager.io" ];
            apiVersions = [ "v1" ];
            operations = [ "CREATE" ];
            resources = [ "certificaterequests" ];
          }
        ];
        admissionReviewVersions = [ "v1" ];
        matchPolicy = "Equivalent";
        timeoutSeconds = cfg.webhook.timeoutSeconds;
        failurePolicy = "Fail";
        sideEffects = "None";
        clientConfig.service = {
          name = "cert-manager-webhook";
          namespace = cfg.namespace;
          path = "/mutate";
        };
      }
    ];
  };

  validating = kixlib'.admission.mkValidatingWebhookConfiguration {
    metadata = {
      name = "cert-manager-webhook";
      labels = webhookLabels.all;
      annotations = {
        "cert-manager.io/inject-ca-from-secret" = "${cfg.namespace}/cert-manager-webhook-ca";
      };
    };
    webhooks = [
      {
        name = "webhook.cert-manager.io";
        namespaceSelector.matchExpressions = [
          {
            key = "cert-manager.io/disable-validation";
            operator = "NotIn";
            values = [ "true" ];
          }
        ];
        rules = [
          {
            apiGroups = [
              "cert-manager.io"
              "acme.cert-manager.io"
            ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
            ];
            resources = [ "*/*" ];
          }
        ];
        admissionReviewVersions = [ "v1" ];
        matchPolicy = "Equivalent";
        timeoutSeconds = cfg.webhook.timeoutSeconds;
        failurePolicy = "Fail";
        sideEffects = "None";
        clientConfig.service = {
          name = "cert-manager-webhook";
          namespace = cfg.namespace;
          path = "/validate";
        };
      }
    ];
  };
}

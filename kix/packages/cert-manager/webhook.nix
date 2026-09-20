# cert-manager webhook — validates and mutates cert-manager resources via admission webhooks.

{
  self,
  config,
  clusterConfig,
  scope,
  lib,
}:
let
  common = import ./common.nix { instanceName = scope.instanceName; };
  name = scope.instanceName;
  ns = scope.namespaceName;

  inherit (scope.rbac)
    group
    core
    grant
    allow
    mkClusterRoleSet
    mkRoleSet
    ;

  authz = group "authorization.k8s.io" [ "subjectaccessreviews" ];

  mkWebhookSubject = [
    {
      kind = "ServiceAccount";
      name = self.webhookServiceAccount.out.name;
      namespace = ns;
    }
  ];

  webhookClusterRoles = mkClusterRoleSet scope {
    subjects = mkWebhookSubject;
    labels = common.webhookLabels;
    roles = {
      "${name}-webhook:subjectaccessreviews" = grant [
        (authz.subjectaccessreviews |> allow [ "create" ])
      ];
    };
  };

  webhookRoles = mkRoleSet scope {
    subjects = mkWebhookSubject;
    labels = common.webhookLabels;
    roles = {
      "${name}-webhook:dynamic-serving" = grant [
        (
          core.secrets
          |> scope.rbac.restrictTo [ "${name}-webhook-ca" ]
          |> allow [
            "get"
            "list"
            "watch"
            "update"
          ]
        )
        (core.secrets |> allow [ "create" ])
      ];
    };
  };

in
{
  # -- ServiceAccount --

  webhookServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-webhook";
    labels = common.webhookLabels;
    extra.automountServiceAccountToken = true;
  };

  # -- Service --

  webhookService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-webhook";
    labels = common.webhookLabels;
    spec = {
      type = "ClusterIP";
      selector = self.webhookDeployment.out.selector;
      ports = [
        {
          name = "https";
          port = 443;
          protocol = "TCP";
          targetPort = 10250;
        }
        {
          name = "metrics";
          port = 9402;
          protocol = "TCP";
          targetPort = 9402;
        }
      ];
    };
  };

  # -- Deployment --

  webhookDeployment =
    {
      name = "${name}-webhook";
      labels = common.webhookLabels;
      spec = {
        replicas = config.webhook.replicaCount;
        selector.matchLabels = common.webhookLabels;
        template = {
          metadata.annotations = {
            "prometheus.io/path" = "/metrics";
            "prometheus.io/scrape" = "true";
            "prometheus.io/port" = "9402";
          };
          spec = {
            serviceAccountName = self.webhookServiceAccount.out.name;
            enableServiceLinks = false;
            securityContext = common.podSecurityContext;
            containers = [
              {
                name = "cert-manager-webhook";
                image = "${config.webhook.image.repository}:${config.webhook.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                args = [
                  "--v=2"
                  "--secure-port=10250"
                  "--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)"
                  "--dynamic-serving-ca-secret-name=${name}-webhook-ca"
                  "--dynamic-serving-dns-names=${name}-webhook"
                  "--dynamic-serving-dns-names=${name}-webhook.$(POD_NAMESPACE)"
                  "--dynamic-serving-dns-names=${name}-webhook.$(POD_NAMESPACE).svc"
                ];
                ports = [
                  {
                    name = "https";
                    containerPort = 10250;
                    protocol = "TCP";
                  }
                  {
                    name = "healthcheck";
                    containerPort = 6080;
                    protocol = "TCP";
                  }
                  {
                    name = "http-metrics";
                    containerPort = 9402;
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  httpGet = {
                    path = "/livez";
                    port = 6080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 60;
                  periodSeconds = 10;
                  timeoutSeconds = 1;
                  successThreshold = 1;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = 6080;
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 5;
                  periodSeconds = 5;
                  timeoutSeconds = 1;
                  successThreshold = 1;
                  failureThreshold = 3;
                };
                securityContext = common.containerSecurityContext;
                env = [
                  {
                    name = "POD_NAMESPACE";
                    valueFrom.fieldRef = {
                      apiVersion = "v1";
                      fieldPath = "metadata.namespace";
                    };
                  }
                ];
              }
            ];
            nodeSelector = {
              "kubernetes.io/os" = "linux";
            };
          };
        };
      };
    }
    |> scope.mkDeployment;

  # -- Webhook configurations --

  mutatingWebhookConfiguration = scope.mkClusterResource {
    apiVersion = "admissionregistration.k8s.io/v1";
    kind = "MutatingWebhookConfiguration";
    name = "${name}-webhook";
    labels = common.webhookLabels;
    annotations = {
      "cert-manager.io/inject-ca-from-secret" = "${ns}/${name}-webhook-ca";
    };
    extra.webhooks = [
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
        timeoutSeconds = 30;
        failurePolicy = "Fail";
        sideEffects = "None";
        clientConfig.service = {
          name = self.webhookService.out.name;
          namespace = ns;
          path = "/mutate";
        };
      }
    ];
  };

  validatingWebhookConfiguration = scope.mkClusterResource {
    apiVersion = "admissionregistration.k8s.io/v1";
    kind = "ValidatingWebhookConfiguration";
    name = "${name}-webhook";
    labels = common.webhookLabels;
    annotations = {
      "cert-manager.io/inject-ca-from-secret" = "${ns}/${name}-webhook-ca";
    };
    extra.webhooks = [
      {
        name = "webhook.cert-manager.io";
        namespaceSelector = {
          matchExpressions = [
            {
              key = "cert-manager.io/disable-validation";
              operator = "NotIn";
              values = [ "true" ];
            }
          ];
        };
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
        timeoutSeconds = 30;
        failurePolicy = "Fail";
        sideEffects = "None";
        clientConfig.service = {
          name = self.webhookService.out.name;
          namespace = ns;
          path = "/validate";
        };
      }
    ];
  };
}
// webhookClusterRoles
// webhookRoles

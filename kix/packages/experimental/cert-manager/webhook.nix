# cert-manager webhook: validates and mutates cert-manager objects for the
# API server. It serves TLS from a CA it creates in the Secret
# common.caSecretName; cainjector copies that CA into the two webhook
# configurations.

{
  self,
  config,
  scope,
  lib,
  kix,
  availability,
  prometheus ? null,
  ...
}:
let
  common = import ./common.nix { inherit lib; };
  name = scope.instanceName;
  ns = scope.namespaceName;
  labels = (common.labels name).webhook;
  metricsOn = config.metrics.enabled && prometheus != null;

  inherit (config.webhook) securePort;
  # The serving certificate's DNS names are derived from this name rather
  # than read from self.webhookService.out.name, which would cycle through
  # the Service's selector on the Deployment.
  serviceName = common.webhookServiceName name;
  caSecret = common.caSecretName name;

  inherit (scope.rbac)
    group
    core
    grant
    allow
    restrictTo
    mkClusterRoleSet
    mkRoleSet
    ;

  authz = group "authorization.k8s.io" [ "subjectaccessreviews" ];

  subjects = [
    {
      kind = "ServiceAccount";
      name = self.webhookServiceAccount.out.name;
      namespace = ns;
    }
  ];

  webhookClusterRoles = mkClusterRoleSet scope {
    inherit subjects labels;
    roles."${name}-webhook:subjectaccessreviews" = grant [
      (authz.subjectaccessreviews |> allow [ "create" ])
    ];
  };

  webhookRoles = mkRoleSet scope {
    inherit subjects labels;
    roles."${name}-webhook:dynamic-serving" = grant [
      (
        core.secrets
        |> restrictTo [ caSecret ]
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

  # With failurePolicy Fail the API server refuses a matching write while
  # it cannot reach the webhook or verify its certificate.
  webhookConfig =
    {
      kind,
      path,
      extraHook ? { },
      rules,
    }:
    scope.mkClusterResource {
      apiVersion = "admissionregistration.k8s.io/v1";
      inherit kind;
      name = "${name}-webhook";
      inherit labels;
      annotations."cert-manager.io/inject-ca-from-secret" = "${ns}/${caSecret}";
      extra.webhooks = [
        (
          {
            name = "webhook.cert-manager.io";
            inherit rules;
            admissionReviewVersions = [ "v1" ];
            matchPolicy = "Equivalent";
            timeoutSeconds = 30;
            failurePolicy = "Fail";
            sideEffects = "None";
            clientConfig.service = {
              name = self.webhookService.out.name;
              namespace = ns;
              inherit path;
            };
          }
          // extraHook
        )
      ];
    };
in
{
  webhookServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-webhook";
    inherit labels;
    extra.automountServiceAccountToken = true;
  };

  webhookService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = serviceName;
    inherit labels;
    spec = {
      type = "ClusterIP";
      selector = self.webhookDeployment.out.selector;
      ports = [
        {
          name = "https";
          port = 443;
          protocol = "TCP";
          targetPort = securePort;
        }
      ]
      ++ lib.optional metricsOn {
        name = "metrics";
        port = common.ports.metrics;
        protocol = "TCP";
        targetPort = common.ports.metrics;
      };
    };
  };

  webhookDeployment =
    {
      name = "${name}-webhook";
      inherit labels;
      spec = {
        # In the write path of every cert-manager object and not
        # leader-elected, so from `pod` up a rolling restart keeps one
        # replica serving.
        replicas = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 2;
        };
        selector.matchLabels = labels;
        template.spec = {
          serviceAccount = self.webhookServiceAccount;
          # Kubernetes' default, set because the scorecard asks every
          # workload to set it.
          terminationGracePeriodSeconds = 30;
          enableServiceLinks = false;
          securityContext = common.podSecurityContext;
          containers = [
            {
              name = "cert-manager-webhook";
              image = kix.image.ref config.webhook.image;
              imagePullPolicy = config.webhook.image.pullPolicy;
              args = [
                "--v=2"
                "--secure-port=${toString securePort}"
                "--dynamic-serving-ca-secret-namespace=$(POD_NAMESPACE)"
                "--dynamic-serving-ca-secret-name=${caSecret}"
                "--dynamic-serving-dns-names=${serviceName}"
                "--dynamic-serving-dns-names=${serviceName}.$(POD_NAMESPACE)"
                "--dynamic-serving-dns-names=${serviceName}.$(POD_NAMESPACE).svc"
              ]
              ++ kix.guardArgs {
                inherit scope;
                option = "webhook.extraArgs";
                owned = {
                  "--secure-port" =
                    "the containerPort and the Service's targetPort use it; set webhook.securePort instead.";
                  "--dynamic-serving-ca-secret-name" =
                    "the CA injection annotation and the dynamic-serving Role name the same Secret; remove it.";
                  "--dynamic-serving-ca-secret-namespace" =
                    "the CA injection annotation and the dynamic-serving Role expect the CA Secret in the instance's namespace; remove it.";
                  "--dynamic-serving-dns-names" =
                    "the package sets the webhook Service's names, which the API server uses to reach the webhook; remove it.";
                };
              } config.webhook.extraArgs;
              ports = [
                {
                  name = "https";
                  containerPort = securePort;
                  protocol = "TCP";
                }
                {
                  name = "healthcheck";
                  containerPort = common.ports.webhookHealthz;
                  protocol = "TCP";
                }
                {
                  name = "http-metrics";
                  containerPort = common.ports.metrics;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/livez";
                  port = "healthcheck";
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
                  port = "healthcheck";
                  scheme = "HTTP";
                };
                initialDelaySeconds = 5;
                periodSeconds = 5;
                timeoutSeconds = 1;
                successThreshold = 1;
                failureThreshold = 3;
              };
              inherit (config.webhook) resources;
              securityContext = common.containerSecurityContext;
              env = [
                {
                  name = "POD_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
              ];
            }
          ];
          nodeSelector."kubernetes.io/os" = "linux";
        };
      };
    }
    |> scope.mkDeployment;

  mutatingWebhookConfiguration = webhookConfig {
    kind = "MutatingWebhookConfiguration";
    path = "/mutate";
    rules = [
      {
        apiGroups = [ "cert-manager.io" ];
        apiVersions = [ "v1" ];
        operations = [ "CREATE" ];
        resources = [ "certificaterequests" ];
      }
    ];
  };

  validatingWebhookConfiguration = webhookConfig {
    kind = "ValidatingWebhookConfiguration";
    path = "/validate";
    extraHook.namespaceSelector.matchExpressions = [
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
  };
}
// webhookClusterRoles
// webhookRoles

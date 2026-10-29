# External Secrets Operator admission webhook, cert-controller, and webhook check Job.

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
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    ns
    ports
    webhookServiceName
    certDir
    certControllerLeaseName
    webhookConfigNames
    labelsFor
    webhookLabels
    certControllerLabels
    podSecurityContext
    containerSecurityContext
    subjectsFor
    serviceAccount
    metricsServiceFor
    crdOf
    ;

  hasMetrics = config.metrics.enabled && prometheus != null;

  inherit (scope.rbac)
    group
    core
    grant
    watch
    allow
    emit
    restrictTo
    mkClusterRoleSet
    mkRoleSet
    ;
  es = group "external-secrets.io" [ ];
  admission = group "admissionregistration.k8s.io" [ "validatingwebhookconfigurations" ];
  apiext = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];
  discovery = group "discovery.k8s.io" [ "endpointslices" ];
  coord = group "coordination.k8s.io" [ "leases" ];

  # From cert-controller-rbac.yaml at the release tag, narrowed to the
  # calls the cert-controller makes: it reads Secrets uncached by name
  # and writes the certificate Secret only. It writes a definition
  # only when the definition has a conversion webhook, which none of
  # the vendored ones has, so it gets no write access to definitions.
  certControllerRbac = mkClusterRoleSet scope {
    subjects = subjectsFor self.certControllerServiceAccount;
    roles."${name}-cert-controller" = grant [
      (apiext.customresourcedefinitions |> watch)
      (admission.validatingwebhookconfigurations |> watch)
      (
        admission.validatingwebhookconfigurations
        |> restrictTo webhookConfigNames
        |> allow [
          "update"
          "patch"
        ]
      )
      (discovery.endpointslices |> watch)
      # Events about the cluster-scoped webhook configurations go to
      # the default namespace.
      (core.events |> emit)
    ];
  };

  certControllerRoles = mkRoleSet scope {
    subjects = subjectsFor self.certControllerServiceAccount;
    roles."${name}-cert-controller" = grant [
      (
        core.secrets
        |> restrictTo [ self.webhookCertSecret.out.name ]
        |> allow [
          "get"
          "update"
          "patch"
        ]
      )
      (coord.leases |> allow [ "create" ])
      (
        coord.leases
        |> restrictTo [ certControllerLeaseName ]
        |> allow [
          "get"
          "update"
          "patch"
        ]
      )
    ];
  };

  # The cert-controller injects the CA only into configurations with
  # this label (pkg/controllers/webhookconfig/webhookconfig.go), and
  # only into entries whose name ends in external-secrets.io.
  webhookConfig =
    configName: entries:
    scope.mkClusterResource {
      apiVersion = "admissionregistration.k8s.io/v1";
      kind = "ValidatingWebhookConfiguration";
      name = configName;
      labels."external-secrets.io/component" = "webhook";
      extra.webhooks = map (e: {
        name = "validate.${e.singular}.external-secrets.io";
        rules = [
          {
            apiGroups = [ "external-secrets.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
              "DELETE"
            ];
            resources = [ "${e.singular}s" ];
            inherit (e) scope;
          }
        ];
        clientConfig.service = {
          name = webhookServiceName;
          namespace = ns;
          path = "/validate-external-secrets-io-v1-${e.singular}";
        };
        admissionReviewVersions = [
          "v1"
          "v1beta1"
        ];
        sideEffects = "None";
        timeoutSeconds = 5;
        failurePolicy = "Fail";
      }) entries;
    };

  # The check: a server-side dry-run create of an ExternalSecret and of
  # a SecretStore, one per webhook configuration, since the
  # cert-controller injects the CA into each separately. With
  # failurePolicy Fail the API server admits each only after calling
  # the webhook and trusting its certificate, which also needs the CA
  # in that configuration. Until then kubectl fails and the Job
  # restarts the container.
  checkName = "${name}-webhook-check";
  checkLabels = labelsFor "webhook-check";
  # A fixed name would fail with AlreadyExists when an object of that
  # name exists.
  checkMetadata = {
    generateName = "${checkName}-";
    namespace = ns;
  };
  checkManifests = {
    "externalsecret.json" = builtins.toJSON {
      apiVersion = "external-secrets.io/v1";
      kind = "ExternalSecret";
      metadata = checkMetadata;
      spec = {
        secretStoreRef = {
          name = checkName;
          kind = "SecretStore";
        };
        data = [
          {
            secretKey = "check";
            remoteRef.key = "check";
          }
        ];
      };
    };
    # The fake provider needs no credentials; its webhook validation
    # requires a non-empty key and value in each entry.
    "secretstore.json" = builtins.toJSON {
      apiVersion = "external-secrets.io/v1";
      kind = "SecretStore";
      metadata = checkMetadata;
      spec.provider.fake.data = [
        {
          key = "check";
          value = "check";
        }
      ];
    };
  };
in
{
  webhookServiceAccount = serviceAccount "${name}-webhook";
  certControllerServiceAccount = serviceAccount "${name}-cert-controller";

  certControllerClusterRole = certControllerRbac."${name}-cert-controller";
  certControllerClusterRoleBinding = certControllerRbac."${name}-cert-controller-binding";
  certControllerRole = certControllerRoles."${name}-cert-controller";
  certControllerRoleBinding = certControllerRoles."${name}-cert-controller-binding";

  # Empty at creation; the cert-controller writes ca.crt, ca.key,
  # tls.crt, and tls.key into it and never creates it.
  webhookCertSecret = scope.mkSecret {
    name = "${name}-webhook-tls";
    keys = [ ];
  };

  webhookDeployment =
    kix.withMounts
      [
        (kix.mount.secret self.webhookCertSecret {
          name = "certs";
          mountPath = certDir;
        })
      ]
      {
        name = "${name}-webhook";
        spec = {
          replicas = kix.availability.pick availability {
            none = 1;
            pod = 2;
            node = 2;
            zone = 2;
          };
          selector.matchLabels = webhookLabels;
          template.spec = {
            serviceAccount = self.webhookServiceAccount;
            terminationGracePeriodSeconds = 30;
            securityContext = podSecurityContext;
            containers = [
              {
                name = "webhook";
                image = kix.image.ref config.image;
                imagePullPolicy = config.image.pullPolicy;
                args = [
                  "webhook"
                  "--port=${toString ports.webhook}"
                  "--dns-name=${webhookServiceName}.$(POD_NAMESPACE).svc"
                  "--cert-dir=${certDir}"
                  "--metrics-addr=:${toString ports.metrics}"
                  "--healthz-addr=:${toString ports.webhookHealth}"
                ];
                env = [
                  {
                    name = "POD_NAMESPACE";
                    valueFrom.fieldRef.fieldPath = "metadata.namespace";
                  }
                ];
                ports = [
                  (kix.port "metrics" ports.metrics)
                  (kix.port "webhook" ports.webhook)
                  (kix.port "ready" ports.webhookHealth)
                ];
                # The health server starts only after the webhook has
                # waited up to 2 minutes for a valid certificate in
                # certDir (waitForCerts in cmd/controller/webhook.go),
                # so the startup probe allows 150 s before liveness
                # applies.
                startupProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = "ready";
                  };
                  periodSeconds = 5;
                  failureThreshold = 30;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = "ready";
                  };
                  periodSeconds = 5;
                };
                # Ready once the certificate in certDir is valid for
                # the Service name.
                readinessProbe = {
                  httpGet = {
                    path = "/readyz";
                    port = "ready";
                  };
                  initialDelaySeconds = 20;
                  periodSeconds = 5;
                };
                resources = config.webhook.resources;
                securityContext = containerSecurityContext;
              }
            ];
          };
        };
      }
    |> scope.mkDeployment;

  # Also the webhook's metrics Service, so no second Service carries
  # the webhook's labels.
  webhookService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = webhookServiceName;
    labels = webhookLabels;
    spec = {
      selector = self.webhookDeployment.out.selector;
      ports = [
        {
          name = "webhook";
          port = 443;
          targetPort = ports.webhook;
          protocol = "TCP";
        }
      ]
      ++ lib.optional hasMetrics {
        name = "metrics";
        port = ports.metrics;
        targetPort = ports.metrics;
        protocol = "TCP";
      };
    };
  };

  secretStoreWebhook = webhookConfig (builtins.elemAt webhookConfigNames 0) [
    {
      singular = "secretstore";
      scope = "Namespaced";
    }
    {
      singular = "clustersecretstore";
      scope = "Cluster";
    }
  ];
  externalSecretWebhook = webhookConfig (builtins.elemAt webhookConfigNames 1) [
    {
      singular = "externalsecret";
      scope = "Namespaced";
    }
  ];

  # Its readiness waits for the webhook pods' endpoints, so it does not
  # require the webhook Deployment, whose pods wait for the
  # certificate it writes.
  certControllerDeployment = scope.mkDeployment {
    name = "${name}-cert-controller";
    requires = [
      self.secretStoreWebhook
      self.externalSecretWebhook
    ];
    spec = {
      replicas = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      selector.matchLabels = certControllerLabels;
      template.spec = {
        serviceAccount = self.certControllerServiceAccount;
        terminationGracePeriodSeconds = 30;
        securityContext = podSecurityContext;
        containers = [
          {
            name = "cert-controller";
            image = kix.image.ref config.image;
            imagePullPolicy = config.image.pullPolicy;
            args = [
              "certcontroller"
              "--service-name=${webhookServiceName}"
              "--service-namespace=${ns}"
              "--secret-name=${self.webhookCertSecret.out.name}"
              "--secret-namespace=${ns}"
              "--metrics-addr=:${toString ports.metrics}"
              "--healthz-addr=:${toString ports.webhookHealth}"
              "--enable-leader-election=true"
              # Caches only definitions labelled
              # external-secrets.io/component=controller and webhook
              # configurations labelled =webhook, instead of every one
              # in the cluster.
              "--enable-partial-cache=true"
            ];
            ports = [
              (kix.port "metrics" ports.metrics)
              (kix.port "ready" ports.webhookHealth)
            ];
            livenessProbe = {
              httpGet = {
                path = "/healthz";
                port = "ready";
              };
              initialDelaySeconds = 20;
              periodSeconds = 5;
            };
            readinessProbe = {
              httpGet = {
                path = "/readyz";
                port = "ready";
              };
              initialDelaySeconds = 20;
              periodSeconds = 5;
            };
            resources = config.certController.resources;
            securityContext = containerSecurityContext;
          }
        ];
      };
    };
  };

  certControllerMetricsService =
    metricsServiceFor hasMetrics self.certControllerDeployment
      certControllerLabels;

  webhookCheckServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = checkName;
    labels = checkLabels;
    extra.automountServiceAccountToken = true;
  };

  # A dry-run create needs the create verb; the API server persists
  # nothing.
  webhookCheckRbac = mkRoleSet scope {
    subjects = subjectsFor self.webhookCheckServiceAccount;
    labels = checkLabels;
    roles.${checkName} = grant [
      (
        map es [
          "externalsecrets"
          "secretstores"
        ]
        |> allow [ "create" ]
      )
    ];
  };

  webhookCheckManifest = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = checkName;
    labels = checkLabels;
    data = checkManifests;
  };

  webhookCheck =
    kix.withMounts
      [
        (kix.mount.configMap self.webhookCheckManifest {
          name = "manifest";
          mountPath = "/check";
          readOnly = true;
        })
        (kix.mount.emptyDir {
          name = "tmp";
          mountPath = "/tmp";
        })
      ]
      {
        name = checkName;
        labels = checkLabels;
        # A Job's pod template is immutable, so a changed check
        # replaces the Job.
        annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
        requires = [
          self.webhookDeployment
          self.webhookService
          self.certControllerDeployment
          self.secretStoreWebhook
          self.externalSecretWebhook
          (crdOf self "ExternalSecret")
          (crdOf self "SecretStore")
        ]
        ++ builtins.attrValues self.webhookCheckRbac;
        spec = {
          # The container restarts with the kubelet's back-off (10 s,
          # doubling, capped at 300 s), so six restarts wait about ten
          # minutes for the cert-controller to inject the CA.
          backoffLimit = 6;
          template = {
            metadata = {
              labels = checkLabels;
              annotations."checksum/manifest" = self.webhookCheckManifest.out.identityHash;
            };
            spec = {
              restartPolicy = "OnFailure";
              serviceAccount = self.webhookCheckServiceAccount;
              enableServiceLinks = false;
              # The kubectl image declares user 0.
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65532;
                runAsGroup = 65532;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                (
                  {
                    name = "webhook-check";
                    image = kix.image.ref config.webhookCheck.image;
                    args = [
                      "create"
                      "--dry-run=server"
                    ]
                    ++ map (f: "--filename=/check/${f}") (builtins.attrNames checkManifests)
                    ++ [
                      "--output=name"
                    ];
                    # kubectl writes its discovery cache under $HOME.
                    env = [
                      {
                        name = "HOME";
                        value = "/tmp";
                      }
                    ];
                    securityContext = containerSecurityContext;
                    # A ResourceQuota on requests or limits refuses a
                    # pod that does not set them, and every custom
                    # resource built from `out` waits on this Job.
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "32Mi";
                      };
                      limits = {
                        cpu = "200m";
                        memory = "128Mi";
                      };
                    };
                  }
                  // lib.optionalAttrs (config.webhookCheck.image.pullPolicy != null) {
                    imagePullPolicy = config.webhookCheck.image.pullPolicy;
                  }
                )
              ];
            };
          };
        };
      }
    |> scope.mkJob;
}

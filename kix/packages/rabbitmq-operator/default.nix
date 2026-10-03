# rabbitmq-operator: the RabbitMQ Cluster Kubernetes Operator, which runs
# RabbitMQ clusters declared as rabbitmq.com RabbitmqCluster resources.
#
# The package applies the RabbitmqCluster CustomResourceDefinition (crds/,
# vendored from the release manifest), the operator's ClusterRole and
# leader-election Role (rbac/, from the same manifest), the operator
# Deployment, the webhook Service, the mutating and validating webhook
# configurations, and a self-signed cert-manager Issuer and Certificate for
# the webhook server. cert-manager's cainjector copies the Certificate's CA
# into each webhook entry's `clientConfig.caBundle`, which Kix never sets.
#
# Both webhook entries have failurePolicy Fail, and until cainjector has
# written the caBundle the API server cannot call them, so a RabbitmqCluster
# created in that window is refused. The RabbitmqCluster handle in
# `out.crds` therefore adds the webhook-check Job to the requires of each
# custom resource built from it. The Job runs a server-side dry-run create
# of a RabbitmqCluster, which succeeds only once both webhooks answer. The
# validating webhook refuses a RabbitmqCluster whose
# `spec.override.statefulSet` asks for host access or privileges
# (internal/webhook/v1beta1/rabbitmqcluster_webhook.go upstream).
#
# A cluster runs one instance (`conflictsWith`): the definition and the
# webhook configurations are cluster-wide, and the operator's
# leader-election lease name is fixed in the binary (cmd/main.go upstream).
# The operator watches every namespace, as upstream ships it;
# OPERATOR_SCOPE_NAMESPACE is refused because the ClusterRole and the
# webhooks stay cluster-wide.
#
# Minimal instance, with cert-manager elsewhere in the cluster:
#
#   instances.rabbitmq-system.rabbitmq-operator.package = packages.rabbitmq-operator;
#
# DI deps:
#   certManager (required)  the cert-manager instance whose Issuer and
#                           Certificate handles the package builds from.
#   prometheus (optional)   a metrics Service and ServiceMonitor for the
#                           operator's metrics (TCP 8080) while
#                           `metrics.enabled`.
#
# Replicas: one at availability none and pod, two from node up. The
# replicas elect a leader for reconciling, and each serves the webhooks.
#
# Escape hatches: `env` (operator variables from cmd/main.go upstream, such
# as LEASE_DURATION or DEFAULT_IMAGE_PULL_SECRETS), `webhookCheck.image`,
# and the instance's `partsOverlays`.
#
# Exposes:
#   out.crds.RabbitmqCluster  the CRD handle for scope.mkCR. Use the
#                             rabbitmq-cluster package rather than building
#                             RabbitmqClusters directly.
#   out.operandSelectors.cluster crName
#                             the labels of a RabbitmqCluster's pods.
#   out.podSelector           the operator pods' labels.
#   out.release               the operator release.
#
# Network policy: the webhook intent admits the API server on TCP 9443 to
# every pod of the package, the webhook-check Job's included, where nothing
# listens on that port. The operator's traffic to the RabbitMQ pods comes
# from rabbitmq-cluster.
#
# Limits: the package ships no alerts. The operator's metrics endpoint is
# served over plain HTTP (`--metrics-secure` is off, as upstream ships it).
#
# root = the operator Deployment; the webhook check runs after it.
#
# Moving to another release: set `release` and the digest of `image`
# (`crane digest ghcr.io/rabbitmq/cluster-operator:<release>`), move the tag
# in crds/sources.txt and rbac/sources.txt, run
# `uv run scripts/vendor-crds.py rabbitmq-operator`, compare the webhook
# entries below and the Deployment with the release manifest, then run the
# kix-lib test rabbitmq-operator-sources-match-release and
# every-package-evaluates.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # meta.version, the default image.tag, and the tag in crds/sources.txt and
  # rbac/sources.txt.
  release = "2.23.0";
  minorOf = lib.versions.majorMinor;

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "rabbitmq-operator ${ns}/${name}";

  group = "rabbitmq.com";
  readJSON = file: builtins.fromJSON (builtins.readFile file);

  podLabels = scope.selectorLabels;

  # controller-runtime's defaults, which the operator keeps.
  webhookPort = 9443;
  metricsPort = 8080;
  healthPort = 8081;
  certDir = "/tmp/k8s-webhook-server/serving-certs";

  # The Service the webhook entries call, and the name the Certificate is
  # issued for. Plain names: the Deployment mounts the Certificate's Secret
  # and the Service selects the Deployment's pods, so a reference to the
  # Service would close a cycle.
  webhookServiceName = "${name}-webhook";
  certificateName = "${name}-webhook";
  certSecretName = "${name}-webhook-tls";

  # Every pod of a RabbitmqCluster carries these labels
  # (internal/metadata/label.go upstream). The operator drops a
  # RabbitmqCluster's own app.kubernetes.io labels when it copies them to
  # its children, so these three come only from the operator.
  operandSelectors.cluster = crName: {
    "app.kubernetes.io/name" = crName;
    "app.kubernetes.io/component" = "rabbitmq";
    "app.kubernetes.io/part-of" = "rabbitmq";
  };

  fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };
in
{
  meta = {
    version = release;
    description = "RabbitMQ Cluster Operator: runs RabbitMQ clusters declared as rabbitmq.com RabbitmqCluster resources";
    owner = "platform";
    defaultAliases = [ "rabbitmqOperator" ];
    conflictsWith = [ "cluster:rabbitmqOperator" ];
    # The operator reads rabbitmq.com annotations on RabbitmqClusters
    # (api/v1beta1/rabbitmqcluster_types.go upstream).
    annotationDomains = [ "rabbitmq.com" ];
    # The definition carries a CEL validation rule, which the API server
    # enforces by default from 1.25.
    k8s.minVersion = "1.25";
    network.intents.webhooks.ingress = [
      {
        from = "apiserver";
        ports = [
          {
            port = webhookPort;
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = minorOf config.image.tag == minorOf release;
        message = "image.tag \"${config.image.tag}\" is not a RabbitMQ Cluster Operator ${minorOf release} release, and the definition under kix/packages/rabbitmq-operator/crds and the roles under rbac are vendored from ${release}. Set image.tag to a ${minorOf release}.x tag, or move the package to another release as its header describes.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "ghcr.io/rabbitmq/cluster-operator";
      tag = release;
      digest = "sha256:9236fb4f559bb6c4a04605fdf9aa1c03d00573df2d4da43c71e11b296e0a1886";
      description = "Operator image. Its major.minor must be the package's release.";
    };

    # The release manifest's values.
    resources = kix.options.resources {
      requests = {
        cpu = "200m";
        memory = "500Mi";
      };
      limits = {
        cpu = "200m";
        memory = "500Mi";
      };
    };

    metrics = kix.options.monitor;

    webhookCheck.image = kix.options.image {
      repository = "registry.k8s.io/kubectl";
      tag = "v1.37.1";
      digest = "sha256:b7cab618e281b1ee7484e7b706a96e2135fbb6e072c2a573a7dab4e87d7f2385";
      description = "Image of the webhook-check Job. Its entrypoint must be kubectl.";
    };

    env = kix.options.env // {
      description = "Extra operator environment variables from the operator's cmd/main.go, such as LEASE_DURATION or DEFAULT_IMAGE_PULL_SECRETS. A value is a string, a `fieldRef`, or `kix.untrackedRef`. The variables the package sets or refuses fail with the reason.";
    };
  };

  build = [
    (
      {
        self,
        config,
        certManager,
        prometheus ? null,
        ...
      }:
      let
        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            owned = [
              {
                vars.OPERATOR_NAMESPACE = fieldRef "metadata.namespace";
                from = "the instance's namespace";
                fix = "Remove it.";
              }
              {
                names = [ "OPERATOR_SCOPE_NAMESPACE" ];
                from = "this package, which leaves it unset so the operator watches every namespace";
                fix = "The ClusterRole and the webhooks stay cluster-wide, and a cluster runs one RabbitMQ Cluster Operator. Remove it.";
              }
              {
                names = [ "ENABLE_WEBHOOKS" ];
                from = "this package: the webhook configurations it renders have failurePolicy Fail, so with the webhooks off the API server refuses every RabbitmqCluster write";
                fix = "Remove it.";
              }
              {
                names = [ "CONTROL_RABBITMQ_IMAGE" ];
                from = "this package: the operator would replace the image each RabbitmqCluster names with its own default";
                fix = "Set image on the rabbitmq-cluster instance instead.";
              }
            ];
          } config.env
        );

        certCrds =
          certManager.out.crds
            or (throw "${who}: the certManager dependency has no out.crds, as with an import. Wire a managed cert-manager instance with deps.certManager = ref.<namespace>.<instance>.");

        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];

        webhookEntry = type: {
          name = "${if type == "mutate" then "m" else "v"}rabbitmqcluster-v1beta1.kb.io";
          admissionReviewVersions = [ "v1" ];
          clientConfig.service = {
            name = webhookServiceName;
            namespace = ns;
            path = "/${type}-rabbitmq-com-v1beta1-rabbitmqcluster";
            port = 443;
          };
          failurePolicy = "Fail";
          rules = [
            {
              apiGroups = [ group ];
              apiVersions = [ "v1beta1" ];
              operations = [
                "CREATE"
                "UPDATE"
              ];
              resources = [ "rabbitmqclusters" ];
            }
          ];
          sideEffects = "None";
        };
        # cainjector reads the Certificate named here and writes its CA into
        # every entry's caBundle.
        injectCa."cert-manager.io/inject-ca-from" = "${ns}/${certificateName}";

        # The webhook check. A dry-run create of a RabbitmqCluster succeeds
        # only when the API server can call both webhooks and trusts the
        # certificate. kubectl exits non-zero otherwise, and the Job retries.
        checkName = "${name}-webhook-check";
        checkLabels."app.kubernetes.io/name" = checkName;
        checkFile = "rabbitmqcluster.json";
        checkCluster = builtins.toJSON {
          apiVersion = "${group}/v1beta1";
          kind = "RabbitmqCluster";
          # A fixed name fails the dry-run when a RabbitmqCluster of that
          # name exists.
          metadata = {
            generateName = "${checkName}-";
            namespace = ns;
          };
          spec.replicas = 1;
        };

        withCheck = args: args // { requires = (args.requires or [ ]) ++ [ self.webhookCheck ]; };
        gate =
          crd:
          crd
          // {
            out = crd.out // {
              cr = args: crd.out.cr (withCheck args);
              mkCR = consumerScope: args: crd.out.mkCR consumerScope (withCheck args);
            };
          };

        probe = path: {
          httpGet = {
            inherit path;
            port = healthPort;
          };
        };
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        clusterRole = scope.rbac.mkClusterRoleSet scope {
          inherit subjects;
          roles.${name} = (readJSON ./rbac/clusterrole-rabbitmq-cluster-operator-role.json).rules;
        };

        leaderElectionRole = scope.rbac.mkRoleSet scope {
          inherit subjects;
          roles."${name}-leader-election" =
            (readJSON ./rbac/role-rabbitmq-cluster-leader-election-role.json).rules;
        };

        crds.rabbitmqClusters = gate (
          scope.mkCRD {
            spec = (readJSON ./crds/rabbitmqclusters.rabbitmq.com.json).spec;
            # The condition carries no observedGeneration
            # (internal/status/all_replicas_ready.go upstream), so right
            # after a spec change the deploy can read the previous status.
            readiness.condition = {
              type = "AllReplicasReady";
              status = "True";
            };
          }
        );

        issuer = scope.mkCR certCrds.Issuer {
          name = "${name}-selfsigned";
          spec.selfSigned = { };
        };

        certificate = scope.mkCR certCrds.Certificate {
          name = certificateName;
          spec = {
            secretName = certSecretName;
            # The API server calls the webhook at this name.
            dnsNames = [ "${webhookServiceName}.${ns}.svc" ];
            usages = [ "server auth" ];
            issuerRef = {
              group = "cert-manager.io";
              kind = "Issuer";
              name = self.issuer.out.name;
            };
          };
        };

        webhookService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = webhookServiceName;
          labels."app.kubernetes.io/component" = "webhook";
          spec = {
            selector = self.deployment.out.selector;
            ports = [
              {
                name = "webhook";
                port = 443;
                targetPort = webhookPort;
                protocol = "TCP";
              }
            ];
          };
        };

        mutatingWebhook = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "MutatingWebhookConfiguration";
          name = "${name}-${ns}";
          annotations = injectCa;
          requires = [ self.certificate ];
          extra.webhooks = [ (webhookEntry "mutate") ];
        };
        validatingWebhook = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "ValidatingWebhookConfiguration";
          name = "${name}-${ns}";
          annotations = injectCa;
          requires = [ self.certificate ];
          extra.webhooks = [ (webhookEntry "validate") ];
        };

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.deployment
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              labels."app.kubernetes.io/component" = "metrics";
              ports = [
                {
                  name = "metrics";
                  port = metricsPort;
                  targetPort = "metrics";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        deployment = scope.mkDeployment {
          inherit name;
          requires = [
            self.crds.rabbitmqClusters
          ]
          ++ builtins.attrValues self.clusterRole
          ++ builtins.attrValues self.leaderElectionRole;
          spec = {
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 1;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = podLabels;
            template = {
              metadata.labels = podLabels;
              spec = {
                serviceAccount = self.serviceAccount;
                # The release manifest's value.
                terminationGracePeriodSeconds = 10;
                securityContext = {
                  runAsNonRoot = true;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = [
                  (
                    {
                      name = "operator";
                      image = kix.image.ref config.image;
                      command = [ "/manager" ];
                      args = [
                        "--health-probe-bind-address=:${toString healthPort}"
                        "--metrics-bind-address=:${toString metricsPort}"
                      ];
                      inherit env;
                      ports = [
                        (kix.port "metrics" metricsPort)
                        (kix.port "webhook-server" webhookPort)
                        (kix.port "health" healthPort)
                      ];
                      # The readiness check includes the webhook server's
                      # (cmd/main.go upstream).
                      livenessProbe = probe "/healthz" // {
                        initialDelaySeconds = 15;
                        periodSeconds = 20;
                      };
                      readinessProbe = probe "/readyz" // {
                        initialDelaySeconds = 5;
                        periodSeconds = 10;
                      };
                      resources = config.resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        capabilities.drop = [ "ALL" ];
                        readOnlyRootFilesystem = true;
                      };
                      volumeMounts = [
                        {
                          name = "webhook-certificates";
                          mountPath = certDir;
                          readOnly = true;
                        }
                      ];
                    }
                    // lib.optionalAttrs (config.image.pullPolicy != null) {
                      imagePullPolicy = config.image.pullPolicy;
                    }
                  )
                ];
                volumes = [
                  {
                    name = "webhook-certificates";
                    secret.secretName = kix.untrackedRef {
                      kind = "Secret";
                      name = certSecretName;
                      by = self.certificate;
                    };
                  }
                ];
              };
            };
          };
        };

        webhookCheckServiceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = checkName;
          labels = checkLabels;
          extra.automountServiceAccountToken = true;
        };

        # A dry-run create needs the create verb; the API server persists
        # nothing.
        webhookCheckRole = scope.rbac.mkRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.webhookCheckServiceAccount.out.name;
              namespace = ns;
            }
          ];
          labels = checkLabels;
          roles.${checkName} = scope.rbac.grant [
            (scope.rbac.allow [ "create" ] (scope.rbac.group group [ "rabbitmqclusters" ]).rabbitmqclusters)
          ];
        };

        webhookCheckManifest = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = checkName;
          labels = checkLabels;
          data.${checkFile} = checkCluster;
        };

        webhookCheckMount = kix.mount.configMap self.webhookCheckManifest {
          mountPath = "/check";
          readOnly = true;
        };

        webhookCheck =
          {
            name = checkName;
            labels = checkLabels;
            # A Job's pod template is immutable, so a changed check replaces
            # the Job.
            annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
            requires = [
              self.deployment
              self.webhookService
              self.mutatingWebhook
              self.validatingWebhook
              self.crds.rabbitmqClusters
            ]
            ++ builtins.attrValues self.webhookCheckRole;
            spec = {
              # The kubelet restarts the container with a growing delay (10 s
              # doubling to 5 min), so eight attempts span about 15 minutes.
              backoffLimit = 8;
              template = {
                metadata.labels = checkLabels;
                spec = {
                  restartPolicy = "OnFailure";
                  serviceAccount = self.webhookCheckServiceAccount;
                  enableServiceLinks = false;
                  # The image's default user is root; kubectl needs none.
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
                          "--output=name"
                          "--filename=/check/${checkFile}"
                        ];
                        # kubectl writes its discovery cache under $HOME.
                        env = [
                          {
                            name = "HOME";
                            value = "/tmp";
                          }
                        ];
                        securityContext = {
                          allowPrivilegeEscalation = false;
                          capabilities.drop = [ "ALL" ];
                          readOnlyRootFilesystem = true;
                        };
                        # A ResourceQuota on requests or limits refuses a pod
                        # that does not set them, and every RabbitmqCluster
                        # waits on this Job.
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
                        volumeMounts = [
                          {
                            name = "tmp";
                            mountPath = "/tmp";
                          }
                        ];
                      }
                      // lib.optionalAttrs (config.webhookCheck.image.pullPolicy != null) {
                        imagePullPolicy = config.webhookCheck.image.pullPolicy;
                      }
                    )
                  ];
                  volumes = [
                    {
                      name = "tmp";
                      emptyDir = { };
                    }
                  ];
                };
              };
            };
          }
          |> kix.withMounts [ self.webhookCheckMount ]
          |> scope.mkJob;

        root = {
          resource = self.deployment;
          requires = [
            self.webhookService
          ]
          ++ builtins.filter (r: r != null) [
            self.metricsService
            (self.serviceMonitor or null)
            (self.prometheusRules or null)
          ];
          postHooks = [ self.webhookCheck ];
          out = {
            crds.RabbitmqCluster = self.crds.rabbitmqClusters;
            inherit operandSelectors release;
            podSelector = self.deployment.out.selector;
          };
        };
      }
    )

    # DI passes a build function only the arguments its formals name, so
    # the wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor { service = "metricsService"; } args
    )
  ];
}

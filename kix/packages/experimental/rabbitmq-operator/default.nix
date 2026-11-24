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
#   instances.rabbitmq-system.rabbitmq-operator.package = packages.experimental.rabbitmq-operator;
#
# Dependencies:
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
# `out`:
#   out.crds.RabbitmqCluster  the CRD handle for scope.mkCR. Use the
#                             rabbitmq-cluster package rather than building
#                             RabbitmqClusters directly.
#   out.operandSelectors.cluster crName
#                             the labels of a RabbitmqCluster's pods.
#   out.podSelector           the operator pods' labels.
#   out.release               the operator release.
#   out.version               the operator version `image.tag` names.
#
# Network policy: the webhook intent admits the API server on TCP 9443 to
# every pod of the package, the webhook-check Job's included, where nothing
# listens on that port. The operator's traffic to the RabbitMQ pods comes
# from rabbitmq-cluster.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   RabbitMQOperatorDown (warning)             no operator replica answers
#                                              a scrape. Running clusters
#                                              keep serving; RabbitmqCluster
#                                              changes are not applied, and
#                                              the webhooks refuse creates
#                                              and updates.
#   RabbitMQOperatorReconcileErrors (warning)  reconciles fail, such as
#                                              `FailedReconcilePVC`.
# Changes the operator refuses without an error (`UnsupportedOperation` on
# a lower replica count) set only a condition and an Event, so no metric
# shows them. Fewer ready replicas than desired is left to
# prometheus-default-rules (KubeDeploymentReplicasMismatch).
#
# Limits: the operator's metrics endpoint is served over plain HTTP
# (`--metrics-secure` is off, as upstream ships it).
#
# root = the operator Deployment; the webhook check runs after it.
#
# Upgrades: the 2.23.3 operator runs on the RabbitmqClusters and pods that
# 2.23.0 left behind. Its CRD adds the /scale subresource and some schema
# fields, and no RabbitMQ pod restarted in the kind test. Upstream states no
# upgrade path between patch releases, so the direct step from 2.23.0 was
# tested only on kind. Going back also works in that test: the 2.23.0
# package applied over 2.23.3 kept the data and the clusters ready, and the
# CRD lost the /scale subresource. To go back, deploy a Kix release whose
# rabbitmq-operator package pins 2.23.0.
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
  release = "2.23.3";

  name = scope.instanceName;
  ns = scope.namespaceName;

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
  # The metrics Service, whose name the alerts select on.
  metricsServiceName = "${name}-metrics";

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
    # The README's Compatibility section requires Kubernetes 1.31 or later
    # and states no upper bound.
    k8s = {
      minVersion = "1.31";
      reason = "[K5618] RabbitMQ Cluster Operator ${release} requires Kubernetes 1.31 or later. Move the cluster to Kubernetes 1.31 or later, or use a Kix release whose rabbitmq-operator package still accepts it";
    };
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
      (kix.image.checkRelease {
        inherit (config) image;
        inherit release;
        reason = "the CRD in kix/packages/experimental/rabbitmq-operator/crds and the RBAC roles in its rbac directory come from RabbitMQ Cluster Operator ${release}";
        fix = "To update this package to another version, follow the instructions at the top of kix/packages/experimental/rabbitmq-operator/default.nix.";
      })
    ];

  options = {
    image = kix.options.image {
      repository = "ghcr.io/rabbitmq/cluster-operator";
      tag = release;
      digest = "sha256:487c7566e5341f00d17e5c2fd079b76a49869dd6d51081371c396f32dbbf5c6a";
      description = "Operator image. Its major.minor must be the package's release.";
    };

    # Requests and the memory limit are the release manifest's values. The
    # manifest also caps CPU at its 200m request, which throttles the
    # operator whenever it reconciles many objects at once; the limit here
    # lets it burst to one core.
    resources = kix.options.resources {
      requests = {
        cpu = "200m";
        memory = "500Mi";
      };
      limits = {
        cpu = "1";
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
            inherit scope;
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
          certManager.out.crds or (scope.fail {
            package = "rabbitmq-operator";
            message = "the certManager dependency has no out.crds, as with an import.";
            fix = "Wire a managed cert-manager instance with deps.certManager = ref.<namespace>.<instance>.";
          });

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

        crds.rabbitmqClusters =
          let
            crdSpec = (readJSON ./crds/rabbitmqclusters.rabbitmq.com.json).spec;
            specSchema = (builtins.head crdSpec.versions).schema.openAPIV3Schema.properties.spec.properties;
            defaultResources = specSchema.resources.default;
            defaultStorage = specSchema.persistence.properties.storage.default;
          in
          scope.mkCRD {
            spec = crdSpec;
            # Every RabbitmqCluster waits for the webhook check.
            crRequires = [ self.webhookCheck ];
            # Durable queues and messages live on the server pods' volumes.
            holdsData = true;
            # The condition carries no observedGeneration, so the deploy
            # judges it by status.observedGeneration, which the operator
            # advances only after a reconcile succeeds
            # (internal/controller/rabbitmqcluster_controller.go upstream).
            # A change the operator refuses waits until the deploy times
            # out; rabbitmq-cluster's header lists those changes.
            readiness.condition = {
              type = "AllReplicasReady";
              status = "True";
            };
            # Count `spec.replicas` server pods (default 1), or
            # `spec.override.statefulSet.spec.replicas` when set, unless
            # reconciliation is paused via the
            # `rabbitmq.com/pauseReconciliation = "true"` label. Each pod has
            # the `rabbitmq` container, sized by `spec.resources` (or the CRD
            # schema default when unset) under its entry in the StatefulSet
            # override, and every other container the override adds. Each
            # pod has one claim of `spec.persistence.storage` (the CRD schema
            # default when unset, none when it is 0), unless the override
            # sets `volumeClaimTemplates`, which can change it. The operator
            # makes two Services: the client Service and the headless one.
            usesAtLeast =
              cr:
              let
                spec = cr.spec or { };
                sts = spec.override.statefulSet.spec or { };
                containers = sts.template.spec.containers or [ ];
                patch = lib.findFirst (c: (c.name or null) == "rabbitmq") { } containers;
                extra = builtins.filter (c: (c.name or null) != "rabbitmq") containers;
                paused = (cr.metadata.labels or { })."rabbitmq.com/pauseReconciliation" or null == "true";
                pods = sts.replicas or spec.replicas or 1;
                storage = spec.persistence.storage or defaultStorage;
                claimed = !(sts ? volumeClaimTemplates) && kix.parseQuantity "memory" storage > 0;
              in
              if paused then
                { }
              else
                kix.usage.add (
                  [
                    (kix.usage.times pods (
                      kix.usage.ofPod (
                        [
                          {
                            resources = lib.recursiveUpdate (spec.resources or defaultResources) (patch.resources or { });
                          }
                        ]
                        ++ extra
                      )
                    ))
                    { services = 2; }
                  ]
                  ++ lib.optional claimed (
                    kix.usage.times pods {
                      persistentvolumeclaims = 1;
                      "requests.storage" = storage;
                    }
                  )
                );
          };

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
              name = metricsServiceName;
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
            # A Job's pod template is immutable, so the deploy replaces the
            # Job when its own content changes. The checksum annotations below
            # put the content of the webhook and of what serves it into that
            # content, so the check runs again when any of them changes.
            requires = builtins.attrValues self.webhookCheckRole;
            spec = {
              # The kubelet restarts the container with a growing delay (10 s
              # doubling to 5 min), so eight attempts span about 15 minutes.
              backoffLimit = 8;
              template = {
                metadata = {
                  labels = checkLabels;
                  annotations = {
                    "checksum/operator" = self.deployment.out.contentHash;
                    "checksum/webhook-service" = self.webhookService.out.contentHash;
                    "checksum/mutating-webhook" = self.mutatingWebhook.out.contentHash;
                    "checksum/validating-webhook" = self.validatingWebhook.out.contentHash;
                    "checksum/crd" = self.crds.rabbitmqClusters.out.contentHash;
                  };
                };
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
          ];
          postHooks = [ self.webhookCheck ];
          out = {
            crds.RabbitmqCluster = self.crds.rabbitmqClusters;
            inherit operandSelectors release;
            version = kix.image.version config.image;
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
      let
        sel = ''namespace="${ns}",service="${metricsServiceName}"'';
        operator = "RabbitMQ Cluster Operator ${ns}/${name}";
      in
      kix.monitor {
        service = "metricsService";
        alerts = {
          RabbitMQOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The RabbitMQ Cluster Operator is down.";
            description = "No replica of the ${operator} has answered a scrape for 10 minutes. Running RabbitMQ clusters keep serving, but changes to RabbitmqClusters are not applied, and its webhooks refuse creating or updating one. Check the operator Deployment in ${ns}.";
          };
          RabbitMQOperatorReconcileErrors = kix.reconcileErrorsAlert {
            selector = sel;
            inherit operator;
            summary = "The RabbitMQ Cluster Operator fails to reconcile RabbitMQ clusters.";
            impact = "a RabbitmqCluster's StatefulSet, Services, or PersistentVolumeClaims may not match its spec";
            nextStep = "Check the operator logs and the RabbitmqCluster's ReconcileSuccess condition for the error.";
          };
        };
      } args
    )
  ];
}

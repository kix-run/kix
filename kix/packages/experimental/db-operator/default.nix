# db-operator: the DB Operator, which creates databases and users on
# PostgreSQL, MySQL, and ClickHouse servers declared as kinda.rocks
# DbInstance resources, from kinda.rocks Database and DbUser resources.
#
# The package applies the DbInstance, Database, and DbUser
# CustomResourceDefinitions (crds/, vendored from upstream's kubebuilder
# bases), the controller's ClusterRole and leader-election Role (rbac/, from
# the same tag), the controller Deployment with its config file, the webhook
# Deployment and its Service, the mutating and validating webhook
# configurations (config/webhook/manifests.yaml upstream), and a self-signed
# cert-manager Issuer and Certificate for the webhook server. cert-manager's
# cainjector copies the Certificate's CA into each webhook entry's
# `clientConfig.caBundle`, which Kix never sets. One image runs both
# Deployments: `db-operator controller` and `db-operator webhook`
# (cmd/main.go upstream).
#
# Every webhook entry has failurePolicy Fail, and until cainjector has
# written the caBundle the API server cannot call them, so a custom resource
# created in that window is refused. Each handle in `out.crds` therefore
# adds the webhook-check Job to the requires of every custom resource built
# from it. The Job runs a server-side dry-run create of a Database, which
# succeeds only once the API server can call the webhook server and trusts
# its certificate. The webhook configurations require the webhook
# Deployment, because the webhook server neither reads nor patches them.
#
# A cluster runs one instance (`conflictsWith`): the definitions and the
# webhook configurations are cluster-wide, a DbInstance is cluster-scoped,
# and two controllers would reconcile the same resources.
#
# Minimal instance, with cert-manager elsewhere in the cluster:
#
#   instances.db-operator.db-operator.package = packages.experimental.db-operator;
#
# Dependencies:
#   certManager (required)  the cert-manager instance whose Issuer and
#                           Certificate handles the package builds from.
#   prometheus (optional)   a metrics Service and ServiceMonitor for the
#                           controller's metrics (TCP 60000) while
#                           `metrics.enabled`.
#
# Replicas: the controller runs one replica at availability none and pod,
# and two from node up. The package turns on leader election
# (DBO_ENABLE_LEADER_ELECTION), so one replica reconciles at a time. The
# webhook server keeps no state, so it runs one replica at none and two
# from pod up, each serving every webhook.
#
# The controller reads its config file only at start. `settings` is that
# file, deep-merged over the values upstream's config/manager/manager.yaml
# ships, and a change restarts the controller.
#
# Escape hatches: `env` and `webhook.env` (variables from cmd/main.go
# upstream, such as DBO_LOG_LEVEL or DBO_RECONCILE_INTERVAL), `settings`,
# `webhookCheck.image`, and the instance's `partsOverlays`.
#
# `out`:
#   out.crds.DbInstance, out.crds.Database, out.crds.DbUser
#                             the CRD handles for scope.mkCR. Use the
#                             db-operator-instance and db-operator-database
#                             packages rather than building the first two
#                             directly.
#   out.podSelector           the controller pods' labels.
#   out.release               the operator release.
#   out.version               the operator version `image.tag` names.
#
# Network policy: the controller connects to each server a DbInstance names.
# The DbInstance definition's factBehavior is terminate, with the controller
# pods as the caller, so a Service address in a DbInstance's spec opens the
# controller's egress to that Service's pods and their ingress from it. A
# server outside the cluster gets its egress from db-operator-instance. The
# webhook intent admits the API server on TCP 9443 to every pod of the
# package. Only the webhook pods listen on that port: the controller starts
# no webhook server, because it registers no webhook. The webhook server
# makes no Kubernetes API calls, so it gets no role and no egress to the API
# server.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   DbOperatorDown (warning)             no controller replica answers a
#                                        scrape. Existing databases keep
#                                        serving; new Database, DbUser, and
#                                        DbInstance resources are not
#                                        reconciled.
#   DbOperatorReconcileErrors (warning)  reconciles fail, such as a server
#                                        that refuses the admin login.
#   DbOperatorDatabaseFailing (warning)  a Database that was ready in the
#                                        last 6 hours has not been ready
#                                        for 15 minutes.
# A webhook pod that stops serving is left to prometheus-default-rules
# (KubeDeploymentReplicasMismatch). Its metrics are not scraped. A Database
# that has never been ready shows in its `status.status` and stops the
# deploy that applies it.
#
# Limits: the metrics endpoints are served over plain HTTP. The webhook
# server's Certificate comes from a self-signed Issuer of its own, as in
# upstream's chart.
#
# root = the controller Deployment; the webhook check runs after it.
#
# Moving to another release: set `release` and the digest of `image`
# (`crane digest ghcr.io/db-operator/db-operator:<release>`), move the tag
# in crds/sources.txt and rbac/sources.txt, run
# `uv run scripts/vendor-crds.py db-operator`, compare the webhook entries
# below with config/webhook/manifests.yaml and the Deployments with
# config/manager/ at the new tag, then run the kix-lib test
# db-operator-sources-match-release and every-package-evaluates.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # meta.version, the default image.tag, and the tag in crds/sources.txt and
  # rbac/sources.txt.
  release = "2.47.0";

  name = scope.instanceName;
  ns = scope.namespaceName;

  group = "kinda.rocks";
  readJSON = file: builtins.fromJSON (builtins.readFile file);
  crdSpec = file: (readJSON ./crds/${file}).spec;

  # The webhook server's port is fixed in cmd/main.go. The metrics and probe
  # addresses are the defaults of DBO_METRICS_ADDR and DBO_PROBE_ADDR there,
  # which the package sets so the ports below stay true.
  webhookPort = 9443;
  metricsPort = 60000;
  healthPort = 8081;
  # controller-runtime's default certificate directory, which cmd/main.go
  # keeps.
  certDir = "/tmp/k8s-webhook-server/serving-certs";
  configDir = "/run/config";

  # The Service the webhook entries call, and the name the Certificate is
  # issued for. Plain names: the webhook Deployment mounts the Certificate's
  # Secret and the Service selects the Deployment's pods, so a reference to
  # the Service would close a cycle.
  webhookServiceName = "${name}-webhook";
  certificateName = "${name}-webhook";
  certSecretName = "${name}-webhook-tls";
  # The metrics Service, whose name the alerts select on.
  metricsServiceName = "${name}-metrics";

  controllerLabels = scope.selectorLabels // {
    "app.kubernetes.io/component" = "controller";
  };
  webhookLabels = scope.selectorLabels // {
    "app.kubernetes.io/component" = "webhook";
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

  # Both servers answer /healthz and /readyz on the probe port
  # (cmd/main.go). The delays are config/manager/manager.yaml's.
  probes = {
    livenessProbe = {
      httpGet = {
        path = "/healthz";
        port = healthPort;
      };
      initialDelaySeconds = 15;
      periodSeconds = 20;
    };
    readinessProbe = {
      httpGet = {
        path = "/readyz";
        port = healthPort;
      };
      initialDelaySeconds = 5;
      periodSeconds = 10;
    };
  };

  # The variables that place the metrics and probe listeners, which the
  # Services, probes, and network policy derive from.
  listenerVars = {
    vars = {
      DBO_METRICS_ADDR = ":${toString metricsPort}";
      DBO_PROBE_ADDR = ":${toString healthPort}";
    };
    from = "the fixed ports (60000 for metrics and 8081 for health probes) used by the package's health checks, metrics Service, and network policies";
    fix = "Remove DBO_METRICS_ADDR and DBO_PROBE_ADDR from env and webhook.env.";
  };
in
{
  meta = {
    version = release;
    description = "DB Operator controller and admission webhook for provisioning databases and users";
    owner = "platform";
    defaultAliases = [ "dbOperator" ];
    conflictsWith = [
      {
        key = "cluster:dbOperator";
        reason = "DB Operator installs cluster-wide CRDs and admission webhooks, and two controllers would act on the same DbInstance, Database, and DbUser resources";
      }
    ];
    # The controller reads kinda.rocks annotations on Databases and
    # DbInstances (pkg/consts/consts.go upstream).
    annotationDomains = [ group ];
    # Upstream's chart declares kubeVersion >= 1.34, and its chart-test
    # workflow runs on Kubernetes 1.34 to 1.36.
    k8s.supported = {
      minVersion = "1.34";
      maxVersion = "1.36";
      source = "kubeVersion in the DB Operator Helm chart and the Kubernetes versions in its integration tests";
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
        reason = "this package's CRDs, RBAC rules, and webhook configuration come from DB Operator ${release}";
        fix = "To update this package to another DB Operator version, follow the steps at the top of kix/packages/experimental/db-operator/default.nix.";
      })
    ];

  options = {
    image = kix.options.image {
      repository = "ghcr.io/db-operator/db-operator";
      tag = release;
      digest = "sha256:6fe812470300b55f3e45e603d3b5a0222ddb13102d797d08001b852afe09641c";
      description = "Container image for both the controller and the webhook server. Its major.minor version must match DB Operator ${release}.";
    };

    # The requests and the CPU limit are config/manager/manager.yaml's.
    # Upstream's chart sets no memory limit, and that file's 128Mi carries a
    # TODO to size it. The controller caches every Secret and ConfigMap in the
    # cluster (SetupWithManager in internal/controller/dbinstance_controller.go
    # upstream). Resident memory was about 48 MiB idle with a few dozen
    # Secrets and about 185 MB with 10,000 Secrets of 8 KiB each, or about
    # 11 KB per 8 KiB Secret. Starting with those 10,000 Secrets reached a
    # 158 MiB cgroup peak. The default limit is 512Mi. Raise
    # `resources.limits.memory` on clusters with more or larger Secrets and
    # ConfigMaps, or when the controller is OOM-killed.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
    };

    env = kix.options.env // {
      description = "Extra `DBO_*` environment variables for the controller, such as `DBO_LOG_LEVEL`, `DBO_RECONCILE_INTERVAL`, or `DBO_CHECK_FOR_CHANGES`. Pass a string, a `fieldRef`, or a `secretKeyRef` (using `kix.untrackedRef` for a Secret managed outside Kix). Kix rejects variables that this package sets or reserves (`DBO_CONFIG`, `DBO_ENABLE_LEADER_ELECTION`, `DBO_WATCH_NAMESPACES`, `DBO_METRICS_ADDR`, and `DBO_PROBE_ADDR`).";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        serverVersionTTL = "30m";
      };
      description = ''
        Settings written to the controller's `config.yaml` file, merged over the
        defaults `{ databaseAwareness = true; serverVersionTTL = "1h"; }`. Changing
        `settings` restarts the controller pods so they reload the file.
      '';
    };

    metrics = kix.options.monitor;

    webhook = {
      # config/manager/webhook/deployment.yaml's requests and limits.
      resources = kix.options.resources {
        requests = {
          cpu = "10m";
          memory = "64Mi";
        };
        limits = {
          cpu = "500m";
          memory = "128Mi";
        };
      };

      env = kix.options.env // {
        description = "Extra `DBO_*` environment variables for the webhook server, such as `DBO_LOG_LEVEL`. Pass a string, a `fieldRef`, or a `secretKeyRef` (using `kix.untrackedRef` for a Secret managed outside Kix). Kix rejects variables that this package sets or reserves (`DBO_ENABLE_LEADER_ELECTION`, `DBO_METRICS_ADDR`, and `DBO_PROBE_ADDR`).";
      };
    };

    webhookCheck.image = kix.options.image {
      repository = "registry.k8s.io/kubectl";
      tag = "v1.37.1";
      digest = "sha256:b7cab618e281b1ee7484e7b706a96e2135fbb6e072c2a573a7dab4e87d7f2385";
      description = "Container image for the `webhook-check` Job that verifies the admission webhook during deploy. Its entrypoint must be `kubectl`.";
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
        controllerEnv = kix.mkEnvVars (
          kix.mergeEnv {
            inherit scope;
            owned = [
              listenerVars
              {
                vars.DBO_CONFIG = "${configDir}/config.yaml";
                from = "the settings option, mounted as the controller's config.yaml";
                fix = "Remove DBO_CONFIG from env and set settings instead.";
              }
              {
                vars.DBO_ENABLE_LEADER_ELECTION = "true";
                from = "this package's leader-election setting, enabled so only one controller pod is active at a time";
                fix = "Remove DBO_ENABLE_LEADER_ELECTION from env.";
              }
              {
                names = [ "DBO_WATCH_NAMESPACES" ];
                reason = "the controller must watch all namespaces. DB Operator's admission webhooks are cluster-wide, so a Database created in an unwatched namespace would pass admission and stay unready forever.";
                fix = "Remove DBO_WATCH_NAMESPACES from env. To restrict which namespaces can use a server, set extraSpec.namespaceFilters on its db-operator-instance.";
              }
            ];
          } config.env
        );

        webhookEnv = kix.mkEnvVars (
          kix.mergeEnv {
            inherit scope;
            option = "webhook.env";
            owned = [
              listenerVars
              {
                names = [ "DBO_ENABLE_LEADER_ELECTION" ];
                reason = "all webhook replicas serve requests at the same time, and the webhook ServiceAccount has no permissions for leader-election Leases.";
                fix = "Remove DBO_ENABLE_LEADER_ELECTION from webhook.env.";
              }
            ];
          } config.webhook.env
        );

        certCrds =
          certManager.out.crds or (scope.fail {
            package = "db-operator";
            dependency = "certManager";
            message = "deps.certManager is missing out.crds (for example, because it uses kix.mkImport instead of packages.experimental.cert-manager), so Kix cannot create the webhook's Issuer and Certificate.";
            fix = "Point deps.certManager at a packages.experimental.cert-manager instance: deps.certManager = ref.<namespace>.<instance>.";
          });

        controllerSubjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];

        # The entries of config/webhook/manifests.yaml upstream, which the
        # kubebuilder markers in internal/webhook generate.
        webhookEntry =
          {
            type,
            version,
            resource,
          }:
          let
            kind = lib.removeSuffix "s" resource;
          in
          {
            name = "${if type == "mutate" then "m" else "v"}${kind}-${version}.kb.io";
            admissionReviewVersions = [ "v1" ];
            clientConfig.service = {
              name = webhookServiceName;
              namespace = ns;
              path = "/${type}-kinda-rocks-${version}-${kind}";
              port = 443;
            };
            failurePolicy = "Fail";
            rules = [
              {
                apiGroups = [ group ];
                apiVersions = [ version ];
                operations = [
                  "CREATE"
                  "UPDATE"
                ];
                resources = [ resource ];
              }
            ];
            sideEffects = "None";
          };
        mutating = map webhookEntry [
          {
            type = "mutate";
            version = "v1beta1";
            resource = "databases";
          }
          {
            type = "mutate";
            version = "v1";
            resource = "dbinstances";
          }
          {
            type = "mutate";
            version = "v1beta1";
            resource = "dbinstances";
          }
        ];
        validating = map webhookEntry [
          {
            type = "validate";
            version = "v1beta1";
            resource = "databases";
          }
          {
            type = "validate";
            version = "v1";
            resource = "dbinstances";
          }
          {
            type = "validate";
            version = "v1beta1";
            resource = "dbinstances";
          }
          {
            type = "validate";
            version = "v1beta1";
            resource = "dbusers";
          }
        ];
        # cainjector reads the Certificate named here and writes its CA into
        # every entry's caBundle.
        injectCa."cert-manager.io/inject-ca-from" = "${ns}/${certificateName}";

        # The webhook check. A dry-run create of a Database succeeds only
        # when the API server can call the webhook server and trusts its
        # certificate. kubectl exits non-zero otherwise, and the Job retries.
        # The webhooks do not look the DbInstance up, so the one named here
        # need not exist.
        checkName = "${name}-webhook-check";
        checkLabels."app.kubernetes.io/name" = checkName;
        checkFile = "database.json";
        checkDatabase = builtins.toJSON {
          apiVersion = "${group}/v1beta1";
          kind = "Database";
          # A fixed name fails the dry-run when a Database of that name
          # exists.
          metadata = {
            generateName = "${checkName}-";
            namespace = ns;
          };
          spec = {
            secretName = checkName;
            instance = checkName;
            deletionProtected = true;
          };
        };

        config' = lib.recursiveUpdate {
          databaseAwareness = true;
          serverVersionTTL = "1h";
        } config.settings;

        crdHandle =
          file: extra:
          scope.mkCRD (
            {
              spec = crdSpec file;
              # Every custom resource waits for the webhook check.
              crRequires = [ self.webhookCheck ];
            }
            // extra
          );
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "${name}-controller";
        };

        webhookServiceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "${name}-webhook";
        };

        clusterRole = scope.rbac.mkClusterRoleSet scope {
          subjects = controllerSubjects;
          roles.${name} = (readJSON ./rbac/clusterrole-manager-role.json).rules;
        };

        leaderElectionRole = scope.rbac.mkRoleSet scope {
          subjects = controllerSubjects;
          roles."${name}-leader-election" = (readJSON ./rbac/role-leader-election-role.json).rules;
        };

        crds = {
          dbInstances = crdHandle "dbinstances.${group}.json" {
            # Removing a DbInstance leaves the server and its databases.
            holdsData = false;
            # The controller sets status.ready once it has logged in, read
            # the server version, and checked the grant rules
            # (internal/controller/dbinstance_controller.go upstream). Its
            # conditions carry no observedGeneration, and the status has no
            # generation field.
            readiness = {
              path = "/status/ready";
              equals = "true";
              observedGeneration = false;
            };
            # The controller connects to the server the spec names.
            factBehavior = {
              endpoint = "terminate";
              podSelector = controllerLabels;
              podNamespace = ns;
            };
          };
          databases = crdHandle "databases.${group}.json" {
            # Unless spec.deletionProtected is true, the controller drops
            # the database and its user when the Database is deleted
            # (deleteDatabase in internal/controller/database_controller.go
            # upstream).
            holdsData = true;
            # status.status turns true once the database, its user, the
            # Secret, and the ConfigMap exist. The status has no generation
            # field.
            readiness = {
              path = "/status/status";
              equals = "true";
              observedGeneration = false;
            };
          };
          dbUsers = crdHandle "dbusers.${group}.json" {
            # Deleting a DbUser drops the user, not the data.
            holdsData = false;
            readiness = {
              path = "/status/status";
              equals = "true";
              observedGeneration = false;
            };
          };
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
            selector = self.webhookDeployment.out.selector;
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
          requires = [
            self.certificate
            self.webhookDeployment
          ];
          extra.webhooks = mutating;
        };
        validatingWebhook = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "ValidatingWebhookConfiguration";
          name = "${name}-${ns}";
          annotations = injectCa;
          requires = [
            self.certificate
            self.webhookDeployment
          ];
          extra.webhooks = validating;
        };

        controllerConfig = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data."config.yaml" = builtins.toJSON config';
        };

        configMount = kix.mount.configMap self.controllerConfig {
          mountPath = configDir;
          readOnly = true;
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

        deployment =
          {
            name = "${name}-controller";
            requires = builtins.attrValues self.crds;
            spec = {
              replicas = kix.availability.pick availability {
                none = 1;
                pod = 1;
                node = 2;
                zone = 2;
              };
              selector.matchLabels = controllerLabels;
              template = {
                metadata = {
                  labels = controllerLabels;
                  # The controller reads its config file only at start.
                  annotations."checksum/config" = self.controllerConfig.out.contentHash;
                };
                spec = {
                  serviceAccount = self.serviceAccount;
                  # config/manager/manager.yaml's value.
                  terminationGracePeriodSeconds = 10;
                  securityContext = podSecurityContext;
                  containers = [
                    (
                      {
                        name = "controller";
                        image = kix.image.ref config.image;
                        args = [ "controller" ];
                        env = controllerEnv;
                        ports = [
                          (kix.port "metrics" metricsPort)
                          (kix.port "health" healthPort)
                        ];
                        resources = config.resources;
                        securityContext = containerSecurityContext;
                      }
                      // probes
                      // lib.optionalAttrs (config.image.pullPolicy != null) {
                        imagePullPolicy = config.image.pullPolicy;
                      }
                    )
                  ];
                };
              };
            };
          }
          |> kix.withMounts [ self.configMount ]
          |> scope.mkDeployment;

        webhookDeployment = scope.mkDeployment {
          name = "${name}-webhook";
          spec = {
            replicas = kix.availability.pick availability {
              none = 1;
              pod = 2;
              node = 2;
              zone = 2;
            };
            selector.matchLabels = webhookLabels;
            template = {
              metadata.labels = webhookLabels;
              spec = {
                serviceAccount = self.webhookServiceAccount;
                # config/manager/webhook/deployment.yaml's value.
                terminationGracePeriodSeconds = 10;
                securityContext = podSecurityContext;
                containers = [
                  (
                    {
                      name = "webhook";
                      image = kix.image.ref config.image;
                      args = [ "webhook" ];
                      env = webhookEnv;
                      ports = [
                        (kix.port "webhook-server" webhookPort)
                        (kix.port "metrics" metricsPort)
                        (kix.port "health" healthPort)
                      ];
                      resources = config.webhook.resources;
                      securityContext = containerSecurityContext;
                      volumeMounts = [
                        {
                          name = "webhook-certificates";
                          mountPath = certDir;
                          readOnly = true;
                        }
                      ];
                    }
                    // probes
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
            (scope.rbac.allow [ "create" ] (scope.rbac.group group [ "databases" ]).databases)
          ];
        };

        webhookCheckManifest = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = checkName;
          labels = checkLabels;
          data.${checkFile} = checkDatabase;
        };

        webhookCheckMount = kix.mount.configMap self.webhookCheckManifest {
          mountPath = "/check";
          readOnly = true;
        };

        webhookCheck =
          {
            name = checkName;
            labels = checkLabels;
            # The checksum annotations put the content of the webhook
            # configurations and of what serves them into the Job's own
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
                    "checksum/webhook" = self.webhookDeployment.out.contentHash;
                    "checksum/webhook-service" = self.webhookService.out.contentHash;
                    "checksum/mutating-webhook" = self.mutatingWebhook.out.contentHash;
                    "checksum/validating-webhook" = self.validatingWebhook.out.contentHash;
                    "checksum/crd" = self.crds.databases.out.contentHash;
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
                        securityContext = containerSecurityContext;
                        # A ResourceQuota on requests or limits refuses a pod
                        # that does not set them, and every custom resource
                        # of the package's kinds waits on this Job.
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
            crds = {
              DbInstance = self.crds.dbInstances;
              Database = self.crds.databases;
              DbUser = self.crds.dbUsers;
            };
            inherit release;
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
        operator = "DB Operator instance ${ns}/${name}";
      in
      kix.monitor {
        service = "metricsService";
        alerts = {
          DbOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "DB Operator controller is down.";
            description = "No controller pod for ${operator} has answered a Prometheus scrape for 10 minutes. Existing databases keep serving traffic, but new or changed Database, DbUser, and DbInstance resources are not applied. Check Deployment ${ns}/${name}-controller and its pod logs.";
          };
          # db_operator_database_status is 1 while a Database is ready and 0
          # otherwise, labelled db_namespace, dbinstance, and database
          # (internal/controller/metrics.go upstream). The controller sets it
          # at the start of each reconcile, so it lags by one interval. A
          # Database that has never been ready is left to the deploy, which
          # waits for it.
          DbOperatorDatabaseFailing = {
            expr = "max by (namespace, service, db_namespace, dbinstance, database) (db_operator_database_status{${sel}}) == 0 and max by (namespace, service, db_namespace, dbinstance, database) (max_over_time(db_operator_database_status{${sel}}[6h])) == 1";
            "for" = "15m";
            severity = "warning";
            summary = "DB Operator Database {{ $labels.db_namespace }}/{{ $labels.database }} is not ready.";
            description = "Database {{ $labels.db_namespace }}/{{ $labels.database }} on DbInstance {{ $labels.dbinstance }} was ready in the last 6 hours and has been unready for 15 minutes. The ${operator} could not update or verify this Database (for example, because it could not reach or sign in to the server), and applications using it may fail to connect. Run kubectl describe database -n {{ $labels.db_namespace }} {{ $labels.database }} and check the logs of Deployment ${ns}/${name}-controller.";
          };
          DbOperatorReconcileErrors = kix.reconcileErrorsAlert {
            selector = sel;
            inherit operator;
            summary = "DB Operator is failing to reconcile resources.";
            impact = "Database, DbUser, or DbInstance changes may not be applied to the database server";
            nextStep = "Check the logs of Deployment ${ns}/${name}-controller and the Events on the failing resource.";
          };
        };
      } args
    )
  ];
}

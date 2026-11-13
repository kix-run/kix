# stackgres-operator: the StackGres operator, which runs PostgreSQL clusters
# declared as stackgres.io custom resources.
#
# The package renders the operator Deployment, its ServiceAccount and
# ClusterRole, the webhook Service, and the two webhook configurations as
# metadata only. The operator does the rest when it starts: it installs or
# updates the stackgres.io CustomResourceDefinitions (INSTALL_CRDS), creates
# its certificate Secret (INSTALL_CERTS), writes every webhook entry with its
# caBundle into the two configurations (INSTALL_WEBHOOKS), and creates or
# updates the SGConfig named after the instance from the `sgConfig` option
# (INSTALL_CONFIG, SGCONFIG). The Deployment requires the two configurations,
# so they exist before the operator starts and it updates them.
#
# The operator writes the webhook entries a few seconds after it installs
# the definitions and reports ready. An SGCluster created in that window
# gets no status from the mutating webhook, and StackGres 1.19's
# StatusUpdateValidator then throws a NullPointerException on every update
# of it, so the operator never creates the cluster's pods. Every CRD
# reference in `out.crds` therefore adds the webhook-check Job to the
# requires of each custom resource built from it. The Job waits until both
# configurations hold their entries and a server-side dry-run create of an
# SGInstanceProfile comes back mutated by the operator.
#
# A cluster runs one instance: the definitions and webhook configurations are
# cluster-wide, and the webhooks have no namespaceSelector, so they admit
# every namespace. `conflictsWith` refuses a second instance.
#
# The SGConfig sets `deploy.restapi`, `deploy.collector`, and
# `collector.prometheusOperator.allowDiscovery` to false. The REST API, web
# console, and OpenTelemetry collector are pods the operator creates from the
# SGConfig, and Kix gives them no RBAC binding or network policy, so the
# package does not run them. PostgreSQL metrics come from each cluster's
# exporter sidecar (stackgres-cluster `metrics`).
#
# The operator merges SGCONFIG into the live SGConfig. A key removed from
# `sgConfig` keeps its old value there; set it explicitly instead.
#
# Minimal instance:
#
#   instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;
#
# Dependencies:
#   prometheus (optional)   a metrics Service and ServiceMonitor for the
#                           operator's Quarkus metrics (`/q/metrics` on TCP
#                           8080) while `metrics.enabled`.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   StackGresOperatorDown (warning)             no operator replica answers
#                                               a scrape. Running PostgreSQL
#                                               clusters keep serving;
#                                               changes to stackgres.io
#                                               resources are not applied,
#                                               and the webhooks refuse
#                                               creates and updates.
#   StackGresOperatorReconcileErrors (warning)  reconciles of one kind fail
#                                               for 15 minutes.
# The webhooks have no metric of their own; the down alert covers a webhook
# that does not answer. Fewer ready replicas than desired is left to
# prometheus-default-rules (KubeDeploymentReplicasMismatch), and the health
# of each PostgreSQL cluster to stackgres-cluster's alerts.
#
# Escape hatches: `sgConfig` (SGConfig spec), `env` (operator variables such
# as OPERATOR_LOG_LEVEL or JAVA_OPTS), `webhookCheck.image`, and the
# instance's `partsOverlays`.
#
# `out`:
#   out.crds.<Kind>   CRD references for scope.mkCR, one per stackgres.io kind
#                     except SGConfig, which this package owns:
#                       scope.mkCR stackgresOperator.out.crds.SGCluster { ... }
#   out.operandSelectors.sgCluster crName
#                     the labels of an SGCluster's pods.
#   out.operandSelectors.dbOps, out.operandSelectors.backup
#                     the labels of the Job pods of every SGDbOps, and of
#                     every manually created SGBackup, in a namespace.
#   out.podSelector   the operator pods' labels.
#   out.release       the StackGres release.
#   out.version       the StackGres version `image.tag` names.
#   out.resolvePostgres { who; version; }
#                     { major; minor; images } for an SGCluster at `version`,
#                     with images from this operator's registry. Throws,
#                     prefixed with `who`, for `latest` or a release the table
#                     does not ship.
#   out.kubectlImages the kubectl images the operator's backup and
#                     major-upgrade Jobs run: one when the cluster sets
#                     k8sVersion, else every candidate.
#
# Network policy for operand pods comes from the package that builds the
# custom resource: stackgres-cluster writes it for SGCluster pods and for
# the SGDbOps and SGBackup Job pods in its namespace. The pods
# of an SGShardedCluster, SGDistributedLogs, or SGStream built from
# out.crds get no policy, so under an enforcer's namespace default-deny they
# cannot reach the API server or each other.
#
# root = the operator Deployment; the webhook check runs after it.
#
# Moving to another release: replace versions.properties with
# versions-<major.minor>.properties from stackgres-k8s/src/common/src/main/resources
# at the new tag, set `release` in release.nix and the digest of `image`
# below (`crane digest quay.io/stackgres/operator:<release>`), set the tag of
# `webhookCheck.image` to the newest kubectl entry in versions.properties and
# its digest (`crane digest quay.io/ongres/kubectl:v<entry>`), compare
# kinds.nix with the chart's crds/ and the RBAC below with its
# operator-cluster-role.yaml, then run the stackgres eval checks
# (every-package-evaluates, homelab-kind).

{
  scope,
  lib,
  kix,
}:

let
  inherit (import ./release.nix { inherit lib; })
    release
    resolvePostgres
    kubectlImages
    ;
  kinds = import ./kinds.nix;

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "stackgres-operator ${ns}/${name}";

  group = "stackgres.io";
  # Quarkus serves HTTP on 8080 beside the webhooks' HTTPS on 8443.
  httpPort = 8080;
  # The metrics Service, whose name the alerts select on.
  metricsServiceName = "${name}-metrics";
  podLabels = {
    app = name;
    group = group;
  };

  # The SGConfig is the operator's own configuration, set through
  # `sgConfig`. A second SGConfig written from a cluster file would compete
  # with it, so its kind gets no CRD reference.
  referencedKinds = removeAttrs kinds [ "SGConfig" ];

  # The Job pods of an SGDbOps and of a manually created SGBackup carry the
  # operation's name, not the cluster's (LabelFactoryForDbOps and
  # LabelFactoryForBackup at 1.19), so they are selected per namespace.
  operandSelectors = {
    sgCluster = crName: {
      app = "StackGresCluster";
      "stackgres.io/cluster-name" = crName;
    };
    dbOps.app = "StackGresDbOps";
    backup.app = "StackGresBackup";
  };

  # Top-level SGConfig keys StackGres reads from chart values or operator
  # variables rather than from the SGConfig, or that configure the REST API,
  # web console, and collector this package does not run.
  refusedSgConfigKeys = [
    "imagePullSecrets"
    "allowedNamespaces"
    "allowedNamespaceLabelSelector"
    "disableClusterRole"
    "allowImpersonationForRestApi"
    "disableCrdsAndWebhooksUpdate"
    "enableConversionWebhooks"
    "sgConfigNamespace"
    "serviceAccount"
    "operator"
    "cert"
    "rbac"
    "deploy"
    "restapi"
    "adminui"
    "authentication"
    "collector"
    "grafana"
  ];

  operatorSuffix = "/stackgres/operator";
  registryOf = repository: lib.removeSuffix operatorSuffix repository;
  fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };
in
{
  meta = {
    version = release;
    description = "StackGres operator: runs PostgreSQL clusters declared as stackgres.io resources";
    owner = "platform";
    defaultAliases = [ "stackgresOperator" ];
    conflictsWith = [ "cluster:stackgresOperator" ];
    k8s.minVersion = "1.25";
    network.intents = {
      # The operator reads extension metadata from extensions.stackgres.io.
      extensions.egress = [
        {
          to = "world";
          ports = [
            {
              port = 443;
              protocol = "TCP";
            }
          ];
        }
      ];
      webhooks.ingress = [
        {
          from = "apiserver";
          ports = [
            {
              port = 8443;
              protocol = "TCP";
            }
          ];
        }
      ];
    };
  };

  assertions =
    { config, ... }:
    let
      refused = builtins.filter (k: config.sgConfig ? ${k}) refusedSgConfigKeys;
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
    in
    [
      {
        assertion = lib.removeSuffix "-jvm" imageTag == release;
        message = "image.tag \"${imageTag}\" is not StackGres ${release}, the release this package's version table and CRD list describe. Move the operator by following the steps in the header of kix/packages/experimental/stackgres-operator/default.nix.";
      }
      {
        assertion = lib.hasSuffix operatorSuffix config.image.repository;
        message = "image.repository \"${config.image.repository}\" does not end in ${operatorSuffix}. StackGres pulls operand images from the same registry prefix (<prefix>/ongres/patroni, ...), so mirror the quay.io layout: <prefix>${operatorSuffix}.";
      }
      {
        assertion = refused == [ ];
        message = "sgConfig sets ${lib.concatStringsSep ", " refused}. StackGres reads these from operator variables, not from the SGConfig, or they configure the web console and collector, which this package does not run. Set operator variables through env, or remove them.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "quay.io/stackgres/operator";
      tag = release;
      digest = "sha256:82f33ab3fb1e30e6c076411ccb349be7335e6a25af5161d7bcecffbc44d42336";
      description = "Operator image. Its tag must be the package's StackGres release (a -jvm tag is accepted). The repository minus /stackgres/operator is the registry prefix StackGres pulls operand images from, and pullPolicy is their pull policy.";
    };

    # The upstream chart's defaults.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "128Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };

    sgConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        extensions.repositoryUrls = [ "https://extensions.example.com/postgres/repository" ];
      };
      description = ''
        SGConfig spec, merged over the package's (`containerRegistry` and
        `imagePullPolicy` from `image`, the REST API and collector off) and
        passed to the operator as SGCONFIG. The operator merges it into the
        live SGConfig, so removing a key leaves its old value: set it
        explicitly instead. Keys StackGres reads from operator variables, and
        keys for the REST API, web console, and collector, are refused.
      '';
    };

    webhookCheck.image = kix.options.image {
      repository = "quay.io/ongres/kubectl";
      tag = "v1.37.1-build-6.56";
      digest = "sha256:8e3f36d49e403423627b450d803c94cf93c8bbebae8f59b11cb5e458bb0c1a39";
      description = "Image of the webhook-check Job, StackGres's kubectl image. It needs bash and kubectl. The declared tag is the newest kubectl entry in versions.properties. Its repository follows the registry prefix of `image.repository` and its pull policy follows `image.pullPolicy`.";
    };

    metrics = kix.options.monitor;

    env = kix.options.env // {
      description = "Extra operator environment variables, such as OPERATOR_LOG_LEVEL or JAVA_OPTS. A value is a string, a `fieldRef`, or `kix.untrackedRef`. The variables the package sets are refused with the option that sets them.";
    };
  };

  # The check image comes from the operator's registry prefix, as the
  # operand images do.
  config =
    { config, ... }:
    {
      webhookCheck.image = {
        repository = lib.mkDefault "${registryOf config.image.repository}/ongres/kubectl";
        pullPolicy = lib.mkDefault config.image.pullPolicy;
      };
    };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        prometheus ? null,
        ...
      }:
      let
        registry = registryOf config.image.repository;
        imageTag = builtins.unsafeDiscardStringContext config.image.tag;
        nativeTag = lib.removeSuffix "-jvm" imageTag;
        jvm = lib.hasSuffix "-jvm" imageTag;
        uid = if jvm then 185 else 1000;
        pullPolicy = config.image.pullPolicy;

        sgConfigSpec =
          kix.mergeGuarded
            {
              inherit who;
              what = "sgConfig";
              locked = [
                [ "containerRegistry" ]
                [ "imagePullPolicy" ]
              ];
            }
            (
              {
                containerRegistry = registry;
                deploy = {
                  restapi = false;
                  collector = false;
                };
                # With discovery on, the SGConfig reconciler reads the
                # prometheuses.monitoring.coreos.com definition, which the
                # ClusterRole does not grant, and the reconcile fails on every
                # pass. Discovery only serves the collector, which is off.
                collector.prometheusOperator.allowDiscovery = false;
              }
              // lib.optionalAttrs (pullPolicy != null) { imagePullPolicy = pullPolicy; }
            )
            config.sgConfig;

        # JSON is YAML, which the operator parses.
        sgConfigManifest = builtins.toJSON {
          apiVersion = "${group}/v1";
          kind = "SGConfig";
          metadata = {
            inherit name;
            namespace = ns;
          };
          spec = sgConfigSpec;
        };

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            owned = [
              {
                vars = {
                  OPERATOR_NAME = name;
                  OPERATOR_NAMESPACE = fieldRef "metadata.namespace";
                  OPERATOR_SERVICE_ACCOUNT = fieldRef "spec.serviceAccountName";
                  OPERATOR_POD_NAME = fieldRef "metadata.name";
                  OPERATOR_IP = fieldRef "status.podIP";
                };
                from = "the instance and its pod";
                fix = "Remove it.";
              }
              {
                vars = {
                  OPERATOR_IMAGE_VERSION = imageTag;
                  OPERATOR_NATIVE_IMAGE_VERSION = nativeTag;
                  OPERATOR_JVM_IMAGE_VERSION = "${nativeTag}-jvm";
                  SG_CONTAINER_REGISTRY = registry;
                }
                // lib.optionalAttrs (pullPolicy != null) { SG_IMAGE_PULL_POLICY = pullPolicy; };
                from = "the image option";
                fix = "Set image instead.";
              }
              {
                vars = {
                  INSTALL_CONFIG = "true";
                  SGCONFIG = sgConfigManifest;
                  SGCONFIG_NAMESPACE = ns;
                };
                from = "the sgConfig option";
                fix = "Set sgConfig instead.";
              }
              {
                # With conversion webhooks off the operator removes
                # spec.conversion from the definitions it installs.
                vars = {
                  INSTALL_CRDS = "true";
                  INSTALL_WEBHOOKS = "true";
                  INSTALL_CONVERSION_WEBHOOKS = "false";
                  INSTALL_CERTS = "true";
                  WAIT_CRDS_UPGRADE = "false";
                  CLUSTER_ROLE_DISABLED = "false";
                  DISABLE_RECONCILIATION = "false";
                  PROMETHEUS_AUTOBIND = "false";
                };
                from = "this package: its ClusterRole, webhook configurations, and CRD references assume these values";
                fix = "Remove it.";
              }
              {
                names = [ "ALLOWED_NAMESPACES" ];
                from = "this package, which leaves it unset so the operator watches every namespace";
                fix = "The operator writes its webhooks with no namespaceSelector, so they still admit every namespace, and a cluster runs one StackGres operator. Namespace-scoped operation is not supported; remove it.";
              }
            ];
          } config.env
        );

        inherit (scope.rbac)
          core
          allow
          grant
          restrictTo
          sub
          mkClusterRoleSet
          mkRoleSet
          ;
        rbacGroup = scope.rbac.group;
        apps = rbacGroup "apps" [
          "deployments"
          "statefulsets"
        ];
        batch = rbacGroup "batch" [
          "cronjobs"
          "jobs"
        ];
        rbacApi = rbacGroup "rbac.authorization.k8s.io" [
          "roles"
          "rolebindings"
        ];
        apiext = rbacGroup "apiextensions.k8s.io" [ "customresourcedefinitions" ];
        admission = rbacGroup "admissionregistration.k8s.io" [
          "mutatingwebhookconfigurations"
          "validatingwebhookconfigurations"
        ];
        sgPlurals = lib.mapAttrsToList (_: k: k.plural) kinds;
        sg = map (rbacGroup group [ ]) sgPlurals;
        sgCrdNames = map (p: "${p}.${group}") sgPlurals;

        # The webhook check: once both configurations name the SGCluster
        # entries, a dry-run create of an SGInstanceProfile must carry the
        # operatorVersion annotation that the operator's mutating webhook
        # adds. That shows the API server calls the mutating webhook and
        # trusts its certificate, which is what gives a new SGCluster its
        # defaults and status. The operator writes every entry of a
        # configuration in one update, so one entry stands for all of them.
        checkName = "${name}-webhook-check";
        checkLabels.app = checkName;
        checkProfile = builtins.toJSON {
          apiVersion = "${group}/${kinds.SGInstanceProfile.version}";
          kind = "SGInstanceProfile";
          # The API server generates the name. A fixed name fails the dry-run
          # with AlreadyExists when an SGInstanceProfile of that name exists.
          metadata = {
            generateName = "${checkName}-";
            namespace = ns;
          };
          spec = {
            cpu = "1";
            memory = "1Gi";
          };
        };
        checkScript = ''
          set -u
          check() {
            for type in mutating validating; do
              entries=$(kubectl get "''${type}webhookconfiguration" ${name} -o 'jsonpath={.webhooks[*].name}') || return 1
              case " $entries " in
                *" sgcluster.''${type}-webhook.${group} "*) ;;
                *) echo "''${type}webhookconfiguration/${name} has no SGCluster entry yet"; return 1 ;;
              esac
            done
            version=$(echo '${checkProfile}' | kubectl create --dry-run=server -o 'jsonpath={.metadata.annotations.stackgres\.io/operatorVersion}' -f -) || return 1
            if [ -z "$version" ]; then
              echo "the dry-run SGInstanceProfile came back without the mutating webhook's annotation"
              return 1
            fi
            echo "the StackGres ${release} admission webhooks are serving (operatorVersion $version)"
          }
          deadline=$((SECONDS + 120))
          until check; do
            if [ "$SECONDS" -ge "$deadline" ]; then
              echo "the StackGres admission webhooks did not serve within 120 s; see the logs of deployment/${name} in ${ns}"
              exit 1
            fi
            sleep 2
          done
        '';
        checkSubjects = [
          {
            kind = "ServiceAccount";
            name = self.webhookCheckServiceAccount.out.name;
            namespace = ns;
          }
        ];

        # Each CRD reference adds the webhook check to the requires of every
        # custom resource built from it.
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

        manage = allow [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];

        rules = grant [
          (allow [ "get" "list" ] (rbacGroup "storage.k8s.io" [ "storageclasses" ]).storageclasses)
          # A create request carries no object name, so it cannot be limited to
          # the stackgres.io definitions.
          (allow [ "list" "create" ] apiext.customresourcedefinitions)
          (
            apiext.customresourcedefinitions
            |> restrictTo sgCrdNames
            |> allow [
              "get"
              "patch"
              "update"
            ]
          )
          # CrdWebhookInstaller updates both configurations.
          (
            [
              admission.mutatingwebhookconfigurations
              admission.validatingwebhookconfigurations
            ]
            |> map (restrictTo [ name ])
            |> allow [
              "get"
              "patch"
              "update"
            ]
          )
          # What the operator creates for each cluster, backup, and operation.
          (allow
            [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "patch"
              "delete"
              "deletecollection"
            ]
            [
              core.pods
              (sub "exec" core.pods)
              (sub "log" core.pods)
              core.services
              core.endpoints
              (sub "restricted" core.endpoints)
              core.persistentvolumeclaims
              core.configmaps
              core.secrets
              core.serviceaccounts
              core.namespaces
              core.events
              apps.deployments
              apps.statefulsets
              rbacApi.roles
              rbacApi.rolebindings
              batch.cronjobs
              batch.jobs
            ]
          )
          (allow [ "update" ] (
            map (sub "finalizers") [
              apps.statefulsets
              core.persistentvolumeclaims
              apps.deployments
              core.services
              core.endpoints
              batch.cronjobs
              batch.jobs
              core.pods
            ]
          ))
          (manage (rbacGroup "coordination.k8s.io" [ "leases" ]).leases)
          (manage sg)
          (allow [ "update" ] (
            map (sub "finalizers") sg
            # The kinds whose definitions have a status subresource, as the
            # upstream chart grants.
            ++ map (p: sub "status" (rbacGroup group [ ] p)) [
              "sgconfigs"
              "sgclusters"
              "sgdistributedlogs"
            ]
          ))
          (allow [
            "get"
            "list"
            "watch"
            "create"
          ] (rbacGroup "snapshot.storage.k8s.io" [ "volumesnapshots" ]).volumesnapshots)
          # Integrations an SGCluster or SGShardedCluster can ask for.
          (manage [
            (rbacGroup "shardingsphere.apache.org" [ "computenodes" ]).computenodes
            (rbacGroup "keda.sh" [ "scaledobjects" ]).scaledobjects
            (rbacGroup "keda.sh" [ "triggerauthentications" ]).triggerauthentications
            (rbacGroup "autoscaling.k8s.io" [ "verticalpodautoscalers" ]).verticalpodautoscalers
            (rbacGroup "serving.knative.dev" [ "services" ]).services
          ])
        ];
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        clusterRole = mkClusterRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = ns;
            }
          ];
          roles.${name} = rules;
        };

        operatorDeployment = scope.mkDeployment {
          inherit name;
          # Each operator pod installs the certificates, webhooks, and
          # definitions when it starts; upstream runs one.
          availability.max = "none";
          requires = [
            self.validatingWebhook
            self.mutatingWebhook
          ];
          spec = {
            replicas = 1;
            selector.matchLabels = podLabels;
            template = {
              metadata.labels = podLabels;
              spec = {
                serviceAccount = self.serviceAccount;
                # The Kubernetes default, written out for the scorecard's
                # gracefulShutdown rule.
                terminationGracePeriodSeconds = 30;
                # The image's user: 185 in the JVM image, 1000 in the native one.
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = uid;
                  runAsGroup = uid;
                  fsGroup = uid;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = [
                  (
                    {
                      inherit name env;
                      image = kix.image.ref config.image;
                      ports = [
                        (kix.port "http" httpPort)
                        (kix.port "https" 8443)
                      ];
                      livenessProbe = {
                        httpGet = {
                          path = "/q/health/live";
                          port = "http";
                        };
                        initialDelaySeconds = 10;
                        periodSeconds = 60;
                        timeoutSeconds = 10;
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "/q/health/ready";
                          port = "http";
                        };
                        periodSeconds = 2;
                        timeoutSeconds = 1;
                      };
                      resources = config.resources;
                      # The operator writes only to /tmp.
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        capabilities.drop = [ "ALL" ];
                        readOnlyRootFilesystem = true;
                      };
                      volumeMounts = [
                        {
                          name = "operator-certs";
                          mountPath = "/etc/operator/certs";
                          readOnly = true;
                        }
                        {
                          name = "tmp";
                          mountPath = "/tmp";
                        }
                      ];
                    }
                    // lib.optionalAttrs (pullPolicy != null) { imagePullPolicy = pullPolicy; }
                  )
                ];
                volumes = [
                  {
                    name = "operator-certs";
                    secret = {
                      # The operator creates this Secret when it starts
                      # (INSTALL_CERTS).
                      secretName = kix.untrackedRef {
                        name = "${name}-certs";
                        by = "self";
                      };
                      optional = true;
                    };
                  }
                  {
                    name = "tmp";
                    emptyDir = { };
                  }
                ];
              };
            };
          };
        };

        # The operator writes `clientConfig.service.name = OPERATOR_NAME` into
        # every webhook entry, so the Service is named after the instance.
        operatorService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          inherit name;
          labels."app.kubernetes.io/component" = "webhook";
          spec = {
            selector = self.operatorDeployment.out.selector;
            ports = [
              {
                name = "https";
                port = 443;
                targetPort = 8443;
                protocol = "TCP";
              }
            ];
          };
        };

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.operatorDeployment
            |> kix.service.fromWorkload {
              name = metricsServiceName;
              labels."app.kubernetes.io/component" = "metrics";
              ports = [
                {
                  name = "metrics";
                  port = httpPort;
                  targetPort = "http";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        # Metadata only: the operator writes every entry with its caBundle, so
        # Kix and the operator never write the same field.
        validatingWebhook = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "ValidatingWebhookConfiguration";
          inherit name;
        };
        mutatingWebhook = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "MutatingWebhookConfiguration";
          inherit name;
        };

        webhookCheckServiceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = checkName;
          labels = checkLabels;
          extra.automountServiceAccountToken = true;
        };

        webhookCheckClusterRole = mkClusterRoleSet scope {
          subjects = checkSubjects;
          labels = checkLabels;
          roles.${checkName} = grant [
            (
              [
                admission.mutatingwebhookconfigurations
                admission.validatingwebhookconfigurations
              ]
              |> map (restrictTo [ name ])
              |> allow [ "get" ]
            )
          ];
        };

        # A dry-run create needs the create verb; the API server persists
        # nothing.
        webhookCheckRole = mkRoleSet scope {
          subjects = checkSubjects;
          labels = checkLabels;
          roles.${checkName} = grant [
            (allow [ "create" ] (rbacGroup group [ "sginstanceprofiles" ]).sginstanceprofiles)
          ];
        };

        webhookCheck = scope.mkJob {
          name = checkName;
          labels = checkLabels;
          # A Job's pod template is immutable, so a changed check replaces the
          # Job.
          annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
          requires = [
            self.operatorDeployment
            self.operatorService
            self.validatingWebhook
            self.mutatingWebhook
            self.crds.${kinds.SGInstanceProfile.part}
          ]
          ++ builtins.attrValues self.webhookCheckClusterRole
          ++ builtins.attrValues self.webhookCheckRole;
          spec = {
            backoffLimit = 1;
            template = {
              metadata.labels = checkLabels;
              spec = {
                restartPolicy = "Never";
                serviceAccount = self.webhookCheckServiceAccount;
                enableServiceLinks = false;
                # The image's stackgres user.
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 1000;
                  runAsGroup = 1000;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = [
                  (
                    {
                      name = "webhook-check";
                      image = kix.image.ref config.webhookCheck.image;
                      command = [
                        "/bin/bash"
                        "-c"
                        checkScript
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
                      # that does not set them, and every StackGres custom
                      # resource waits on this Job.
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
        };

        # One reference per kind. A custom resource built from one waits for
        # the definition, which the operator installs after it starts, and for
        # the webhook check.
        crds = lib.mapAttrs' (
          kind: k:
          lib.nameValuePair k.part (
            gate (
              scope.mkCRDRef (
                {
                  inherit group kind;
                  inherit (k) plural version;
                  servedVersions = k.servedVersions or null;
                  readiness = k.readiness or null;
                  inherit (k) holdsData;
                  installedBy = self.operatorDeployment;
                }
                // lib.optionalAttrs (kind == "SGCluster") {
                  # The operand pods dial the addresses in an SGCluster spec,
                  # including an SGObjectStorage endpoint it references.
                  factBehavior = {
                    endpoint = "terminate";
                    podSelector = cr: operandSelectors.sgCluster cr.metadata.name;
                  };
                }
                // lib.optionalAttrs (kind == "SGCluster") {
                  # Count `spec.instances` pods, lowered to
                  # `spec.autoscaling.minInstances` when horizontal autoscaling is
                  # active (`mode` is `"all"`, the default, or `"horizontal"`) and to
                  # 1 when replicas initialize from a newly created backup. Each
                  # pod has one claim of `spec.pods.persistentVolume.size`. Pod
                  # resources are not counted because they live on the
                  # referenced `SGInstanceProfile`.
                  usesAtLeast =
                    cr:
                    let
                      spec = cr.spec or { };
                      autoscaling = spec.autoscaling or null;
                      scales =
                        autoscaling != null
                        && builtins.elem (autoscaling.mode or "all") [
                          "all"
                          "horizontal"
                        ];
                      fromNewBackup = (spec.replication.initialization.mode or null) == "FromNewlyCreatedBackup";
                      pods = lib.foldl' lib.min (spec.instances or 0) (
                        lib.optional scales (autoscaling.minInstances or 0) ++ lib.optional fromNewBackup 1
                      );
                    in
                    kix.usage.times pods {
                      pods = 1;
                      persistentvolumeclaims = 1;
                      "requests.storage" = spec.pods.persistentVolume.size or null;
                    };
                }
                // lib.optionalAttrs (kind == "SGDistributedLogs") {
                  # Count the single-instance `SGCluster` created for distributed
                  # logs, with its one claim of `spec.persistentVolume.size`.
                  usesAtLeast = cr: {
                    pods = 1;
                    persistentvolumeclaims = 1;
                    "requests.storage" = cr.spec.persistentVolume.size or null;
                  };
                }
                # Profiles, configurations, storage definitions, and scripts
                # are read by the clusters that name them and run no pods.
                // lib.optionalAttrs (builtins.elem kind [
                  "SGInstanceProfile"
                  "SGObjectStorage"
                  "SGPoolingConfig"
                  "SGPostgresConfig"
                  "SGScript"
                ]) { usesAtLeast = _: { }; }
                // lib.optionalAttrs (kind == "SGObjectStorage") {
                  # No pod dials the endpoint for the SGObjectStorage; the
                  # SGCluster that references it carries the address on.
                  factBehavior.endpoint = "conduct";
                }
              )
            )
          )
        ) referencedKinds;

        root = {
          resource = self.operatorDeployment;
          requires = [
            self.operatorService
          ]
          ++ builtins.attrValues self.clusterRole
          ++ builtins.filter (r: r != null) [ self.metricsService ];
          postHooks = [ self.webhookCheck ];
          out = {
            version = kix.image.version config.image;
            crds = lib.mapAttrs (_: k: self.crds.${k.part}) referencedKinds;
            inherit operandSelectors release;
            podSelector = self.operatorDeployment.out.selector;
            kubectlImages = kubectlImages {
              inherit registry;
              k8sVersion = clusterConfig.k8sVersion or null;
            };
            resolvePostgres =
              { who, version }:
              resolvePostgres {
                inherit who version registry;
                operatorTag = imageTag;
              };
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
        reconcileErrors = "sum by (namespace, service, resource) (increase(sg_operator_reconciliation_total_errors{${sel}}[30m]))";
        reconciles = "sum by (namespace, service, resource) (increase(sg_operator_reconciliation_total_performed{${sel}}[30m]))";
        operator = "StackGres operator ${ns}/${name}";
      in
      kix.monitor {
        service = "metricsService";
        path = "/q/metrics";
        alerts = {
          StackGresOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The StackGres operator is down.";
            description = "No replica of the ${operator} has answered a scrape for 10 minutes. Running PostgreSQL clusters keep serving, but changes to SGClusters and other stackgres.io resources are not applied, and its webhooks refuse creating or updating one. Check the operator Deployment in ${ns}.";
          };
          # The operator keeps its error count in a gauge that only grows
          # (io.stackgres.operator.common.Metrics upstream), and publishes
          # the series after the first error, so rate() sees the second.
          StackGresOperatorReconcileErrors = {
            # Both counters are gauges that only grow, so increase() reads them.
            # Alert on the share of reconciles that fail, with a floor, so a
            # retried conflict on a busy operator stays quiet.
            expr = "${reconcileErrors} / ${reconciles} > 0.1 and ${reconcileErrors} > 2";
            "for" = "15m";
            severity = "warning";
            summary = "The StackGres operator fails to reconcile its resources.";
            description = "The ${operator} has failed {{ $value | humanizePercentage }} of its reconciles of {{ $labels.resource }} resources over the last 30 minutes, so one of them may not match its spec. The operator log names the resource and the error.";
          };
        };
      } args
    )
  ];
}

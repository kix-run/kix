# cnpg-operator: the CloudNativePG operator, which runs PostgreSQL clusters
# declared as postgresql.cnpg.io custom resources.
#
# The package applies the postgresql.cnpg.io CustomResourceDefinitions
# (crds/, vendored from the release manifest), the operator's ClusterRole
# (rbac/, from the same manifest), the operator Deployment, the webhook
# Service, the two admission webhook configurations with every entry, and
# the default monitoring queries (monitoring/, from the same manifest),
# which the operator copies into the namespace of each Cluster for the
# instance manager's exporter.
# When it starts, the operator creates its CA and serving certificate in the
# Secrets cnpg-ca-secret and cnpg-webhook-cert and writes the certificate
# into each webhook entry's `clientConfig.caBundle`. Kix never sets
# caBundle, so the operator is its only writer. The Deployment requires the
# two configurations, because the operator fails to start when it cannot
# read them.
#
# Every webhook entry has failurePolicy Fail, and until the operator has
# written its caBundle the API server cannot call it, so a custom resource
# created in that window is refused. Every CRD handle in `out.crds`
# therefore adds the webhook-check Job to the requires of each custom
# resource built from it. The Job runs a server-side dry-run create of a
# Cluster, which succeeds only once the mutating and validating webhooks for
# Cluster both answer.
#
# A cluster runs one instance (`conflictsWith`): the definitions and webhook
# configurations are cluster-wide, and the operator fixes the names of the
# webhook Service (cnpg-webhook-service), its certificate Secrets, and, with
# ENABLE_WEBHOOK_NAMESPACE_SUFFIX off, the webhook configurations
# (internal/cmd/manager/controller/controller.go and
# internal/configuration/configuration.go upstream). The operator watches
# every namespace, as upstream ships it; WATCH_NAMESPACE is refused because
# the ClusterRole and the webhooks stay cluster-wide.
#
# The operator labels the Secrets it creates as owned by its Deployment,
# which it finds by the label app.kubernetes.io/name=cloudnative-pg in its
# namespace, so the pods carry that label and no other Deployment in the
# namespace may.
#
# Minimal instance:
#
#   instances.cnpg-system.cnpg-operator.package = packages.cnpg-operator;
#
# Dependencies:
#   prometheus (optional)   a metrics Service and ServiceMonitor for the
#                           operator's metrics (TCP 8080) while
#                           `metrics.enabled`.
#
# Replicas: one at availability none and pod, two from node up. The
# replicas elect a leader for reconciling, and each serves the webhooks.
#
# Escape hatches: `env` (operator variables from
# internal/configuration/configuration.go, such as INSTANCES_ROLLOUT_DELAY
# or DRAIN_TAINTS), `webhookCheck.image`, and the instance's
# `partsOverlays`.
#
# `out`:
#   out.crds.<Kind>   CRD handles for scope.mkCR: Cluster, Database,
#                     DatabaseRole, ImageCatalog, ClusterImageCatalog,
#                     Publication, Subscription, ScheduledBackup, and
#                     Pooler.
#                       scope.mkCR cnpgOperator.out.crds.Cluster { ... }
#   out.operandSelectors.cluster crName
#                     the labels of a Cluster's instance and Job pods.
#   out.podSelector   the operator pods' labels.
#   out.release       the CloudNativePG release.
#   out.version       the CloudNativePG version `image.tag` names.
#
# Network policy: the webhook intent admits the API server on TCP 9443 to
# every pod of the package, the webhook-check Job's included, where nothing
# listens on that port.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   CNPGOperatorDown (warning)             no operator replica answers a
#                                          scrape. Running PostgreSQL
#                                          clusters keep serving, with no
#                                          failover while it is down; changes
#                                          to Clusters are not applied, and
#                                          the webhooks refuse creates and
#                                          updates.
#   CNPGOperatorReconcileErrors (warning)  reconciles of one kind fail for
#                                          15 minutes.
# The webhooks answer every request with HTTP 200 and put any failure in the
# admission response (controller-runtime pkg/webhook/admission/http.go), so
# no metric of the operator counts webhook errors; the down alert covers a
# webhook that does not answer. Fewer ready replicas than desired is left to
# prometheus-default-rules (KubeDeploymentReplicasMismatch), and the health
# of each PostgreSQL cluster to cnpg-cluster's alerts.
#
# Limits: Backup and FailoverQuorum have definitions (the operator watches
# them) and no handle, so no package builds them. The operator's metrics
# endpoint is served over plain HTTP (METRICS_CERT_DIR unset, as upstream
# ships it). Network policy for operand pods comes from cnpg-cluster and
# cnpg-pooler.
#
# root = the operator Deployment; the webhook check runs after it.
#
# Moving to another release: set `release` and the digest of `image`
# (`crane digest ghcr.io/cloudnative-pg/cloudnative-pg:<release>`), move the
# tag in crds/sources.txt and rbac/sources.txt, run
# `uv run scripts/vendor-crds.py cnpg-operator`, replace
# monitoring/configmap-cnpg-default-monitoring.json with the manifest's
# ConfigMap cnpg-default-monitoring (the script vendors only definitions
# and roles), compare the webhook entries below with the release manifest's
# webhook configurations, set the Kubernetes range in `meta.k8s`, then run the
# kix-lib test cnpg-operator-sources-match-release and
# every-package-evaluates.
#
# Upgrades: a patch release such as 1.30.2 upgrades directly from the
# previous patch. The deploy restarts the operator, then the operator rolls
# each PostgreSQL cluster to the new instance manager, and each rollout ends
# with a switchover unless `primaryUpdateStrategy` is supervised. Going back
# needs no data step: deploy the old package over the new one. Upstream
# documents neither path. The operator from 1.30.1 to 1.30.2 and back was
# tested on kind with a one-instance and a two-instance cluster.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # meta.version, the default image.tag, and the tag in crds/sources.txt and
  # rbac/sources.txt.
  release = "1.30.2";
  minorOf = lib.versions.majorMinor;

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "cnpg-operator ${ns}/${name}";

  group = "postgresql.cnpg.io";
  vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
  readJSON = file: builtins.fromJSON (builtins.readFile file);

  # The operator finds its own Deployment by this label
  # (OperatorDeploymentLabelSelector in controller.go).
  podLabels = {
    "app.kubernetes.io/name" = "cloudnative-pg";
    "app.kubernetes.io/instance" = name;
  };

  # Fixed by the operator: it issues its serving certificate for this
  # Service and reads the configurations by these names.
  webhookServiceName = "cnpg-webhook-service";
  mutatingConfigName = "cnpg-mutating-webhook-configuration";
  validatingConfigName = "cnpg-validating-webhook-configuration";
  webhookPort = 9443;
  # The manager's --metrics-bind-address default
  # (internal/cmd/manager/controller/cmd.go upstream).
  metricsPort = 8080;
  # The metrics Service, whose name the alerts select on.
  metricsServiceName = "${name}-metrics";

  # The release manifest's ConfigMap cnpg-default-monitoring: its `queries`
  # and the cnpg.io/reload label, which has the operator refresh its copies
  # when the queries change.
  defaultMonitoring = readJSON ./monitoring/configmap-cnpg-default-monitoring.json;

  # The release manifest's webhook entries: each admits CREATE and UPDATE
  # of one kind, served at /<mutate|validate>-postgresql-cnpg-io-v1-<kind>.
  mutatingKinds = [
    "backup"
    "cluster"
    "database"
    "scheduledbackup"
  ];
  validatingKinds = [
    "backup"
    "cluster"
    "database"
    "pooler"
    "scheduledbackup"
  ];

  # The instance pods carry cnpg.io/podRole=instance as well; this selects
  # the initdb and join Job pods of the Cluster too.
  operandSelectors.cluster = crName: { "cnpg.io/cluster" = crName; };

  fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };

  # CloudNativePG writes no observedGeneration on the Cluster's Ready
  # condition (SetClusterReadyCondition in pkg/resources/status), so right
  # after a spec change the deploy can read the previous Ready=True.
  ready.condition = {
    type = "Ready";
    status = "True";
  };
  # Database, DatabaseRole, Publication, and Subscription report the result
  # of their last reconcile as the boolean status.applied.
  applied = {
    path = "/status/applied";
    equals = "true";
  };
in
{
  meta = {
    version = release;
    description = "CloudNativePG operator: runs PostgreSQL clusters declared as postgresql.cnpg.io resources";
    owner = "platform";
    defaultAliases = [ "cnpgOperator" ];
    conflictsWith = [ "cluster:cnpgOperator" ];
    # The operator reads cnpg.io annotations on Clusters and their objects,
    # and on the Services that register plugins.
    annotationDomains = [ "cnpg.io" ];
    # The Kubernetes versions upstream supports for the 1.30.x series, from
    # the support status table on its supported releases page
    # (https://cloudnative-pg.io/docs/1.30/supported_releases/). Upstream
    # also tests 1.33 and 1.37, and no version from 1.31 is known to fail,
    # so the minimum stays where it was. Move `supported` with `release`.
    k8s = {
      minVersion = "1.31";
      supported = {
        minVersion = "1.34";
        maxVersion = "1.36";
        source = "the support status table at cloudnative-pg.io/docs/1.30/supported_releases";
      };
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
    let
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
    in
    [
      {
        assertion = minorOf imageTag == minorOf release;
        message = "image.tag \"${imageTag}\" is not a CloudNativePG ${minorOf release} release, and the definitions under kix/packages/stable/cnpg-operator/crds and the ClusterRole under rbac are vendored from ${release}. Set image.tag to a ${minorOf release}.x tag, or move the package to another release as its header describes.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "ghcr.io/cloudnative-pg/cloudnative-pg";
      tag = release;
      digest = "sha256:f96f6be3d81ec93819b443c665c575c609342fca840df90d4d87dae314a5b913";
      description = "Operator image. Its major.minor must be the package's release. The operator also runs it as the init container of every PostgreSQL pod (OPERATOR_IMAGE_NAME).";
    };

    # Requests and the memory limit are the release manifest's values. The
    # manifest also caps CPU at its 100m request, which throttles the
    # operator whenever it reconciles many objects at once, as during a
    # rolling restart of a Cluster; the limit here lets it burst to one core.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "100Mi";
      };
      limits = {
        cpu = "1";
        memory = "200Mi";
      };
    };

    webhookCheck.image = kix.options.image {
      repository = "registry.k8s.io/kubectl";
      tag = "v1.37.1";
      digest = "sha256:b7cab618e281b1ee7484e7b706a96e2135fbb6e072c2a573a7dab4e87d7f2385";
      description = "Image of the webhook-check Job. Its entrypoint must be kubectl.";
    };

    metrics = kix.options.monitor;

    env = kix.options.env // {
      description = "Extra operator environment variables from CloudNativePG's operator configuration, such as INSTANCES_ROLLOUT_DELAY or DRAIN_TAINTS. A value is a string, a `fieldRef`, or `kix.untrackedRef`. The variables the package sets or refuses fail with the reason.";
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
        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            owned = [
              {
                vars = {
                  OPERATOR_IMAGE_NAME = kix.image.ref config.image;
                  OPERATOR_NAMESPACE = fieldRef "metadata.namespace";
                };
                from = "the image option and the instance's namespace";
                fix = "Set image instead.";
              }
              {
                vars.MONITORING_QUERIES_CONFIGMAP = self.defaultMonitoring.out.name;
                from = "the package's default monitoring queries";
                fix = "Add queries to a Cluster with spec.monitoring.customQueriesConfigMap in the cnpg-cluster's extraSpec instead.";
              }
              {
                vars.KUBERNETES_CLUSTER_DOMAIN = clusterConfig.clusterDomain;
                from = "the cluster's clusterDomain";
                fix = "Remove it.";
              }
              {
                names = [ "WATCH_NAMESPACE" ];
                from = "this package, which leaves it unset so the operator watches every namespace";
                fix = "The ClusterRole and the webhooks stay cluster-wide, and a cluster runs one CloudNativePG operator. Remove it.";
              }
              {
                names = [
                  "WEBHOOK_CERT_DIR"
                  "MANAGE_WEBHOOK_CONFIGURATIONS"
                  "ENABLE_WEBHOOK_NAMESPACE_SUFFIX"
                ];
                from = "this package: the webhook configurations it renders carry no caBundle and the operator's default names, so the operator must issue its certificate and write caBundle into them";
                fix = "Remove it.";
              }
              {
                names = [
                  "INHERITED_ANNOTATIONS"
                  "INHERITED_LABELS"
                ];
                from = "this package: the operator would copy matching Kix annotations from a Cluster to its pods and claims, and `kix gc` treats an object carrying a Kix identity hash as its own";
                fix = "Set spec.inheritedMetadata in the cnpg-cluster's extraSpec instead.";
              }
            ];
          } config.env
        );

        inherit (scope.rbac)
          allow
          grant
          mkClusterRoleSet
          mkRoleSet
          ;

        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];

        webhookEntry =
          type: kind:
          let
            prefix = if type == "mutate" then "m" else "v";
          in
          {
            name = "${prefix}${kind}.cnpg.io";
            admissionReviewVersions = [ "v1" ];
            # The fixed name, without the Service's context: the Deployment
            # requires these configurations, and the Service selects the
            # Deployment's pods, so a reference would close a cycle.
            clientConfig.service = {
              name = webhookServiceName;
              namespace = ns;
              path = "/${type}-postgresql-cnpg-io-v1-${kind}";
              port = 443;
            };
            failurePolicy = "Fail";
            rules = [
              {
                apiGroups = [ group ];
                apiVersions = [ "v1" ];
                operations = [
                  "CREATE"
                  "UPDATE"
                ];
                resources = [ "${kind}s" ];
              }
            ];
            sideEffects = "None";
          };

        # The webhook check. With both configurations in place from the start,
        # a dry-run create of a Cluster succeeds only when the API server can
        # call both Cluster webhooks and trusts the operator's certificate.
        # kubectl exits non-zero otherwise, and the Job retries.
        checkName = "${name}-webhook-check";
        checkLabels."app.kubernetes.io/name" = checkName;
        checkFile = "cluster.json";
        checkCluster = builtins.toJSON {
          apiVersion = "${group}/v1";
          kind = "Cluster";
          # A fixed name fails the dry-run when a Cluster of that name exists.
          metadata = {
            generateName = "${checkName}-";
            namespace = ns;
          };
          spec = {
            instances = 1;
            storage.size = "1Gi";
          };
        };

        # Every custom resource of a gated kind waits for the webhook check.
        checked = [ self.webhookCheck ];
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        clusterRole = mkClusterRoleSet scope {
          inherit subjects;
          roles.${name} = (readJSON ./rbac/clusterrole-cnpg-manager.json).rules;
        };

        # The operator watches every kind, so every definition is applied,
        # with or without a handle.
        #
        # A Cluster keeps its databases on its volumes, and a Database is one
        # of them. The operator keeps a Database's contents when the custom
        # resource is deleted unless `databaseReclaimPolicy` is `delete`, so
        # it is marked as holding data. Backups live in the object store and
        # outlive their Backup objects. The other kinds are configuration.
        # Only a Cluster and a Pooler run pods.
        crds = {
          backups = scope.mkCRD {
            spec = vendored "backups.${group}.json";
            holdsData = false;
            usesAtLeast = _: { };
          };
          # A ScheduledBackup and a Pooler report no conditions; a Pooler's
          # consumers wait on its Service's endpoints instead.
          scheduledBackups = scope.mkCRD {
            spec = vendored "scheduledbackups.${group}.json";
            crRequires = checked;
            holdsData = false;
            usesAtLeast = _: { };
          };
          poolers = scope.mkCRD {
            spec = vendored "poolers.${group}.json";
            crRequires = checked;
            holdsData = false;
            # Count `spec.instances` PgBouncer pods (default 1), each with
            # every container in `spec.template`, and the one Service the
            # operator makes for the Pooler.
            usesAtLeast =
              cr:
              kix.usage.add [
                (kix.usage.times (cr.spec.instances or 1) (
                  kix.usage.ofPod (cr.spec.template.spec.containers or [ ])
                ))
                { services = 1; }
              ];
          };
          failoverQuorums = scope.mkCRD {
            spec = vendored "failoverquorums.${group}.json";
            holdsData = false;
            usesAtLeast = _: { };
          };
          clusters = scope.mkCRD {
            spec = vendored "clusters.${group}.json";
            crRequires = checked;
            readiness = ready;
            holdsData = true;
            # The instances dial the hosts a Cluster names (externalClusters).
            factBehavior = {
              endpoint = "terminate";
              podSelector = cr: operandSelectors.cluster cr.metadata.name;
            };
            # Count `spec.instances` instance pods, sized by `spec.resources`.
            # Each instance has one claim for its data, one for
            # `spec.walStorage` when set, and one per tablespace. A claim
            # counts only when its size is known. The rw, ro, and r Services
            # count unless `spec.managed.services` disables them, plus each
            # additional managed Service. Short-lived init and join Jobs are
            # excluded.
            usesAtLeast =
              cr:
              let
                spec = cr.spec or { };
                instances = spec.instances or 1;
                sizeOf = storage: storage.size or storage.pvcTemplate.resources.requests.storage or null;
                sizes = builtins.filter (size: size != null && size != "") (
                  map sizeOf (
                    [ (spec.storage or { }) ]
                    ++ lib.optional (spec ? walStorage) spec.walStorage
                    ++ map (t: t.storage or { }) (spec.tablespaces or [ ])
                  )
                );
                services = spec.managed.services or { };
                disabled = services.disabledDefaultServices or [ ];
              in
              kix.usage.add (
                [
                  (kix.usage.times instances (kix.usage.ofPod [ { resources = spec.resources or { }; } ]))
                  {
                    services =
                      builtins.length (
                        builtins.filter (t: !(builtins.elem t disabled)) [
                          "rw"
                          "ro"
                          "r"
                        ]
                      )
                      + builtins.length (services.additional or [ ]);
                  }
                ]
                ++ map (
                  size:
                  kix.usage.times instances {
                    persistentvolumeclaims = 1;
                    "requests.storage" = size;
                  }
                ) sizes
              );
          };
          databases = scope.mkCRD {
            spec = vendored "databases.${group}.json";
            crRequires = checked;
            readiness = applied;
            holdsData = true;
            usesAtLeast = _: { };
          };
          databaseRoles = scope.mkCRD {
            spec = vendored "databaseroles.${group}.json";
            crRequires = checked;
            readiness = applied;
            holdsData = false;
            usesAtLeast = _: { };
          };
          publications = scope.mkCRD {
            spec = vendored "publications.${group}.json";
            crRequires = checked;
            readiness = applied;
            holdsData = false;
            usesAtLeast = _: { };
          };
          subscriptions = scope.mkCRD {
            spec = vendored "subscriptions.${group}.json";
            crRequires = checked;
            readiness = applied;
            holdsData = false;
            usesAtLeast = _: { };
          };
          imageCatalogs = scope.mkCRD {
            spec = vendored "imagecatalogs.${group}.json";
            crRequires = checked;
            holdsData = false;
            usesAtLeast = _: { };
          };
          clusterImageCatalogs = scope.mkCRD {
            spec = vendored "clusterimagecatalogs.${group}.json";
            crRequires = checked;
            holdsData = false;
            usesAtLeast = _: { };
          };
        };

        defaultMonitoring = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-default-monitoring";
          inherit (defaultMonitoring.metadata) labels;
          inherit (defaultMonitoring) data;
        };

        webhookService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = webhookServiceName;
          labels."app.kubernetes.io/component" = "webhook";
          spec = {
            selector = self.operatorDeployment.out.selector;
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
          name = mutatingConfigName;
          extra.webhooks = map (webhookEntry "mutate") mutatingKinds;
        };
        validatingWebhook = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "ValidatingWebhookConfiguration";
          name = validatingConfigName;
          extra.webhooks = map (webhookEntry "validate") validatingKinds;
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
                  port = metricsPort;
                  targetPort = "metrics";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        operatorDeployment = scope.mkDeployment {
          inherit name;
          requires = [
            self.mutatingWebhook
            self.validatingWebhook
          ]
          ++ builtins.attrValues self.crds
          ++ builtins.attrValues self.clusterRole;
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
                      name = "manager";
                      image = kix.image.ref config.image;
                      command = [ "/manager" ];
                      args = [
                        "controller"
                        "--leader-elect"
                        "--max-concurrent-reconciles=10"
                        "--webhook-port=${toString webhookPort}"
                      ];
                      inherit env;
                      ports = [
                        (kix.port "metrics" metricsPort)
                        (kix.port "webhook-server" webhookPort)
                      ];
                      startupProbe = {
                        httpGet = {
                          path = "/readyz";
                          port = webhookPort;
                          scheme = "HTTPS";
                        };
                        periodSeconds = 5;
                        failureThreshold = 6;
                      };
                      livenessProbe.httpGet = {
                        path = "/readyz";
                        port = webhookPort;
                        scheme = "HTTPS";
                      };
                      readinessProbe.httpGet = {
                        path = "/readyz";
                        port = webhookPort;
                        scheme = "HTTPS";
                      };
                      resources = config.resources;
                      # The image's user; the operator writes only under
                      # /controller and reads its certificates.
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        capabilities.drop = [ "ALL" ];
                        readOnlyRootFilesystem = true;
                        runAsUser = 10001;
                        runAsGroup = 10001;
                      };
                      volumeMounts = [
                        {
                          name = "scratch-data";
                          mountPath = "/controller";
                        }
                        {
                          name = "webhook-certificates";
                          mountPath = "/run/secrets/cnpg.io/webhook";
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
                    name = "scratch-data";
                    emptyDir = { };
                  }
                  {
                    name = "webhook-certificates";
                    secret = {
                      # The operator creates this Secret when it starts.
                      secretName = kix.untrackedRef {
                        name = "cnpg-webhook-cert";
                        by = "self";
                      };
                      optional = true;
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
        webhookCheckRole = mkRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.webhookCheckServiceAccount.out.name;
              namespace = ns;
            }
          ];
          labels = checkLabels;
          roles.${checkName} = grant [
            (allow [ "create" ] (scope.rbac.group group [ "clusters" ]).clusters)
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
            annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
            requires = builtins.attrValues self.webhookCheckRole;
            spec = {
              # The kubelet restarts the container with a growing delay (10 s
              # doubling to 5 min), so eight attempts span about 15 minutes.
              backoffLimit = 8;
              template = {
                metadata = {
                  labels = checkLabels;
                  annotations = {
                    "checksum/operator" = self.operatorDeployment.out.contentHash;
                    "checksum/webhook-service" = self.webhookService.out.contentHash;
                    "checksum/mutating-webhook" = self.mutatingWebhook.out.contentHash;
                    "checksum/validating-webhook" = self.validatingWebhook.out.contentHash;
                    "checksum/crd" = self.crds.clusters.out.contentHash;
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
                        # that does not set them, and every CloudNativePG
                        # custom resource waits on this Job.
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
          resource = self.operatorDeployment;
          requires = [
            self.webhookService
          ]
          ++ builtins.filter (r: r != null) [ self.metricsService ];
          postHooks = [ self.webhookCheck ];
          out = {
            crds = {
              Cluster = self.crds.clusters;
              Database = self.crds.databases;
              DatabaseRole = self.crds.databaseRoles;
              Publication = self.crds.publications;
              Subscription = self.crds.subscriptions;
              ScheduledBackup = self.crds.scheduledBackups;
              Pooler = self.crds.poolers;
              ImageCatalog = self.crds.imageCatalogs;
              ClusterImageCatalog = self.crds.clusterImageCatalogs;
            };
            inherit operandSelectors release;
            version = kix.image.version config.image;
            podSelector = self.operatorDeployment.out.selector;
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
        reconcileErrors = "sum by (namespace, service, controller) (increase(controller_runtime_reconcile_errors_total{${sel}}[30m]))";
        reconciles = "sum by (namespace, service, controller) (increase(controller_runtime_reconcile_total{${sel}}[30m]))";
        operator = "CloudNativePG operator ${ns}/${name}";
      in
      kix.monitor {
        service = "metricsService";
        alerts = {
          CNPGOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The CloudNativePG operator is down.";
            description = "No replica of the ${operator} has answered a scrape for 10 minutes. Running PostgreSQL clusters keep serving, but no failover happens, changes to Clusters are not applied, and its webhooks refuse creating or updating one. Check the operator Deployment in ${ns}.";
          };
          CNPGOperatorReconcileErrors = {
            # controller-runtime counts an optimistic-lock conflict as an error
            # and retries at once, so a busy healthy controller shows a few.
            # Alert on the share of reconciles that fail, with a floor.
            expr = "${reconcileErrors} / ${reconciles} > 0.1 and ${reconcileErrors} > 2";
            "for" = "15m";
            severity = "warning";
            summary = "The CloudNativePG operator fails to reconcile its resources.";
            description = "The {{ $labels.controller }} controller of the ${operator} has failed {{ $value | humanizePercentage }} of its reconciles over the last 30 minutes, so a resource of that kind may not match its spec. The operator log names the error and the resource.";
          };
        };
      } args
    )
  ];
}

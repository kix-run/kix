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
# A cluster runs one instance: the definitions and webhook configurations are
# cluster-wide, and the webhooks have no namespaceSelector, so they admit
# every namespace. `conflictsWith` refuses a second instance.
#
# The SGConfig sets `deploy.restapi` and `deploy.collector` to false. The
# REST API, web console, and OpenTelemetry collector are pods the operator
# creates from the SGConfig, and Kix gives them no RBAC binding or network
# policy, so the package does not run them. PostgreSQL metrics come from each
# cluster's exporter sidecar (stackgres-cluster `metrics`).
#
# The operator merges SGCONFIG into the live SGConfig. A key removed from
# `sgConfig` keeps its old value there; set it explicitly instead.
#
# Minimal instance:
#
#   instances.stackgres-system.stackgres-operator.package = packages.stackgres-operator;
#
# DI deps: none.
#
# Escape hatches: `sgConfig` (SGConfig spec), `env` (operator variables such
# as OPERATOR_LOG_LEVEL or JAVA_OPTS), and the instance's `partsOverlays`.
#
# Exposes:
#   out.crds.<Kind>   CRD references for scope.mkCR, one per stackgres.io kind
#                     except SGConfig, which this package owns:
#                       scope.mkCR stackgresOperator.out.crds.SGCluster { ... }
#   out.operandSelectors.sgCluster crName
#                     the labels of an SGCluster's pods.
#   out.podSelector   the operator pods' labels.
#   out.release       the StackGres release.
#   out.postgresVersions
#                     PostgreSQL major -> minors this release ships.
#   out.resolvePostgres { who; version; }
#                     { major; minor; images } for an SGCluster at `version`,
#                     with images from this operator's registry. Throws,
#                     prefixed with `who`, for `latest` or a release the table
#                     does not ship.
#
# root = the operator Deployment.
#
# Moving to another release: replace versions.properties with
# versions-<major.minor>.properties from stackgres-k8s/src/common/src/main/resources
# at the new tag, set `release` in release.nix and the image digest below
# (`crane digest quay.io/stackgres/operator:<release>`), compare kinds.nix
# with the chart's crds/ and the RBAC below with its operator-cluster-role.yaml,
# then run the stackgres eval checks (every-package-evaluates, ludo-kind).

{
  scope,
  lib,
  kix,
}:

let
  inherit (import ./release.nix { inherit lib; })
    release
    postgresVersions
    resolvePostgres
    ;
  kinds = import ./kinds.nix;

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "stackgres-operator ${ns}/${name}";

  group = "stackgres.io";
  podLabels = {
    app = name;
    group = group;
  };

  # The SGConfig is the operator's own configuration, set through
  # `sgConfig`. A second SGConfig written from a cluster file would compete
  # with it, so its kind gets no CRD reference.
  referencedKinds = removeAttrs kinds [ "SGConfig" ];

  operandSelectors.sgCluster = crName: {
    app = "StackGresCluster";
    "stackgres.io/cluster-name" = crName;
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
    in
    [
      {
        assertion = lib.removeSuffix "-jvm" config.image.tag == release;
        message = "image.tag \"${config.image.tag}\" is not StackGres ${release}, the release this package's version table and CRD list describe. Move the operator by following the steps in the header of kix/packages/stackgres-operator/default.nix.";
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

    # The 1.19.2 chart's defaults.
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

    env = kix.options.env // {
      description = "Extra operator environment variables, such as OPERATOR_LOG_LEVEL or JAVA_OPTS. A value is a string, a `fieldRef`, or `kix.untrackedRef`. The variables the package sets are refused with the option that sets them.";
    };
  };

  build =
    { self, config, ... }:
    let
      registry = lib.removeSuffix operatorSuffix config.image.repository;
      nativeTag = lib.removeSuffix "-jvm" config.image.tag;
      jvm = lib.hasSuffix "-jvm" config.image.tag;
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
                OPERATOR_IMAGE_VERSION = config.image.tag;
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
        (allow [ "update" ] (map (sub "status") sg ++ map (sub "finalizers") sg))
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
          # The chart's selector.
          selector.matchLabels = podLabels;
          template = {
            metadata.labels = podLabels;
            spec = {
              serviceAccount = self.serviceAccount;
              # Kubernetes' default; the chart sets none.
              terminationGracePeriodSeconds = 30;
              # The chart's user: 185 in the JVM image, 1000 in the native one.
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
                      (kix.port "http" 8080)
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

      # One reference per kind. A custom resource built from one waits for
      # the definition, which the operator installs after it starts.
      crds = lib.mapAttrs' (
        kind: k:
        lib.nameValuePair k.part (
          scope.mkCRDRef (
            {
              inherit group kind;
              inherit (k) plural version;
              servedVersions = k.servedVersions or null;
              readiness = k.readiness or null;
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
          )
        )
      ) referencedKinds;

      root = {
        resource = self.operatorDeployment;
        requires = [
          self.operatorService
        ]
        ++ builtins.attrValues self.clusterRole;
        out = {
          crds = lib.mapAttrs (_: k: self.crds.${k.part}) referencedKinds;
          inherit operandSelectors release postgresVersions;
          podSelector = self.operatorDeployment.out.selector;
          resolvePostgres =
            { who, version }:
            resolvePostgres {
              inherit who version registry;
              operatorTag = config.image.tag;
            };
        };
      };
    };
}

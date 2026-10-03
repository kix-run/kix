# Tests for the CloudNativePG packages: the refusals of cnpg-operator,
# cnpg-cluster, and cnpg-database, each beside a positive control, the
# rendered Cluster, Database, and DatabaseRole, the webhook check that every
# postgresql.cnpg.io custom resource waits for, and the vendored sources'
# release.

{
  lib,
  eval,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  singleNode,
  ...
}:

let
  operatorPackage = import ../../../packages/cnpg-operator;
  clusterPackage = import ../../../packages/cnpg-cluster;
  databasePackage = import ../../../packages/cnpg-database;
  stackgresOperatorPackage = import ../../../packages/stackgres-operator;
  stackgresClusterPackage = import ../../../packages/stackgres-cluster;

  # A package's failed assertion messages for `config`, evaluated against
  # its options. Throws lose their message in tryEval, so the tests read
  # message text from assertions and check build throws with evalFails.
  failedMessages =
    {
      package,
      instanceName,
      namespaceName ? "data",
      config ? { },
    }:
    let
      attrs = package (
        builtins.intersectAttrs (builtins.functionArgs package) {
          scope = { inherit instanceName namespaceName; };
          inherit lib;
          kix = kixlib;
          availability = "none";
        }
      );
      evaluated = eval.evaluateInstanceConfig {
        packageOptions = attrs.options;
        instCfg.config.imports = [ config ];
        inherit namespaceName instanceName;
      };
    in
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        attrs.assertions {
          config = evaluated;
          deps = { };
        }
      )
    );
  says = fragment: messages: builtins.any (m: lib.hasInfix fragment m) messages;

  # The operator, a cluster `postgres`, and, unless `database` is null, a
  # cnpg-database `app-db` beside it.
  cnpg =
    {
      operatorConfig ? { },
      clusterConfig ? { },
      database ? {
        password = "password";
      },
      extra ? { },
    }:
    mkCluster [
      {
        instances.cnpg-system.cnpg-operator = {
          package = operatorPackage;
          config = operatorConfig;
        };
        instances.data = {
          postgres = {
            package = clusterPackage;
            config = clusterConfig;
          };
        }
        // lib.optionalAttrs (database != null) {
          app-db = {
            package = databasePackage;
            config = database;
          };
        };
      }
      extra
    ];
  ms = cluster: manifests cluster;
  clusterSpec = cluster: (byName "postgres" (ofKind "Cluster" (ms cluster))).spec;
in
{
  # Every postgresql.cnpg.io custom resource waits for the webhook check,
  # and the check is a server-side dry-run create of a Cluster.
  cnpg-operator-crd-handles-gated =
    let
      cluster = cnpg { };
      all = ms cluster;
      operator = cluster.instances.cnpg-system.cnpg-operator;
      jobHash = builtins.unsafeDiscardStringContext operator.raw.webhookCheck.out.identityHash;
      dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
      customResources = builtins.filter (m: lib.hasPrefix "postgresql.cnpg.io/" m.apiVersion) all;
      ungated = map (m: "${m.kind}/${m.metadata.name}") (
        builtins.filter (m: !(lib.hasInfix jobHash (dependsOn m))) customResources
      );
      kinds = lib.unique (lib.naturalSort (map (m: m.kind) customResources));
      container = builtins.head (byName "cnpg-operator-webhook-check" (ofKind "Job" all))
        .spec.template.spec.containers;
    in
    (
      ungated == [ ]
      &&
        kinds == [
          "Cluster"
          "Database"
          "DatabaseRole"
        ]
      &&
        container.args == [
          "create"
          "--dry-run=server"
          "--output=name"
          "--filename=/check/cluster.json"
        ]
    )
    || throw "webhook-check gate: ${
      builtins.toJSON {
        inherit ungated kinds;
        inherit (container) args;
      }
    }";

  # The webhook configurations carry every entry of the release manifest,
  # name the operator's fixed Service, and leave caBundle to the operator.
  cnpg-operator-webhook-entries =
    let
      all = ms (cnpg {
        database = null;
      });
      entries = kind: (builtins.head (ofKind kind all)).webhooks;
      names = kind: map (w: w.name) (entries kind);
      services = lib.unique (
        map (w: w.clientConfig.service.name) (
          entries "MutatingWebhookConfiguration" ++ entries "ValidatingWebhookConfiguration"
        )
      );
      caBundles = builtins.filter (w: w.clientConfig ? caBundle) (
        entries "MutatingWebhookConfiguration" ++ entries "ValidatingWebhookConfiguration"
      );
    in
    (
      names "MutatingWebhookConfiguration" == [
        "mbackup.cnpg.io"
        "mcluster.cnpg.io"
        "mdatabase.cnpg.io"
        "mscheduledbackup.cnpg.io"
      ]
      &&
        names "ValidatingWebhookConfiguration" == [
          "vbackup.cnpg.io"
          "vcluster.cnpg.io"
          "vdatabase.cnpg.io"
          "vpooler.cnpg.io"
          "vscheduledbackup.cnpg.io"
        ]
      && services == [ "cnpg-webhook-service" ]
      && caBundles == [ ]
    )
    || throw "webhook entries: ${
      builtins.toJSON {
        mutating = names "MutatingWebhookConfiguration";
        validating = names "ValidatingWebhookConfiguration";
        inherit services;
      }
    }";

  # An operator image of another minor than the vendored definitions is
  # refused; the default image is not.
  cnpg-operator-image-minor =
    let
      got = failedMessages {
        package = operatorPackage;
        instanceName = "cnpg-operator";
        config.image.tag = "1.29.3";
      };
      fine = failedMessages {
        package = operatorPackage;
        instanceName = "cnpg-operator";
        config.image.tag = "1.30.0";
      };
    in
    (says ''image.tag "1.29.3" is not a CloudNativePG 1.30 release'' got && fine == [ ])
    || throw "cnpg-operator image refusal: ${builtins.toJSON { inherit got fine; }}";

  # Operator variables the package owns or refuses fail the build; another
  # variable passes.
  cnpg-operator-env-refusals =
    let
      withEnv =
        env:
        cnpg {
          operatorConfig = { inherit env; };
          database = null;
        };
    in
    (
      evalFails (withEnv {
        WATCH_NAMESPACE = "data";
      })
      && evalFails (withEnv {
        INHERITED_ANNOTATIONS = "kix.run/*";
      })
      && evalFails (withEnv {
        MANAGE_WEBHOOK_CONFIGURATIONS = "false";
      })
      && evalFails (withEnv {
        KUBERNETES_CLUSTER_DOMAIN = "example.org";
      })
      && !evalFails (withEnv {
        INSTANCES_ROLLOUT_DELAY = "30";
      })
    )
    || throw "cnpg-operator env refusals: one did not fail, or the control failed";

  # The vendored definitions and ClusterRole come from the package's
  # release.
  cnpg-operator-sources-match-release =
    let
      urls =
        file:
        builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
          map (l: builtins.head (lib.splitString " " (lib.trim l))) (
            lib.splitString "\n" (builtins.readFile file)
          )
        );
      release =
        (operatorPackage {
          scope = {
            instanceName = "cnpg-operator";
            namespaceName = "cnpg-system";
          };
          inherit lib;
          kix = kixlib;
          availability = "none";
        }).meta.version;
      dir = ../../../packages/cnpg-operator;
      stray = builtins.filter (u: !(lib.hasInfix "/v${release}/" u)) (
        urls (dir + "/crds/sources.txt") ++ urls (dir + "/rbac/sources.txt")
      );
    in
    stray == [ ] || throw "sources.txt URLs not at ${release}: ${builtins.toJSON stray}";

  # The rendered Cluster: the image, the volumes, no anti-affinity of the
  # operator's, and no PodDisruptionBudgets for a single instance.
  cnpg-cluster-spec =
    let
      one = clusterSpec (cnpg {
        database = null;
        extra = singleNode;
      });
      two = clusterSpec (cnpg {
        database = null;
        clusterConfig.instances = 2;
      });
    in
    (
      lib.hasPrefix "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:" one.imageName
      && one.instances == 1
      && one.storage.size == "20Gi"
      && one.affinity.enablePodAntiAffinity == false
      && one.enablePDB == false
      && !(one ? topologySpreadConstraints)
      && two.enablePDB == true
      &&
        (builtins.head two.topologySpreadConstraints).labelSelector.matchLabels == {
          "cnpg.io/cluster" = "postgres";
          "cnpg.io/podRole" = "instance";
        }
    )
    || throw "Cluster spec: ${builtins.toJSON { inherit one two; }}";

  # cnpg-cluster's assertions, one message each, and none for the defaults.
  cnpg-cluster-refusals =
    let
      longName = "a" + lib.concatStrings (lib.replicate 50 "b");
      named = failedMessages {
        package = clusterPackage;
        instanceName = longName;
      };
      latest = failedMessages {
        package = clusterPackage;
        instanceName = "postgres";
        config.image.tag = "latest";
      };
      podMonitor = failedMessages {
        package = clusterPackage;
        instanceName = "postgres";
        config.extraSpec.monitoring.enablePodMonitor = true;
      };
      fine = failedMessages {
        package = clusterPackage;
        instanceName = "postgres";
        config.extraSpec.postgresql.parameters.max_connections = "50";
      };
    in
    (
      says "CloudNativePG requires a Cluster name of at most 50 characters" named
      && says ''image.tag "latest" does not start with a PostgreSQL version'' latest
      && says "extraSpec sets monitoring.enablePodMonitor" podMonitor
      && fine == [ ]
    )
    || throw "cnpg-cluster refusals: ${
      builtins.toJSON {
        inherit
          named
          latest
          podMonitor
          fine
          ;
      }
    }";

  # extraSpec cannot set a path the package sets; another path passes.
  cnpg-cluster-extra-spec-locks =
    (
      evalFails (cnpg {
        database = null;
        clusterConfig.extraSpec.instances = 3;
      })
      && evalFails (cnpg {
        database = null;
        clusterConfig.extraSpec.affinity.enablePodAntiAffinity = true;
      })
      && evalFails (cnpg {
        database = null;
        clusterConfig.extraSpec.imageCatalogRef.name = "catalog";
      })
      && !evalFails (cnpg {
        database = null;
        clusterConfig.extraSpec.affinity.nodeSelector."example.com/db" = "true";
      })
    )
    || throw "cnpg-cluster extraSpec locks: a locked path passed, or the control failed";

  # The role, its basic-auth password Secret, and the Database live in the
  # cluster's namespace; the role owns the database; the extensions reach
  # the Database.
  cnpg-database-resources =
    let
      all = ms (cnpg {
        database = {
          password = "password";
          user = "app_user";
          extensions = [
            "citext"
            {
              name = "vector";
              version = "0.8.0";
            }
          ];
        };
      });
      role = byName "data-app-db" (ofKind "DatabaseRole" all);
      database = byName "data-app-db" (ofKind "Database" all);
      secret = byName role.spec.passwordSecret.name (ofKind "Secret" all);
      credentials = byName "app-db-credentials" (ofKind "Secret" all);
    in
    (
      role.spec == {
        cluster.name = "postgres";
        name = "app_user";
        login = true;
        passwordSecret.name = "data-app-db-role";
      }
      &&
        database.spec == {
          cluster.name = "postgres";
          name = "app-db";
          owner = "app_user";
          extensions = [
            {
              name = "citext";
              ensure = "present";
            }
            {
              name = "vector";
              version = "0.8.0";
              ensure = "present";
            }
          ];
        }
      && secret.type == "kubernetes.io/basic-auth"
      && secret.stringData.username == "app_user"
      && credentials.metadata.namespace == "data"
      && credentials.stringData.host == "postgres-rw.data.svc.cluster.local"
    )
    || throw "cnpg-database resources: ${builtins.toJSON { inherit role database secret; }}";

  # The password checks of stackgres-database, and the reserved role names.
  cnpg-database-refusals =
    let
      reserved = failedMessages {
        package = databasePackage;
        instanceName = "app-db";
        config.user = "pg_app";
      };
      fine = failedMessages {
        package = databasePackage;
        instanceName = "app-db";
        config.user = "app";
      };
    in
    (
      says ''user "pg_app" is reserved by CloudNativePG'' reserved
      && fine == [ ]
      && evalFails (cnpg {
        database = { };
      })
      && evalFails (cnpg {
        database = {
          password = "password";
          passwordSource = ./cnpg.nix;
          passwordHash = "hash";
        };
      })
      && evalFails (cnpg {
        database.passwordSource = ./cnpg.nix;
      })
      && !evalFails (cnpg {
        database = {
          passwordSource = ./cnpg.nix;
          passwordHash = "hash";
        };
      })
    )
    || throw "cnpg-database refusals: ${builtins.toJSON { inherit reserved fine; }}";

  # A cnpg-database on a stackgres-cluster is refused; the same database on
  # a cnpg-cluster (cnpg-database-resources) evaluates.
  cnpg-database-refuses-other-postgres = evalFails (mkCluster [
    {
      instances.cnpg-system.cnpg-operator.package = operatorPackage;
      instances.stackgres-system.stackgres-operator.package = stackgresOperatorPackage;
      instances.data = {
        postgres.package = stackgresClusterPackage;
        app-db = {
          package = databasePackage;
          config.password = "password";
        };
      };
    }
  ]);
}

# Tests for the CloudNativePG packages: the refusals of cnpg-operator,
# cnpg-cluster, cnpg-database, cnpg-barman-cloud, and cnpg-pooler, each
# beside a positive control, the rendered Cluster, Database, DatabaseRole,
# backups, and Pooler, the webhook check that every postgresql.cnpg.io
# custom resource waits for, the vendored sources' release, and the alert
# rules of cnpg-operator and cnpg-cluster and what each is gated on, and
# cnpg-database's refusal of the removed password options and its two
# routes for the `password` dependency.

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
  netpolOn,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  operatorPackage = import ../../../packages/stable/cnpg-operator;
  clusterPackage = import ../../../packages/stable/cnpg-cluster;
  databasePackage = import ../../../packages/experimental/cnpg-database;
  stackgresOperatorPackage = import ../../../packages/experimental/stackgres-operator;
  stackgresClusterPackage = import ../../../packages/experimental/stackgres-cluster;
  barmanPackage = import ../../../packages/experimental/cnpg-barman-cloud;
  poolerPackage = import ../../../packages/experimental/cnpg-pooler;
  certManagerPackage = import ../../../packages/experimental/cert-manager;
  ciliumPackage = import ../../../packages/experimental/cilium;
  secretPackage = import ../../../packages/stable/secret;
  secretRefPackage = import ../../../packages/stable/secret-ref;
  serviceRefPackage = import ../../../packages/experimental/service-ref;

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

  # The password secret of a cnpg-database: a packages.secret with a SOPS
  # source.
  sopsPassword = {
    package = secretPackage;
    config = {
      source = ./cnpg.nix;
      hash = "hash";
      keys = [ "password" ];
    };
  };

  # The operator, a cluster `postgres`, and, unless `database` is null, a
  # cnpg-database `app-db` beside it, with `password` as its password
  # dependency `app-db-password` unless that is null.
  cnpg =
    {
      operatorConfig ? { },
      clusterConfig ? { },
      database ? { },
      password ? sopsPassword,
      extra ? { },
    }:
    mkCluster [
      (
        { ref, ... }:
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
            }
            // lib.optionalAttrs (password != null) {
              deps.password = ref.data.app-db-password;
            };
          }
          // lib.optionalAttrs (database != null && password != null) {
            app-db-password = password;
          };
        }
      )
      extra
    ];
  ms = cluster: manifests cluster;
  clusterSpec = cluster: (byName "postgres" (ofKind "Cluster" (ms cluster))).spec;
  dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
  hashOf = r: builtins.unsafeDiscardStringContext r.out.identityHash;

  # The operator and a cluster `postgres` that imports from `old-db`, a
  # service-ref in `legacy` for a Service Kix does not manage, with the
  # password in the secret `old-db-password`. `deps` replaces the wiring,
  # `extra` adds instances to `data`, and `modules` are added to the
  # cluster.
  imported =
    {
      importConfig ? {
        databases = [ "registry" ];
        user = "postgres";
        sslMode = "require";
      },
      extraSpec ? {
        bootstrap.initdb = {
          database = "registry";
          owner = "harbor";
        };
      },
      deps ? ref: {
        importSource = ref.legacy.old-db;
        importPassword = ref.data.old-db-password;
      },
      extra ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        (
          { ref, ... }:
          {
            instances.cnpg-system.cnpg-operator.package = operatorPackage;
            instances.legacy.old-db = {
              package = serviceRefPackage;
              config = {
                selector."app.example.com/cluster" = "old-db";
                ports = [
                  {
                    port = 5433;
                    targetPort = 5432;
                  }
                ];
              };
            };
            instances.data = {
              old-db-password = {
                package = secretPackage;
                config.stringData.password = "password";
              };
              postgres = {
                package = clusterPackage;
                deps = deps ref;
                config = {
                  import = importConfig;
                  inherit extraSpec;
                };
              };
            }
            // extra;
          }
        )
      ]
      ++ modules
    );

  # The operator, cert-manager, the plugin, S3 credentials, and a cluster
  # `postgres` with `backup` set. `modules` are added to the cluster.
  backups =
    {
      backup ? {
        destinationPath = "s3://backups/pg";
      },
      plugin ? true,
      pluginNamespace ? "cnpg-system",
      pluginConfig ? { },
      credentials ? {
        accessKeyId = "id";
        secretAccessKey = "key";
      },
      clusterExtraSpec ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.cnpg-system.cnpg-operator.package = operatorPackage;
          instances.cert-manager.cert-manager.package = certManagerPackage;
          instances.data = {
            postgres = {
              package = clusterPackage;
              config = {
                inherit backup;
                extraSpec = clusterExtraSpec;
              };
            };
          }
          // lib.optionalAttrs (credentials != null) {
            s3-credentials = {
              package = secretPackage;
              aliases = [ "storageCredentials" ];
              config.stringData = credentials;
            };
          };
        }
      ]
      ++ lib.optional plugin {
        instances.${pluginNamespace}.cnpg-barman-cloud = {
          package = barmanPackage;
          config = pluginConfig;
        };
      }
      ++ modules
    );

  # A cluster `postgres`, a cnpg-pooler `pooler` in front of it, and a
  # cnpg-database `app-db` on the pooler.
  pooled =
    {
      poolerConfig ? { },
      poolerNamespace ? "data",
      postgres ? clusterPackage,
      modules ? [ ],
    }:
    mkCluster (
      [
        (
          { ref, ... }:
          {
            instances.cnpg-system.cnpg-operator.package = operatorPackage;
            instances.stackgres-system = lib.optionalAttrs (postgres == stackgresClusterPackage) {
              stackgres-operator.package = stackgresOperatorPackage;
            };
            instances.data = {
              postgres.package = postgres;
              app-db = {
                package = databasePackage;
                deps.postgres = ref.${poolerNamespace}.pooler;
                deps.password = ref.data.app-db-password;
              };
              app-db-password = sopsPassword;
            };
          }
        )
        (
          { ref, ... }:
          {
            instances.${poolerNamespace}.pooler = {
              package = poolerPackage;
              deps.postgres = ref.data.postgres;
              config = poolerConfig;
            };
          }
        )
      ]
      ++ modules
    );
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
        INHERITED_ANNOTATIONS = "example.com/*";
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
      dir = ../../../packages/stable/cnpg-operator;
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

  # The operator requests 100m CPU and may burst to one core.
  cnpg-operator-cpu-bursts =
    let
      container =
        builtins.head
          (byName "cnpg-operator" (
            ofKind "Deployment" (
              ms (cnpg {
                database = null;
              })
            )
          )).spec.template.spec.containers;
    in
    (container.resources.requests.cpu == "100m" && container.resources.limits.cpu == "1")
    || throw "cnpg-operator resources: ${builtins.toJSON container.resources}";

  # At `node`, two or more instances get required anti-affinity on the
  # instance labels per host, which CloudNativePG also gives its join job.
  # One instance, and the `pod` and `zone` levels, get none.
  cnpg-cluster-node-level-separates-instances =
    let
      at =
        level: instances:
        (clusterSpec (cnpg {
          database = null;
          clusterConfig.instances = instances;
          extra = {
            cluster.capabilities.multiNode = true;
            cluster.capabilities.availabilityZones = [
              "a"
              "b"
            ];
            instances.data.postgres.availability = level;
          };
        })).affinity;
      node = at "node" 3;
      required = node.additionalPodAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution or [ ];
      none = a: !(a ? additionalPodAntiAffinity);
    in
    (
      node.enablePodAntiAffinity == false
      &&
        required == [
          {
            labelSelector.matchLabels = {
              "cnpg.io/cluster" = "postgres";
              "cnpg.io/podRole" = "instance";
            };
            topologyKey = "kubernetes.io/hostname";
          }
        ]
      && none (at "node" 1)
      && none (at "pod" 3)
      && none (at "zone" 3)
    )
    || throw "cnpg-cluster node-level anti-affinity: ${
      builtins.toJSON {
        inherit node;
        one = at "node" 1;
        pod = at "pod" 3;
        zone = at "zone" 3;
      }
    }";

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
  # The record carries the PostgreSQL major from the image tag. A tag
  # without one fails the build through the assertion on the tag, which
  # tryEval catches; a type error from reading the major out of such a tag
  # would abort the whole test run instead.
  cnpg-cluster-reports-postgres-major =
    let
      record = byName "postgres" (
        ofKind "PackageInstance" (
          ms (cnpg {
            database = null;
          })
        )
      );
      latest = cnpg {
        database = null;
        clusterConfig.image.tag = "latest";
      };
    in
    ((record.spec.version or null) == "18" && evalFails latest)
    || throw "record version: ${builtins.toJSON (record.spec.version or null)}";

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

  # The removed `password`, `passwordSource`, and `passwordHash` options
  # fail the build, and so does a database with no `password` dependency.
  # A packages.secret with a SOPS source fills both Secrets from that file
  # at deploy.
  cnpg-database-password-refused =
    let
      secretIn = name: byName name (ofKind "Secret" (ms (cnpg { })));
      fromSops =
        name:
        let
          secret = secretIn name;
        in
        secret.metadata.annotations ? ${kixKeys.sopsSource} && !(secret.stringData or { } ? password);
    in
    (
      evalFails (cnpg {
        database.password = "pw";
      })
      && evalFails (cnpg {
        database = {
          passwordSource = ./cnpg.nix;
          passwordHash = "hash";
        };
      })
      && evalFails (cnpg {
        password = null;
      })
      && fromSops "app-db-credentials"
      && fromSops "data-app-db-role"
    )
    || throw "cnpg-database password: ${builtins.toJSON (secretIn "app-db-credentials")}";

  # A password from a secret-ref holding `username` and `password` is the
  # credentials Secret. The package renders no Secret of its own, and the
  # role reads its password from the basic-auth Secret
  # `<namespace>-<instance>-role` in the cluster's namespace, which the site
  # writes. A secret-ref without `username` fails.
  cnpg-database-password-secret-ref =
    let
      withRef =
        keys:
        cnpg {
          password = {
            package = secretRefPackage;
            config = { inherit keys; };
          };
        };
      cluster = withRef [
        "username"
        "password"
      ];
      all = ms cluster;
      secrets = map (m: m.metadata.name) (
        builtins.filter (m: m.metadata.namespace == "data") (ofKind "Secret" all)
      );
      imported = builtins.filter (
        m: (m.metadata.annotations or { }).${kixKeys.importKind} or null == "Secret"
      ) (ofKind "PackageInstance" all);
      roleSecret = lib.findFirst (
        m: m.metadata.annotations.${kixKeys.importName} == "data-app-db-role"
      ) null imported;
      role = byName "data-app-db" (ofKind "DatabaseRole" all);
      credentialsName = builtins.unsafeDiscardStringContext cluster.instances.data.app-db.raw.root.out.credentials.out.name;
    in
    (
      role.spec.passwordSecret.name == "data-app-db-role"
      && roleSecret != null
      && roleSecret.metadata.annotations.${kixKeys.secretType} == "kubernetes.io/basic-auth"
      && roleSecret.metadata.annotations.${kixKeys.importSecretKeys} == "username,password"
      && credentialsName == "app-db-password"
      && !(builtins.elem "app-db-credentials" secrets)
      && !(builtins.elem "data-app-db-role" secrets)
      && evalFails (withRef [ "password" ])
    )
    || throw "cnpg-database secret-ref password: ${
      builtins.toJSON {
        inherit secrets credentialsName;
        roleSecret = if roleSecret == null then null else roleSecret.metadata.annotations;
      }
    }";

  # A name listed twice, as when a consumer's deps.database.config.extensions
  # repeats one of the instance's, renders once, keeping the one version
  # given; two different versions of one name fail evaluation.
  cnpg-database-extensions-merge =
    let
      databaseWith =
        extensions:
        byName "data-app-db" (
          ofKind "Database" (
            ms (cnpg {
              database = {
                inherit extensions;
              };
            })
          )
        );
      merged = databaseWith [
        "citext"
        "citext"
        {
          name = "vector";
          version = "0.8.0";
        }
        "vector"
      ];
    in
    (
      merged.spec.extensions == [
        {
          name = "citext";
          ensure = "present";
        }
        {
          name = "vector";
          version = "0.8.0";
          ensure = "present";
        }
      ]
      && evalFails (cnpg {
        database = {
          extensions = [
            {
              name = "vector";
              version = "0.8.0";
            }
            {
              name = "vector";
              version = "0.7.4";
            }
          ];
        };
      })
    )
    || throw "cnpg-database extensions merge: ${builtins.toJSON merged.spec}";

  # The password checks of cnpg-database, and the reserved role and
  # database names.
  cnpg-database-refusals =
    let
      reserved = failedMessages {
        package = databasePackage;
        instanceName = "app-db";
        config.user = "pg_app";
      };
      reservedDatabase = failedMessages {
        package = databasePackage;
        instanceName = "app-db";
        config.database = "template1";
      };
      # The database defaults to the instance name.
      reservedByName = failedMessages {
        package = databasePackage;
        instanceName = "postgres";
        config.user = "app";
      };
      fine = failedMessages {
        package = databasePackage;
        instanceName = "app-db";
        config.user = "app";
      };
    in
    (
      says ''user "pg_app" is reserved by CloudNativePG'' reserved
      && says ''database "template1" is reserved by PostgreSQL'' reservedDatabase
      && says ''database "postgres" is reserved by PostgreSQL'' reservedByName
      && fine == [ ]
      && evalFails (cnpg {
        password = null;
      })
      && evalFails (cnpg {
        database.password = "password";
      })
      && evalFails (cnpg {
        database.passwordSource = ./cnpg.nix;
      })
      && !evalFails (cnpg { })
    )
    || throw "cnpg-database refusals: ${
      builtins.toJSON {
        inherit
          reserved
          reservedDatabase
          reservedByName
          fine
          ;
      }
    }";

  # A cnpg-database on a stackgres-cluster is refused; the same database on
  # a cnpg-cluster (cnpg-database-resources) evaluates.
  cnpg-database-refuses-other-postgres = evalFails (mkCluster [
    (
      { ref, ... }:
      {
        instances.cnpg-system.cnpg-operator.package = operatorPackage;
        instances.stackgres-system.stackgres-operator.package = stackgresOperatorPackage;
        instances.data = {
          postgres.package = stackgresClusterPackage;
          app-db = {
            package = databasePackage;
            deps.password = ref.data.app-db-password;
          };
          app-db-password = sopsPassword;
        };
      }
    )
  ]);

  # With `backup` set: the Cluster enables the plugin as its WAL archiver
  # and names the ObjectStore, the ObjectStore takes its credentials from
  # the storageCredentials Secret, the ScheduledBackup uses the plugin, the
  # Cluster waits for the plugin Deployment, and the ScheduledBackup for the
  # operator's webhook check. A world egress policy selects the instance
  # pods (the test enforcer renders no intent rules, so the port is not
  # visible here).
  cnpg-cluster-backup-resources =
    let
      cluster = backups {
        backup = {
          destinationPath = "s3://backups/pg";
          schedule = "@daily";
          retention = "30d";
          credentialKeys.region = "region";
          extraSpec.configuration.endpointURL = "https://s3.example.com:9000";
        };
        credentials = {
          accessKeyId = "id";
          secretAccessKey = "key";
          region = "eu-west-1";
        };
        modules = [ netpolOn ];
      };
      all = ms cluster;
      spec = clusterSpec cluster;
      store = byName "postgres-backup" (ofKind "ObjectStore" all);
      scheduled = byName "postgres" (ofKind "ScheduledBackup" all);
      egress = byName "postgres-backup-egress" (ofKind "CiliumNetworkPolicy" all);
      pluginHash = hashOf cluster.instances.cnpg-system.cnpg-barman-cloud.raw.deployment;
      checkHash = hashOf cluster.instances.cnpg-system.cnpg-operator.raw.webhookCheck;
      postgres = byName "postgres" (ofKind "Cluster" all);
    in
    (
      spec.plugins == [
        {
          name = "barman-cloud.cloudnative-pg.io";
          isWALArchiver = true;
          parameters = {
            barmanObjectName = "postgres-backup";
            serverName = "data-postgres";
          };
        }
      ]
      &&
        store.spec == {
          configuration = {
            destinationPath = "s3://backups/pg";
            endpointURL = "https://s3.example.com:9000";
            s3Credentials = {
              accessKeyId = {
                name = "s3-credentials";
                key = "accessKeyId";
              };
              secretAccessKey = {
                name = "s3-credentials";
                key = "secretAccessKey";
              };
              region = {
                name = "s3-credentials";
                key = "region";
              };
            };
          };
          retentionPolicy = "30d";
        }
      &&
        scheduled.spec == {
          cluster.name = "postgres";
          schedule = "@daily";
          method = "plugin";
          pluginConfiguration.name = "barman-cloud.cloudnative-pg.io";
          backupOwnerReference = "self";
          immediate = true;
        }
      && lib.hasInfix pluginHash (dependsOn postgres)
      && lib.hasInfix checkHash (dependsOn scheduled)
      &&
        egress.spec.endpointSelector.matchLabels == {
          "cnpg.io/cluster" = "postgres";
          "cnpg.io/podRole" = "instance";
        }
      && builtins.any (
        r: (r.stubRule or null) == "intent-egress" && r.to == "world" && map (p: p.port) r.ports == [ 9000 ]
      ) egress.spec.egress
    )
    || throw "backup resources: ${
      builtins.toJSON {
        inherit (spec) plugins;
        store = store.spec or null;
        scheduled = scheduled.spec or null;
        egress = egress.spec or null;
      }
    }";

  # Without `backup` the Cluster has no plugin entry and the package builds
  # no ObjectStore or ScheduledBackup, even with the plugin and a
  # storageCredentials Secret in the cluster; `extraSpec.plugins` then
  # passes through.
  cnpg-cluster-backup-off =
    let
      all = ms (backups {
        backup = null;
        clusterExtraSpec.plugins = [ { name = "example.com"; } ];
      });
    in
    (
      (clusterSpec (backups {
        backup = null;
      })) ? plugins == false
      && ofKind "ObjectStore" all == [ ]
      && ofKind "ScheduledBackup" all == [ ]
      && (byName "postgres" (ofKind "Cluster" all)).spec.plugins == [ { name = "example.com"; } ]
    )
    || throw "backup off: an ObjectStore, ScheduledBackup, or plugin entry was rendered";

  # `backup` without the plugin, without the credentials, or with a
  # credentials Secret that lacks a key is refused; the same cluster with
  # all three evaluates.
  cnpg-cluster-backup-needs-deps =
    (
      evalFails (backups {
        plugin = false;
      })
      && evalFails (backups {
        credentials = null;
      })
      && evalFails (backups {
        credentials.accessKeyId = "id";
      })
      && evalFails (backups {
        backup = {
          destinationPath = "s3://backups/pg";
          credentialKeys.region = "region";
        };
      })
      && !evalFails (backups { })
    )
    || throw "backup dependencies: a missing dependency or key passed, or the control failed";

  # backup.extraSpec cannot set the paths the package writes, and the
  # Cluster's extraSpec cannot set `plugins` or `backup.barmanObjectStore`
  # while backups are on; other paths, and barmanObjectStore without
  # `backup`, pass.
  cnpg-cluster-backup-extra-spec-locks =
    let
      withExtra =
        extraSpec:
        backups {
          backup = {
            destinationPath = "s3://backups/pg";
            inherit extraSpec;
          };
        };
    in
    (
      evalFails (withExtra {
        configuration.destinationPath = "s3://other";
      })
      && evalFails (withExtra {
        configuration.s3Credentials.inheritFromIAMRole = true;
      })
      && evalFails (withExtra {
        retentionPolicy = "7d";
      })
      && evalFails (backups {
        clusterExtraSpec.plugins = [ ];
      })
      && evalFails (backups {
        clusterExtraSpec.backup.barmanObjectStore.destinationPath = "s3://other";
      })
      && !evalFails (backups {
        backup = null;
        clusterExtraSpec.backup.barmanObjectStore.destinationPath = "s3://other";
      })
      && !evalFails (backups {
        clusterExtraSpec.backup.target = "primary";
      })
      && !evalFails (withExtra {
        configuration.wal.compression = "gzip";
        instanceSidecarConfiguration.logLevel = "debug";
      })
    )
    || throw "backup extraSpec locks: a locked path passed, or the control failed";

  # With an in-cluster store as endpointService, the ObjectStore's
  # endpointURL is the store's Service, with the scheme from
  # backup.endpointScheme, which the instance pods get egress to, and
  # backup.extraSpec may not set another endpoint. A store outside the
  # cluster opens no in-cluster path. Without endpointService, an
  # endpointURL naming a Service in the cluster, with or without the cluster
  # domain, is refused, and so is endpointScheme.
  cnpg-cluster-backup-endpoint-service =
    let
      # An S3 store whose root is its Service, listening on TCP 7070.
      storePackage =
        { scope, kix, ... }:
        {
          meta = {
            description = "S3 store stand-in";
            owner = "platform";
          };
          build =
            { self, ... }:
            {
              deployment = scope.mkDeployment {
                name = "s3";
                availability.max = "none";
                spec = {
                  replicas = 1;
                  selector.matchLabels = scope.selectorLabels;
                  template.spec.containers = [
                    {
                      name = "s3";
                      image = "example.com/s3:1";
                      ports = [ (kix.port "s3" 7070) ];
                    }
                  ];
                };
              };
              service = self.deployment |> kix.service.fromWorkload { name = "s3"; } |> scope.mkResource;
              root = self.service;
            };
        };
      withStore =
        backup:
        backups {
          inherit backup;
          modules = [
            netpolOn
            (
              { ref, ... }:
              {
                instances.data = {
                  s3.package = storePackage;
                  postgres.deps.endpointService = ref.data.s3;
                };
              }
            )
          ];
        };
      all = ms (withStore {
        destinationPath = "s3://backups/pg";
      });
      store = byName "postgres-backup" (ofKind "ObjectStore" all);
      storeUrl = store.spec.configuration.endpointURL;
      httpsUrl =
        (byName "postgres-backup" (
          ofKind "ObjectStore" (
            ms (withStore {
              destinationPath = "s3://backups/pg";
              endpointScheme = "https";
            })
          )
        )).spec.configuration.endpointURL;
      # The store's address as a literal endpointURL, without endpointService.
      literal =
        url:
        backups {
          backup = {
            destinationPath = "s3://backups/pg";
            extraSpec.configuration.endpointURL = url;
          };
        };
      policies = ofKind "CiliumNetworkPolicy" all;
      toStore = builtins.filter (
        p:
        (p.spec.endpointSelector.matchLabels or { }) == {
          "cnpg.io/cluster" = "postgres";
        }
        && lib.hasInfix "7070" (builtins.toJSON p.spec)
      ) policies;
    in
    (
      lib.hasPrefix "http://s3.data.svc." storeUrl
      && httpsUrl == "https://${lib.removePrefix "http://" storeUrl}"
      && toStore != [ ]
      && byName "postgres-backup-egress" policies == null
      && evalFails (withStore {
        destinationPath = "s3://backups/pg";
        extraSpec.configuration.endpointURL = "https://s3.example.com";
      })
      && evalFails (literal storeUrl)
      && evalFails (literal "http://s3.data.svc:7070")
      && evalFails (literal "http://S3.data.svc.:7070/bucket")
      && !evalFails (literal "http://s3.data.example.com:7070")
      && evalFails (backups {
        backup = {
          destinationPath = "s3://backups/pg";
          endpointScheme = "https";
        };
      })
    )
    || throw "endpointService: ${
      builtins.toJSON {
        endpoint = store.spec.configuration.endpointURL or null;
        policies = map (p: p.metadata.name) policies;
      }
    }";

  # The schedule, destination, and retention checks: a five-field crontab,
  # a descriptor robfig/cron does not know, a destination that is not an
  # s3:// URL, a malformed retention, and an endpoint that is not a URL are
  # refused; six fields and the known descriptors pass.
  cnpg-cluster-backup-refusals =
    let
      scheduleMessages =
        schedule:
        failedMessages {
          package = clusterPackage;
          instanceName = "postgres";
          config.backup = {
            destinationPath = "s3://backups/pg";
            inherit schedule;
          };
        };
      fiveFields = scheduleMessages "0 2 * * *";
      sixFields = scheduleMessages "0 0 2 * * *";
      descriptor = scheduleMessages "@every 12h";
      everyMixed = scheduleMessages "@every 1h30m";
      daily = scheduleMessages "@midnight";
      reboot = scheduleMessages "@reboot";
      everyBad = scheduleMessages "@every day";
      withBackup =
        backup:
        backups {
          backup = {
            destinationPath = "s3://backups/pg";
          }
          // backup;
        };
    in
    (
      says ''backup.schedule "0 2 * * *" has 5 fields'' fiveFields
      && sixFields == [ ]
      && descriptor == [ ]
      && everyMixed == [ ]
      && daily == [ ]
      && says ''backup.schedule "@reboot" is not a descriptor'' reboot
      && says ''backup.schedule "@every day" is not a descriptor'' everyBad
      && evalFails (withBackup {
        destinationPath = "gs://backups/pg";
      })
      && evalFails (withBackup {
        retention = "30 days";
      })
      && evalFails (withBackup {
        extraSpec.configuration.endpointURL = "s3.example.com";
      })
      && !evalFails (withBackup {
        retention = "4w";
      })
    )
    || throw "backup refusals: ${
      builtins.toJSON {
        inherit
          fiveFields
          sixFields
          descriptor
          everyMixed
          daily
          reboot
          everyBad
          ;
      }
    }";

  # The plugin's serverName defaults to <namespace>-<instance>, so
  # same-named instances in two namespaces archive to different folders;
  # backup.serverName replaces it, and a name with a slash is refused.
  cnpg-cluster-backup-server-name =
    let
      serverNameOf =
        backup:
        (builtins.head
          (clusterSpec (backups {
            backup = {
              destinationPath = "s3://backups/pg";
            }
            // backup;
          })).plugins
        ).parameters.serverName;
      default = serverNameOf { };
      set = serverNameOf { serverName = "postgres"; };
    in
    (
      default == "data-postgres"
      && set == "postgres"
      && evalFails (backups {
        backup = {
          destinationPath = "s3://backups/pg";
          serverName = "a/b";
        };
      })
    )
    || throw "backup serverName: ${builtins.toJSON { inherit default set; }}";

  # Under Cilium, the world egress rule for a store outside the cluster
  # opens the endpointURL's port, or 443 without an endpointURL, to the
  # instance pods.
  cnpg-cluster-backup-world-egress-port =
    let
      egressOf =
        backup:
        let
          all = ms (backups {
            backup = {
              destinationPath = "s3://backups/pg";
            }
            // backup;
            modules = [
              {
                cluster.roles.cni = {
                  binding = "shadowable";
                  provider = "cilium (environment)";
                };
                networkPolicy.enable = true;
                instances.net.cilium.package = ciliumPackage;
                instances.net.platform-cilium.package = eval.mkImport {
                  roles = [ "cni" ];
                  out.helmChartConfig = null;
                };
              }
            ];
          });
        in
        (byName "postgres-backup-egress" (ofKind "CiliumNetworkPolicy" all)).spec.egress;
      explicit = egressOf { extraSpec.configuration.endpointURL = "https://s3.example.com:9000/x"; };
      byScheme = egressOf { extraSpec.configuration.endpointURL = "http://s3.example.com"; };
      aws = egressOf { };
      rule = port: [
        {
          toEntities = [ "world" ];
          toPorts = [
            {
              ports = [
                {
                  inherit port;
                  protocol = "TCP";
                }
              ];
            }
          ];
        }
      ];
    in
    (explicit == rule "9000" && byScheme == rule "80" && aws == rule "443")
    || throw "backup world egress: ${builtins.toJSON { inherit explicit byScheme aws; }}";

  # mkObjectStore refuses a Secret selector named by a literal string and
  # accepts one marked with kix.untrackedRef.
  cnpg-barman-cloud-object-store-literal-secret =
    let
      withCA =
        name:
        backups {
          backup = {
            destinationPath = "s3://backups/pg";
            extraSpec.configuration.endpointCA = {
              inherit name;
              key = "ca.crt";
            };
          };
        };
    in
    (
      evalFails (withCA "store-ca")
      && !evalFails (
        withCA (
          kixlib.untrackedRef {
            name = "store-ca";
            kind = "Secret";
          }
        )
      )
    )
    || throw "mkObjectStore: the literal Secret name passed, or the untracked one failed";

  # The plugin must run in the operator's namespace.
  cnpg-barman-cloud-operator-namespace =
    (
      evalFails (backups {
        pluginNamespace = "backup-system";
      })
      && !evalFails (backups { })
    )
    || throw "cnpg-barman-cloud namespace: another namespace passed, or the control failed";

  # The plugin's Service carries the label and annotations the operator
  # discovers it by, and the server certificate names that Service.
  cnpg-barman-cloud-registration =
    let
      all = ms (backups { });
      service = byName "cnpg-barman-cloud" (ofKind "Service" all);
      certificate = byName "cnpg-barman-cloud-server" (ofKind "Certificate" all);
      deployment = byName "cnpg-barman-cloud" (ofKind "Deployment" all);
      secretNames = map (v: v.secret.secretName) deployment.spec.template.spec.volumes;
    in
    (
      service.metadata.labels."cnpg.io/pluginName" == "barman-cloud.cloudnative-pg.io"
      && service.metadata.annotations."cnpg.io/pluginPort" == "9090"
      && service.metadata.annotations."cnpg.io/pluginServerSecret" == certificate.spec.secretName
      && builtins.elem service.metadata.annotations."cnpg.io/pluginClientSecret" secretNames
      && certificate.spec.dnsNames == [ service.metadata.name ]
      && deployment.spec.strategy.type == "Recreate"
    )
    || throw "plugin registration: ${
      builtins.toJSON {
        service = service.metadata;
        certificate = certificate.spec;
      }
    }";

  # The plugin's refusals: an image or sidecar tag of another minor, a flag
  # the package sets, and SIDECAR_IMAGE in env; the defaults, another flag,
  # and another variable pass.
  cnpg-barman-cloud-refusals =
    let
      messages =
        config:
        failedMessages {
          package = barmanPackage;
          instanceName = "cnpg-barman-cloud";
          namespaceName = "cnpg-system";
          inherit config;
        };
      oldImage = messages { image.tag = "v0.14.0"; };
      oldSidecar = messages { sidecar.image.tag = "v0.14.0"; };
      fine = messages { image.tag = "v0.15.0"; };
    in
    (
      says ''image.tag "v0.14.0" is not a plugin-barman-cloud 0.15 release'' oldImage
      && says ''sidecar.image.tag "v0.14.0" is not a plugin-barman-cloud 0.15 release'' oldSidecar
      && fine == [ ]
      && evalFails (backups {
        pluginConfig.extraArgs = [ "--server-address=:9091" ];
      })
      && evalFails (backups {
        pluginConfig.env.SIDECAR_IMAGE = "example.com/sidecar:1";
      })
      && !evalFails (backups {
        pluginConfig = {
          extraArgs = [ "--log-level=debug" ];
          env.GOMEMLIMIT = "200MiB";
        };
      })
    )
    || throw "cnpg-barman-cloud refusals: ${builtins.toJSON { inherit oldImage oldSidecar fine; }}";

  # The vendored definition and roles come from the package's release.
  cnpg-barman-cloud-sources-match-release =
    let
      urls =
        file:
        builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
          map (l: builtins.head (lib.splitString " " (lib.trim l))) (
            lib.splitString "\n" (builtins.readFile file)
          )
        );
      release =
        (barmanPackage {
          scope = {
            instanceName = "cnpg-barman-cloud";
            namespaceName = "cnpg-system";
          };
          inherit lib;
          kix = kixlib;
        }).meta.version;
      dir = ../../../packages/experimental/cnpg-barman-cloud;
      stray = builtins.filter (u: !(lib.hasInfix "/${release}/" u)) (
        urls (dir + "/crds/sources.txt") ++ urls (dir + "/rbac/sources.txt")
      );
    in
    stray == [ ] || throw "sources.txt URLs not at ${release}: ${builtins.toJSON stray}";

  # A cnpg-database on a pooler creates its role and database on the
  # pooler's Cluster and hands consumers the pooler's Service. The Pooler
  # waits for the operator's webhook check, and the pooler pods get egress
  # to the instance pods, which admit them, on TCP 5432.
  cnpg-pooler-database =
    let
      cluster = pooled { modules = [ netpolOn ]; };
      all = ms cluster;
      pooler = byName "pooler" (ofKind "Pooler" all);
      role = byName "data-app-db" (ofKind "DatabaseRole" all);
      credentials = byName "app-db-credentials" (ofKind "Secret" all);
      policies = ofKind "CiliumNetworkPolicy" all;
      checkHash = hashOf cluster.instances.cnpg-system.cnpg-operator.raw.webhookCheck;
      egress = byName "pooler-pooler-egress" policies;
      ingress = byName "pooler-pooler-to-instances" policies;
    in
    (
      pooler.spec.cluster.name == "postgres"
      && pooler.spec.type == "rw"
      && pooler.spec.pgbouncer.poolMode == "session"
      && role.spec.cluster.name == "postgres"
      && lib.hasPrefix "pooler.data.svc." credentials.stringData.host
      && lib.hasInfix checkHash (dependsOn pooler)
      && egress != null
      && lib.hasInfix ''"cnpg.io/podRole":"instance"'' (builtins.toJSON egress.spec)
      && ingress != null
      && lib.hasInfix ''"cnpg.io/poolerName":"pooler"'' (builtins.toJSON ingress.spec)
    )
    || throw "pooler: ${
      builtins.toJSON {
        pooler = pooler.spec or null;
        host = credentials.stringData.host or null;
        policies = map (p: p.metadata.name) policies;
      }
    }";

  # The pooler's refusals: an instance name that is not a DNS-1035 label,
  # monitoring.enablePodMonitor, a locked extraSpec path, a pooler in
  # another namespace than its cluster, and a pooler on a stackgres-cluster;
  # the defaults and a pgbouncer parameter pass.
  cnpg-pooler-refusals =
    let
      messages =
        instanceName: config:
        failedMessages {
          package = poolerPackage;
          inherit instanceName config;
        };
      badName = messages "Pooler" { };
      podMonitor = messages "pooler" { extraSpec.monitoring.enablePodMonitor = true; };
      fine = messages "pooler" { extraSpec.pgbouncer.poolMode = "transaction"; };
    in
    (
      says "is not a DNS-1035 label" badName
      && says "extraSpec sets monitoring.enablePodMonitor" podMonitor
      && fine == [ ]
      && evalFails (pooled {
        poolerConfig.extraSpec.instances = 3;
      })
      && evalFails (pooled {
        poolerConfig.extraSpec.template.spec.containers = [ ];
      })
      && evalFails (pooled {
        poolerNamespace = "apps";
      })
      && evalFails (pooled {
        postgres = stackgresClusterPackage;
      })
      && !evalFails (pooled {
        poolerConfig.extraSpec.pgbouncer.parameters.max_client_conn = "500";
      })
    )
    || throw "cnpg-pooler refusals: ${builtins.toJSON { inherit badName podMonitor fine; }}";

  # The rules select on the PodMonitor's job and render only with a
  # prometheus dependency and metrics on. The replication rules need more
  # than one instance and the backup rules need `backup`.
  cnpg-cluster-alerts =
    let
      withPrometheus.instances.monitoring.prometheus.package = prometheusStub;
      rulesOf = cluster: alertRulesOf "PrometheusRule" "postgres" (ms cluster);
      plain =
        clusterConfig:
        rulesOf (cnpg {
          inherit clusterConfig;
          database = null;
          extra = withPrometheus;
        });
      one = plain { instances = 1; };
      two = plain { instances = 2; };
      backedUp = rulesOf (backups {
        modules = [ withPrometheus ];
      });
      replication = [
        "CNPGClusterMultiplePrimaries"
        "CNPGStandbysNotStreaming"
        "CNPGReplicationLagHigh"
      ];
      backupRules = [
        "CNPGWALArchivingFailing"
        "CNPGBackupMissing"
        "CNPGBackupNeverCompleted"
        "CNPGBackupFailed"
        "CNPGBackupMetricsMissing"
      ];
      hasAll = names: rules: lib.all (n: rules ? ${n}) names;
      hasNone = names: rules: !lib.any (n: rules ? ${n}) names;
    in
    (
      allSelect ''namespace="data",job="data/postgres"'' two
      && allSelect ''namespace="data",job="data/postgres"'' backedUp
      && one ? CNPGClusterDown
      && hasNone replication one
      && hasAll replication two
      && hasNone backupRules two
      && hasAll backupRules backedUp
      &&
        rulesOf (cnpg {
          database = null;
        }) == null
      && plain { metrics.enabled = false; } == null
    )
    || throw "cnpg-cluster alerts: one ${builtins.toJSON (builtins.attrNames one)}, two ${builtins.toJSON (builtins.attrNames two)}, backup ${builtins.toJSON (builtins.attrNames backedUp)}";

  # The operator's rules select its metrics Service and need a prometheus
  # dependency and metrics.enabled.
  cnpg-operator-alerts =
    let
      withPrometheus.instances.monitoring.prometheus.package = prometheusStub;
      rulesOf =
        {
          operatorConfig ? { },
          extra ? withPrometheus,
        }:
        alertRulesOf "PrometheusRule" "cnpg-operator" (
          ms (cnpg {
            inherit operatorConfig extra;
            database = null;
          })
        );
      rules = rulesOf { };
    in
    (
      allSelect ''namespace="cnpg-system",service="cnpg-operator-metrics"'' rules
      &&
        builtins.attrNames rules == [
          "CNPGOperatorDown"
          "CNPGOperatorReconcileErrors"
        ]
      && rulesOf { extra = { }; } == null
      && rulesOf { operatorConfig.metrics.enabled = false; } == null
    )
    || throw "cnpg-operator alerts: ${builtins.toJSON (builtins.attrNames rules)}";

  # An import names the source in externalClusters, by the service-ref's
  # DNS name and port and the password Secret's key, and copies the one
  # database into the application database extraSpec names. The service-ref
  # renders its import marker with the selector and ports.
  cnpg-cluster-import-renders =
    let
      cluster = imported { };
      all = ms cluster;
      spec = clusterSpec cluster;
      source = builtins.head spec.externalClusters;
      marker = byName "service-ref-old-db-old-db" (ofKind "PackageInstance" all);
    in
    (
      spec.bootstrap.initdb == {
        database = "registry";
        owner = "harbor";
        import = {
          type = "microservice";
          databases = [ "registry" ];
          source.externalCluster = "import-source";
        };
      }
      && builtins.length spec.externalClusters == 1
      && source.name == "import-source"
      &&
        source.connectionParameters == {
          host = "old-db.legacy.svc.cluster.local";
          port = "5433";
          user = "postgres";
          dbname = "postgres";
          sslmode = "require";
        }
      &&
        source.password == {
          name = "old-db-password";
          key = "password";
        }
      && !(source ? sslRootCert)
      && marker != null
      && marker.metadata.namespace == "legacy"
      && marker.metadata.annotations.${kixKeys.importKind} == "Service"
      && marker.metadata.annotations.${kixKeys.importName} == "old-db"
      &&
        marker.metadata.annotations.${kixKeys.servicePorts}
        == ''[{"port":5433,"protocol":"TCP","targetPort":5432}]''
    )
    || throw "import: ${
      builtins.toJSON {
        bootstrap = spec.bootstrap or null;
        externalClusters = spec.externalClusters or null;
        marker = marker.metadata or null;
      }
    }";

  # Under default deny, the Cluster's pods, the import Job's among them, get
  # egress to the source's pods on the port they listen on, and the source's
  # pods admit them. Without import, no policy names the source.
  cnpg-cluster-import-network-policy =
    let
      policies = c: ofKind "CiliumNetworkPolicy" (ms c);
      withImport = policies (imported {
        modules = [ netpolOn ];
      });
      egress = byName "postgres-cluster-postgres-egress" withImport;
      ingress = byName "postgres-cluster-postgres-to-old-db-ingress" withImport;
      toSource = builtins.filter (r: (r.stubRule or "") == "service-egress") egress.spec.egress;
      plain = policies (cnpg {
        database = null;
        extra = netpolOn;
      });
    in
    (
      egress != null
      && egress.metadata.namespace == "data"
      && egress.spec.endpointSelector.matchLabels == { "cnpg.io/cluster" = "postgres"; }
      &&
        toSource == [
          {
            stubRule = "service-egress";
            namespace = "legacy";
            selector."app.example.com/cluster" = "old-db";
            ports = [
              {
                port = 5433;
                targetPort = 5432;
                protocol = "TCP";
              }
            ];
          }
        ]
      && ingress != null
      && ingress.metadata.namespace == "legacy"
      && ingress.spec.endpointSelector.matchLabels == { "app.example.com/cluster" = "old-db"; }
      && lib.hasInfix ''"cnpg.io/cluster":"postgres"'' (builtins.toJSON ingress.spec.ingress)
      && !(lib.hasInfix "old-db" (builtins.toJSON plain))
    )
    || throw "import policies: ${builtins.toJSON (map (p: p.metadata.name) withImport)} egress: ${
      builtins.toJSON (egress.spec or null)
    } ingress: ${builtins.toJSON (ingress.spec or null)}";

  # A managed cnpg-cluster can be the source, through its out.fqdn and
  # out.port. A monolith import copies roles too, and takes `*`. import's
  # extraSpec merges into bootstrap.initdb.import.
  cnpg-cluster-import-from-cnpg-cluster =
    let
      cluster = imported {
        importConfig = {
          type = "monolith";
          databases = [ "*" ];
          roles = [ "*" ];
          user = "postgres";
          sslMode = "require";
          extraSpec.pgDumpExtraOptions = [ "--jobs=2" ];
        };
        extraSpec = { };
        deps = ref: {
          importSource = ref.data.old-pg;
          importPassword = ref.data.old-db-password;
        };
        extra.old-pg = {
          package = clusterPackage;
          config.instances = 1;
        };
      };
      spec = clusterSpec cluster;
      source = builtins.head spec.externalClusters;
    in
    (
      spec.bootstrap.initdb.import == {
        type = "monolith";
        databases = [ "*" ];
        roles = [ "*" ];
        source.externalCluster = "import-source";
        pgDumpExtraOptions = [ "--jobs=2" ];
      }
      && source.connectionParameters.host == "old-pg-rw.data.svc.cluster.local"
      && source.connectionParameters.port == "5432"
    )
    || throw "monolith import: ${builtins.toJSON (spec.bootstrap or null)} ${
      builtins.toJSON (spec.externalClusters or null)
    }";

  # verify-full checks the source's certificate against importCa's ca.crt.
  cnpg-cluster-import-verifies-with-ca =
    let
      cluster = imported {
        importConfig = {
          databases = [ "registry" ];
          user = "postgres";
        };
        deps = ref: {
          importSource = ref.legacy.old-db;
          importPassword = ref.data.old-db-password;
          importCa = ref.data.old-db-ca;
        };
        extra.old-db-ca = {
          package = secretPackage;
          config.stringData."ca.crt" = "not a real certificate";
        };
      };
      source = builtins.head (clusterSpec cluster).externalClusters;
    in
    (
      source.connectionParameters.sslmode == "verify-full"
      &&
        source.sslRootCert == {
          name = "old-db-ca";
          key = "ca.crt";
        }
    )
    || throw "verify-full: ${builtins.toJSON source}";

  # The import's refusals, each beside a configuration that builds: no
  # source, no password, a source without an address, a password Secret
  # without the key, verify-full without a CA, a CA nothing checks, and
  # extraSpec or import.extraSpec setting what the package owns.
  cnpg-cluster-import-refusals =
    let
      wired = ref: {
        importSource = ref.legacy.old-db;
        importPassword = ref.data.old-db-password;
      };
      require = {
        databases = [ "registry" ];
        user = "postgres";
        sslMode = "require";
      };
      plainSource = eval.mkImport {
        out = {
          fqdn = "plain-db.data.svc.cluster.local";
          port = "5432";
          tls = false;
        };
      };
    in
    (
      !(evalFails (imported { }))
      && evalFails (imported {
        deps = ref: { importPassword = ref.data.old-db-password; };
      })
      && evalFails (imported {
        deps = ref: { importSource = ref.legacy.old-db; };
      })
      && evalFails (imported {
        deps = ref: wired ref // { importSource = ref.data.old-db-password; };
      })
      && evalFails (imported {
        importConfig = require // {
          passwordKey = "secret";
        };
      })
      && evalFails (imported {
        importConfig = removeAttrs require [ "sslMode" ];
      })
      && evalFails (imported {
        deps = ref: wired ref // { importCa = ref.data.old-db-password; };
      })
      && evalFails (imported {
        extraSpec.externalClusters = [ { name = "other"; } ];
      })
      && evalFails (imported {
        extraSpec.bootstrap.initdb.import.type = "monolith";
      })
      && evalFails (imported {
        importConfig = require // {
          extraSpec.source.externalCluster = "other";
        };
      })
      && evalFails (imported {
        importConfig = require // {
          extraSpec.databases = [ "other" ];
        };
      })
      && !(evalFails (imported {
        importConfig = require // {
          extraSpec.schemaOnly = true;
        };
      }))
      # A source that serves no TLS, with a mode that needs it, and with one that does not.
      && evalFails (imported {
        deps = ref: wired ref // { importSource = ref.data.plain-db; };
        extra.plain-db.package = plainSource;
      })
      && !(evalFails (imported {
        importConfig = require // {
          sslMode = "disable";
        };
        deps = ref: wired ref // { importSource = ref.data.plain-db; };
        extra.plain-db.package = plainSource;
      }))
      # Import dependencies wired while import is null.
      && evalFails (imported {
        importConfig = null;
      })
      && evalFails (imported {
        importConfig = null;
        extraSpec = { };
        deps = ref: { importPassword = ref.data.old-db-password; };
      })
      && !(evalFails (imported {
        importConfig = null;
        extraSpec = { };
        deps = _: { };
      }))
      # bootstrap.initdb.import through extraSpec, with import null.
      && evalFails (cnpg {
        database = null;
        clusterConfig.extraSpec.bootstrap.initdb.import = {
          type = "microservice";
          databases = [ "app" ];
          source.externalCluster = "other";
        };
      })
      && !(evalFails (cnpg {
        database = null;
        clusterConfig.extraSpec.externalClusters = [ { name = "other"; } ];
      }))
    )
    || throw "an import refusal did not hold, or its control failed";

  # The import's assertions: a microservice import takes exactly one named
  # database and no roles, and a Cluster bootstraps one way. Each has a
  # control that passes.
  cnpg-cluster-import-assertions =
    let
      messages =
        config:
        failedMessages {
          package = clusterPackage;
          instanceName = "postgres";
          inherit config;
        };
      base = {
        databases = [ "registry" ];
        user = "postgres";
      };
    in
    (
      messages { import = base; } == [ ]
      && says "exactly one named database" (messages {
        import = base // {
          databases = [
            "a"
            "b"
          ];
        };
      })
      && says "exactly one named database" (messages {
        import = base // {
          databases = [ "*" ];
        };
      })
      && says "exactly one named database" (messages {
        import = base // {
          databases = [ "app*" ];
        };
      })
      && says "beside names" (messages {
        import = base // {
          type = "monolith";
          databases = [
            "*"
            "a"
          ];
        };
      })
      && says "beside names" (messages {
        import = base // {
          type = "monolith";
          roles = [
            "*"
            "r"
          ];
        };
      })
      && says "microservice import only" (messages {
        import = base // {
          type = "monolith";
          extraSpec.postImportApplicationSQL = [ "ANALYZE" ];
        };
      })
      &&
        messages {
          import = base // {
            extraSpec.postImportApplicationSQL = [ "ANALYZE" ];
          };
        } == [ ]
      &&
        messages {
          import = base // {
            type = "monolith";
            databases = [
              "a"
              "b"
            ];
            roles = [ "*" ];
          };
        } == [ ]
      && says "copies no roles" (messages {
        import = base // {
          roles = [ "app" ];
        };
      })
      && says "bootstraps one way" (messages {
        import = base;
        extraSpec.bootstrap.recovery.source = "backup";
      })
      && says "bootstraps one way" (messages {
        import = base;
        extraSpec.bootstrap.pg_basebackup.source = "other";
      })
      && messages { extraSpec.bootstrap.recovery.source = "backup"; } == [ ]
    )
    || throw "import assertions: ${
      builtins.toJSON (messages {
        import = base // {
          roles = [ "app" ];
        };
      })
    }";
}

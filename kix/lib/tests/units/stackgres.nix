# Tests for the stackgres packages and the kix/lib behaviour they rely on:
# kix.availability.spreadConstraints (the spread rule for operator-placed
# operands), the refusals of stackgres-operator, stackgres-cluster, and
# stackgres-object-storage, the operand image table, the rendered
# SGCluster, the webhook check that StackGres custom resources wait for,
# the alert rules of stackgres-operator and stackgres-cluster and what
# each is gated on,
# stackgres-database's names in the cluster's namespace, and its warning on
# a literal `password`.

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
  multiZone,
  alertRulesOf,
  allSelect,
  prometheusStub,
  netpolOn,
  ...
}:

let
  operatorPackage = import ../../../packages/stackgres-operator;
  clusterPackage = import ../../../packages/stackgres-cluster;
  objectStoragePackage = import ../../../packages/stackgres-object-storage;
  databasePackage = import ../../../packages/stackgres-database;
  secretPackage = import ../../../packages/secret;
  releaseTable = import ../../../packages/stackgres-operator/release.nix { inherit lib; };

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

  # The operator, a cluster with `config`, and an object storage when
  # `objectStorage` is set, in the namespaces StackGres users pick.
  sgCluster =
    {
      config ? { },
      operatorConfig ? { },
      objectStorage ? null,
      extra ? { },
    }:
    mkCluster [
      {
        instances.stackgres-system.stackgres-operator = {
          package = operatorPackage;
          config = operatorConfig;
        };
        instances.data = {
          postgres = {
            package = clusterPackage;
            inherit config;
          };
        }
        // lib.optionalAttrs (objectStorage != null) {
          s3-credentials = {
            package = secretPackage;
            aliases = [ "storageCredentials" ];
            config.stringData = {
              accessKeyId = "id";
              secretAccessKey = "key";
            };
          };
          backups = {
            package = objectStoragePackage;
            config = objectStorage;
          };
        };
      }
      extra
    ];
  sgClusterSpec = cluster: (byName "postgres" (ofKind "SGCluster" (manifests cluster))).spec;
  storage = {
    type = "s3Compatible";
    bucket = "backups";
  };

  zoneKey = "topology.kubernetes.io/zone";
  hostKey = "kubernetes.io/hostname";
  selector.app = "operand";

  spread =
    level: failureDomainKeys:
    kixlib.availability.spreadConstraints {
      inherit level selector;
      topology = {
        inherit zoneKey hostKey failureDomainKeys;
      };
    };

  constraint = key: whenUnsatisfiable: {
    topologyKey = key;
    maxSkew = 1;
    inherit whenUnsatisfiable;
    nodeTaintsPolicy = "Honor";
    labelSelector.matchLabels = selector;
  };
in
{
  # At zone on a multi-zone cluster: the zone key is hard, the host key soft.
  stackgres-spread-zone =
    let
      got = spread "zone" [
        zoneKey
        hostKey
      ];
    in
    got == [
      (constraint zoneKey "DoNotSchedule")
      (constraint hostKey "ScheduleAnyway")
    ]
    || throw "spreadConstraints at zone: ${builtins.toJSON got}";

  # At node on a single-zone cluster: the host key is hard.
  stackgres-spread-node =
    let
      got = spread "node" [ hostKey ];
    in
    got == [ (constraint hostKey "DoNotSchedule") ]
    || throw "spreadConstraints at node: ${builtins.toJSON got}";

  # A single-node cluster has no failure-domain keys and gets no constraints.
  stackgres-spread-single-node =
    let
      got = spread "none" [ ];
    in
    got == [ ] || throw "spreadConstraints on a single node: ${builtins.toJSON got}";

  # The StackGres CRDs refuse quantities Kubernetes accepts: the messages
  # name the pattern and a value that fits.
  stackgres-cluster-quantity-patterns =
    let
      got = failedMessages {
        package = clusterPackage;
        instanceName = "postgres";
        config = {
          instanceProfile = {
            cpu = "1.5";
            memory = "2G";
          };
          persistentVolume.size = "20G";
        };
      };
      fine = failedMessages {
        package = clusterPackage;
        instanceName = "postgres";
        config = {
          instanceProfile = {
            cpu = "1500m";
            memory = "1.5Gi";
          };
          persistentVolume.size = "1Ti";
        };
      };
    in
    (
      says ''instanceProfile.cpu is "1.5", which StackGres refuses: it must match ^[1-9][0-9]*[m]?$. Write whole cores ("2") or millicores ("1500m").'' got
      && says ''instanceProfile.memory is "2G", which StackGres refuses'' got
      && says ''persistentVolume.size is "20G", which StackGres refuses: it must match ^[0-9]+(\.[0-9]+)?(Mi|Gi|Ti)$. Use Mi, Gi, or Ti, such as "20Gi".'' got
      && fine == [ ]
    )
    || throw "stackgres-cluster quantity refusals: ${builtins.toJSON { inherit got fine; }}";

  # The other stackgres-cluster assertions, one message each.
  stackgres-cluster-refusals =
    let
      longName = "a" + lib.concatStrings (lib.replicate 44 "b");
      named = failedMessages {
        package = clusterPackage;
        instanceName = longName;
      };
      got = failedMessages {
        package = clusterPackage;
        instanceName = "postgres";
        config = {
          extraSpec.pods.disableEnvoy = false;
          backups = [
            { sgObjectStorage = "other"; }
            { cronSchedule = "0 2 * * 0"; }
          ];
          scripts = [ { name = "empty"; } ];
          extensions = [
            {
              name = "vector";
              version = "0.7.0";
            }
            {
              name = "vector";
              version = "0.8.0";
            }
          ];
        };
      };
    in
    (
      says ''StackGres limits an SGCluster name to 44 characters matching ^[a-z]([-a-z0-9]*[a-z0-9])?$; "${longName}" is 45 characters. Rename the instance.'' named
      && says "extraSpec sets pods.disableEnvoy = false." got
      && says "backups entries take sgObjectStorage from the sgObjectStorage dependency. Remove it." got
      && says "backups has more than one entry, but StackGres schedules backups only from the first entry" got
      && !(says "backups has more than one entry" (failedMessages {
        package = clusterPackage;
        instanceName = "postgres";
        config.backups = [ { } ];
      }))
      && says "scripts entry 0 must set exactly one of script or scriptFrom." got
      && says "extension vector is requested at versions 0.7.0 and 0.8.0." got
    )
    || throw "stackgres-cluster refusals: ${builtins.toJSON { inherit named got; }}";

  # Each build refusal of stackgres-cluster fails the evaluation.
  stackgres-cluster-build-refusals =
    let
      fails = args: evalFails (sgCluster args);
      atZone = {
        extra = lib.recursiveUpdate multiZone { cluster.availability.default = "zone"; };
      };
    in
    (
      fails { config.postgres.version = "latest"; }
      && fails { config.postgres.version = "19"; }
      && fails { config.postgres.version = "17.1"; }
      # 12.22, the newest 12.x, has no published images.
      && fails { config.postgres.version = "12"; }
      && fails { config.extraSpec.postgres.flavor = "babelfish"; }
      && fails { config.backups = [ { } ]; }
      && fails (atZone // { config.extraSpec.profile = "development"; })
      && fails (atZone // { config.extraSpec.nonProductionOptions.disableClusterPodAntiAffinity = true; })
      && !(fails (
        atZone
        // {
          config.extraSpec = {
            profile = "development";
            nonProductionOptions.disableClusterPodAntiAffinity = false;
          };
        }
      ))
      && !(fails { config.postgres.version = "17.11"; })
    )
    || throw "stackgres-cluster build refusals";

  # The rendered SGCluster: a pooler and a script reference their resources,
  # backups name the object storage, and a single-node cluster turns off the
  # namespace-wide anti-affinity.
  stackgres-cluster-renders =
    let
      cluster = sgCluster {
        config = {
          pooling = { };
          scripts = [
            {
              name = "init";
              script = "SELECT 1";
            }
          ];
          backups = [ { compression = "zstd"; } ];
          extensions = [
            {
              name = "pg_cron";
              repository = "https://extensions.example.com/repo";
            }
          ];
        };
        objectStorage = storage;
        extra = singleNode;
      };
      spec = sgClusterSpec cluster;
      ms = manifests cluster;
      pooling = byName "postgres-pooling-config" (ofKind "SGPoolingConfig" ms);
      script = byName "postgres-init" (ofKind "SGScript" ms);
    in
    (
      spec.configurations.sgPoolingConfig == "postgres-pooling-config"
      && pooling.spec == { pgBouncer."pgbouncer.ini" = { }; }
      && spec.pods.disableConnectionPooling == false
      && spec.managedSql.scripts == [ { sgScript = "postgres-init"; } ]
      &&
        script.spec.scripts == [
          {
            name = "init";
            script = "SELECT 1";
          }
        ]
      &&
        spec.configurations.backups == [
          {
            compression = "zstd";
            sgObjectStorage = "backups";
          }
        ]
      &&
        spec.postgres.extensions == [
          {
            name = "pg_cron";
            repository = "https://extensions.example.com/repo";
          }
        ]
      && spec.nonProductionOptions == { disableClusterPodAntiAffinity = true; }
    )
    || throw "stackgres-cluster render: ${builtins.toJSON spec}";

  # On a multi-node cluster the production profile's anti-affinity stays on.
  stackgres-cluster-multi-node-keeps-anti-affinity =
    let
      spec = sgClusterSpec (sgCluster {
        extra = multiZone;
      });
    in
    !(spec ? nonProductionOptions) || throw "multi-node SGCluster: ${builtins.toJSON spec}";

  # The operator's refusals: a tag other than the release, a repository
  # outside the quay.io layout, SGConfig keys StackGres reads elsewhere, and
  # a variable the package sets.
  stackgres-operator-refusals =
    let
      got = failedMessages {
        package = operatorPackage;
        instanceName = "stackgres-operator";
        namespaceName = "stackgres-system";
        config = {
          image = {
            repository = "registry.example.com/operator";
            tag = "1.19.0";
          };
          sgConfig = {
            deploy.restapi = true;
            adminui = { };
          };
        };
      };
      jvm = failedMessages {
        package = operatorPackage;
        instanceName = "stackgres-operator";
        namespaceName = "stackgres-system";
        config.image.tag = "${releaseTable.release}-jvm";
      };
    in
    (
      says ''image.tag "1.19.0" is not StackGres ${releaseTable.release}'' got
      && says ''image.repository "registry.example.com/operator" does not end in /stackgres/operator.'' got
      && says "sgConfig sets deploy, adminui. StackGres reads these from operator variables" got
      && jvm == [ ]
      && evalFails (sgCluster {
        operatorConfig.env.SGCONFIG = "x";
      })
      && evalFails (sgCluster {
        operatorConfig.env.ALLOWED_NAMESPACES = "data";
      })
    )
    || throw "stackgres-operator refusals: ${builtins.toJSON { inherit got jvm; }}";

  # Every StackGres custom resource built through out.crds requires the
  # webhook-check Job. The Job's image takes the operator's registry prefix
  # and pull policy, and its tag is the newest kubectl entry in
  # versions.properties.
  stackgres-operator-crd-handles-gated =
    let
      cluster = sgCluster {
        config = {
          pooling = { };
          scripts = [
            {
              name = "init";
              script = "SELECT 1";
            }
          ];
        };
        operatorConfig.image = {
          repository = "registry.example.com/mirror/stackgres/operator";
          pullPolicy = "Always";
        };
        extra = singleNode;
      };
      ms = manifests cluster;
      operator = cluster.instances.stackgres-system.stackgres-operator;
      jobHash = builtins.unsafeDiscardStringContext operator.raw.webhookCheck.out.identityHash;
      dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
      customResources = builtins.filter (
        m: lib.hasPrefix "stackgres.io/" m.apiVersion && m.kind != "SGConfig"
      ) ms;
      ungated = map (m: "${m.kind}/${m.metadata.name}") (
        builtins.filter (m: !(lib.hasInfix jobHash (dependsOn m))) customResources
      );
      kinds = lib.unique (lib.naturalSort (map (m: m.kind) customResources));
      container = builtins.head (byName "stackgres-operator-webhook-check" (ofKind "Job" ms))
        .spec.template.spec.containers;
      newestKubectl = builtins.head (
        releaseTable.kubectlImages {
          registry = "registry.example.com/mirror";
          k8sVersion = null;
        }
      );
    in
    (
      ungated == [ ]
      &&
        kinds == [
          "SGCluster"
          "SGInstanceProfile"
          "SGPoolingConfig"
          "SGPostgresConfig"
          "SGScript"
        ]
      && lib.hasPrefix "${newestKubectl}@sha256:" container.image
      && container.imagePullPolicy == "Always"
    )
    || throw "webhook-check gate: ${
      builtins.toJSON {
        inherit ungated kinds newestKubectl;
        inherit (container) image;
        imagePullPolicy = container.imagePullPolicy or null;
      }
    }";

  # The operand image table: a major takes its newest minor and the Patroni
  # build of that minor; unknown, unpublished, and `latest` versions throw.
  # Two stackgres-database instances named alike in two namespaces, on one
  # cluster, put their bootstrap Secret and Job in the cluster's namespace
  # under names that carry their own namespace, so both render.
  stackgres-database-same-name-two-namespaces =
    let
      dbIn =
        ns:
        { ref, ... }:
        {
          instances.${ns}.app-db = {
            package = databasePackage;
            deps.postgres = ref.data.postgres;
            config.password = "pw-${ns}";
          };
        };
      cluster = sgCluster {
        extra.imports = [
          (dbIn "team-a")
          (dbIn "team-b")
        ];
      };
      inData =
        kind:
        map (m: m.metadata.name) (
          builtins.filter (m: m.metadata.namespace == "data") (ofKind kind (manifests cluster))
        );
      jobs = inData "Job";
      secrets = inData "Secret";
    in
    (
      builtins.any (lib.hasPrefix "app-db-team-a-bootstrap-") jobs
      && builtins.any (lib.hasPrefix "app-db-team-b-bootstrap-") jobs
      && builtins.elem "app-db-team-a-bootstrap-password" secrets
      && builtins.elem "app-db-team-b-bootstrap-password" secrets
    )
    || throw "stackgres-database same name: jobs ${builtins.toJSON jobs}, secrets ${builtins.toJSON secrets}";

  # A literal `password` still fills both Secrets, and warns that Kix 0.10
  # removes it. `passwordSource` gives no such warning.
  stackgres-database-password-warns =
    let
      withDatabase =
        config:
        sgCluster {
          extra =
            { ref, ... }:
            {
              instances.apps.app-db = {
                package = databasePackage;
                deps.postgres = ref.data.postgres;
                inherit config;
              };
            };
        };
      literal = withDatabase { password = "pw"; };
      sops = withDatabase {
        passwordSource = ./stackgres.nix;
        passwordHash = "hash";
      };
      warningsOf = cluster: cluster.instances.apps.app-db._diagnostics.warnings;
      warns = cluster: builtins.any (lib.hasInfix "Kix 0.10 removes") (warningsOf cluster);
      passwordIn = name: (byName name (ofKind "Secret" (manifests literal))).stringData.password;
    in
    (
      warns literal
      && !(warns sops)
      && passwordIn "app-db-credentials" == "pw"
      && passwordIn "app-db-apps-bootstrap-password" == "pw"
    )
    || throw "stackgres-database password warning: ${
      builtins.toJSON {
        literal = warningsOf literal;
        sops = warningsOf sops;
      }
    }";

  stackgres-resolve-postgres =
    let
      resolve =
        version:
        releaseTable.resolvePostgres {
          who = "test";
          inherit version;
          registry = "quay.io";
          operatorTag = releaseTable.release;
        };
      fails = version: !(builtins.tryEval (builtins.deepSeq (resolve version) true)).success;
      pg16 = resolve "16";
    in
    (
      pg16.minor == "16.15"
      && pg16.images.patroni == "quay.io/ongres/patroni:v4.1.5-pg16.15-build-6.56"
      && (resolve "17.6").images.postgresUtil == "quay.io/ongres/postgres-util:v17.6-build-6.44"
      && fails "latest"
      && fails "19"
      && fails "17.1"
      && fails "12"
      && fails "12.22"
    )
    || throw "resolvePostgres: ${builtins.toJSON pg16}";

  # kubectl follows the API server's minor within one, else the newest.
  stackgres-kubectl-images =
    let
      images =
        k8sVersion:
        releaseTable.kubectlImages {
          registry = "quay.io";
          inherit k8sVersion;
        };
    in
    (
      images "1.34" == [ "quay.io/ongres/kubectl:v1.33.13-build-6.56" ]
      && images "v1.37.2-gke.100" == [ "quay.io/ongres/kubectl:v1.37.1-build-6.56" ]
      && images "1.10" == [ "quay.io/ongres/kubectl:v1.37.1-build-6.56" ]
      && builtins.length (images null) == 8
    )
    || throw "kubectlImages: ${builtins.toJSON (images "1.34")}";

  # The object storage's refusals: S3 bucket names and selectors the type
  # does not read; a malformed endpoint and an in-cluster store on another
  # type fail the build.
  stackgres-object-storage-refusals =
    let
      got = failedMessages {
        package = objectStoragePackage;
        instanceName = "backups";
        config = {
          type = "s3";
          bucket = "Backups..x";
          credentialKeys.serviceAccountJSON = "json";
        };
      };
      # Without an enforcer nothing reads the port, so the test reads it.
      portOf =
        objectStorage:
        (sgCluster {
          inherit objectStorage;
          config.backups = [ { } ];
        }).instances.data.backups.raw.root.out.worldEgressPort;
      fails = objectStorage: !(builtins.tryEval (portOf objectStorage)).success;
    in
    (
      says ''bucket "Backups..x" is not a valid S3 bucket name: it must use only lowercase letters'' got
      && says "it contains two adjacent dots" got
      && says ''credentialKeys sets serviceAccountJSON, which type "s3" does not read. Remove it.'' got
      && fails (storage // { extraSpec.s3Compatible.endpoint = "s3.example.com"; })
      && portOf (storage // { extraSpec.s3Compatible.endpoint = "https://s3.example.com:9443"; }) == 9443
      && portOf (storage // { extraSpec.s3Compatible.endpoint = "http://s3.example.com"; }) == 80
      && portOf storage == 443
    )
    || throw "stackgres-object-storage refusals: ${builtins.toJSON got}";

  # The rules select on the PodMonitor's job and render only with a
  # prometheus dependency, metrics on, and the exporter sidecar on, which
  # either of two extraSpec keys turns off. The replication rules need more
  # than one instance, WAL archiving needs `backups`, and a standby cluster
  # (`extraSpec.replicateFrom`) gets no StackGresClusterNoPrimary.
  stackgres-cluster-alerts =
    let
      withPrometheus.instances.monitoring.prometheus.package = prometheusStub;
      rulesOf =
        args:
        alertRulesOf "PrometheusRule" "postgres" (
          manifests (sgCluster ({ extra = withPrometheus; } // args))
        );
      one = rulesOf { config.instances = 1; };
      two = rulesOf { config.instances = 2; };
      backedUp = rulesOf {
        config.backups = [ { compression = "zstd"; } ];
        objectStorage = storage;
      };
      standby = rulesOf {
        config.extraSpec.replicateFrom.instance.external = {
          host = "primary.example.com";
          port = 5432;
        };
      };
      replication = [
        "StackGresClusterMultiplePrimaries"
        "StackGresStandbysNotStreaming"
        "StackGresReplicationLagHigh"
      ];
      hasAll = names: rules: lib.all (n: rules ? ${n}) names;
      hasNone = names: rules: !lib.any (n: rules ? ${n}) names;
    in
    (
      allSelect ''namespace="data",job="data/postgres"'' two
      && allSelect ''namespace="data",job="data/postgres"'' backedUp
      && one ? StackGresClusterDown
      && one ? StackGresClusterNoPrimary
      && hasNone replication one
      && hasAll replication two
      && !(two ? StackGresWALArchivingFailing)
      && backedUp ? StackGresWALArchivingFailing
      && standby ? StackGresClusterDown
      && !(standby ? StackGresClusterNoPrimary)
      && rulesOf { extra = { }; } == null
      && rulesOf { config.metrics.enabled = false; } == null
      && rulesOf { config.extraSpec.pods.disableMetricsExporter = true; } == null
      && rulesOf { config.extraSpec.configurations.observability.disableMetrics = true; } == null
    )
    || throw "stackgres-cluster alerts: one ${builtins.toJSON (builtins.attrNames one)}, two ${builtins.toJSON (builtins.attrNames two)}, backups ${builtins.toJSON (builtins.attrNames backedUp)}";

  # SGDbOps and SGBackup Job pods reach DNS and the API server, SGDbOps Jobs
  # reach PostgreSQL on 5432, and the PostgreSQL pods admit them. Without an
  # enforcer the package writes none of these policies.
  stackgres-cluster-job-policies =
    let
      policies = ofKind "CiliumNetworkPolicy" (
        manifests (sgCluster {
          extra = netpolOn;
        })
      );
      dbOps = byName "postgres-dbops-egress" policies;
      backup = byName "postgres-backup-job-egress" policies;
      ingress = byName "postgres-operand-ingress" policies;
      operandSelector = {
        app = "StackGresCluster";
        "stackgres.io/cluster-name" = "postgres";
      };
      stubRules = p: map (r: r.stubRule or null) p.spec.egress;
      plain = ofKind "CiliumNetworkPolicy" (manifests (sgCluster { }));
    in
    (
      dbOps.spec.endpointSelector.matchLabels == {
        app = "StackGresDbOps";
      }
      &&
        stubRules dbOps == [
          "dns-egress"
          "apiserver-egress"
          "service-egress"
        ]
      && (lib.last dbOps.spec.egress).selector == operandSelector
      && map (p: p.port) (lib.last dbOps.spec.egress).ports == [ 5432 ]
      && backup.spec.endpointSelector.matchLabels == { app = "StackGresBackup"; }
      &&
        stubRules backup == [
          "dns-egress"
          "apiserver-egress"
        ]
      && builtins.any (
        r: (r.callerSelector or null) == { app = "StackGresDbOps"; } && map (p: p.port) r.ports == [ 5432 ]
      ) ingress.spec.ingress
      && plain == [ ]
    )
    || throw "stackgres-cluster job policies: ${builtins.toJSON { inherit dbOps backup; }}";

  # The operator's rules select its metrics Service, which serves Quarkus's
  # /q/metrics, and need a prometheus dependency and metrics.enabled.
  stackgres-operator-alerts =
    let
      withPrometheus.instances.monitoring.prometheus.package = prometheusStub;
      msOf = args: manifests (sgCluster ({ extra = withPrometheus; } // args));
      rulesOf = args: alertRulesOf "PrometheusRule" "stackgres-operator" (msOf args);
      rules = rulesOf { };
      monitor = byName "stackgres-operator" (ofKind "ServiceMonitor" (msOf { }));
    in
    (
      allSelect ''namespace="stackgres-system",service="stackgres-operator-metrics"'' rules
      &&
        builtins.attrNames rules == [
          "StackGresOperatorDown"
          "StackGresOperatorReconcileErrors"
        ]
      && (builtins.head monitor.spec.endpoints).path == "/q/metrics"
      && rulesOf { extra = { }; } == null
      && rulesOf { operatorConfig.metrics.enabled = false; } == null
    )
    || throw "stackgres-operator alerts: ${
      builtins.toJSON (if rules == null then null else builtins.attrNames rules)
    }";
}

# Tests for the `cluster-admin` unsafe grant and the
# `security.noClusterAdmin` rule that enforces its absence, for the
# network policies derived for a terminate-declared CR (the velero
# BackupStorageLocation), and for the velero package's refusals.

{
  lib,
  mkCluster,
  baseInstances,
  manifests,
  evalFails,
  netpolOn,
  kixlib,
  ofKind,
  byName,
  kixKeys,
  alertRulesOf,
  prometheusStub,
  ...
}:

let
  # A ServiceAccount bound to cluster-admin, a ClusterRole with an
  # all-wildcard rule, and two shapes the rule leaves alone: a wildcard
  # limited to one API group and a namespaced RoleBinding to cluster-admin.
  mkAdminPackage =
    {
      unsafe ? [ ],
    }:
    {
      meta = {
        version = "test";
        inherit unsafe;
      };
      build =
        { self, scope, ... }:
        {
          sa = scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "backup";
          };
          binding = scope.mkClusterResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRoleBinding";
            name = "backup-admin";
            extra = {
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "ClusterRole";
                name = "cluster-admin";
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = "backup";
                  namespace = scope.namespaceName;
                }
              ];
            };
          };
          wildcardRole = scope.mkClusterResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRole";
            name = "backup-everything";
            extra.rules = [
              {
                apiGroups = [ "*" ];
                resources = [ "*" ];
                verbs = [ "*" ];
              }
            ];
          };
          groupRole = scope.mkClusterResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRole";
            name = "backup-one-group";
            extra.rules = [
              {
                apiGroups = [ "example.com" ];
                resources = [ "*" ];
                verbs = [ "*" ];
              }
            ];
          };
          namespacedBinding = scope.mkResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            name = "backup-local-admin";
            extra = {
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "ClusterRole";
                name = "cluster-admin";
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = "backup";
                  namespace = scope.namespaceName;
                }
              ];
            };
          };
          root = {
            resource = self.sa;
            requires = [
              self.binding
              self.wildcardRole
              self.groupRole
              self.namespacedBinding
            ];
          };
        };
    };

  rules = import ../../rules { inherit lib; };

  # Only the rule under test and the audit rule, so the base instances'
  # other findings do not fail the cluster. Reading `scorecardReport` of a
  # cluster whose cap lets an error through raises the error, so findings
  # are read at the `warning` cap and failure is checked at `error`.
  mkAdminCluster =
    maxSeverity: unsafe:
    mkCluster [
      baseInstances
      {
        scorecard = {
          enable = true;
          inherit maxSeverity;
          rules = {
            security = { inherit (rules.security) noClusterAdmin; };
            architecture = { inherit (rules.architecture) unsafeGrants; };
          };
        };
        instances.backup.backup.package = mkAdminPackage { inherit unsafe; };
      }
    ];

  # The velero package with its store wired to the base instances' db
  # Service, under network policy.
  veleroCluster = mkVelero {
    withStore = true;
    netpol = true;
  };

  findingsOf =
    rule: cluster:
    builtins.filter (f: f.rule == rule && f.instance == "backup") cluster.scorecardReport.findings;

  awsKeyPair = {
    AWS_ACCESS_KEY_ID = "id";
    AWS_SECRET_ACCESS_KEY = "secret";
  };

  # The velero package with a bucket, `config` merged over it, the cloud
  # credentials Secret holding `cloud`, and a repository Secret named
  # `repository` (none when null). `withStore` wires the base instances' db Service as the store,
  # and `withPrometheus` adds a prometheus provider, so the alerts render.
  mkVelero =
    {
      config ? { },
      cloud ? {
        cloud = "[default]";
      },
      repository ? "velero-repo-credentials",
      withStore ? false,
      netpol ? false,
      withPrometheus ? false,
    }:
    mkCluster (
      [
        baseInstances
        (
          { ref, ... }:
          {
            instances.velero = {
              cloud = {
                package = import ../../../packages/stable/secret;
                aliases = [ "cloudCredentials" ];
                config.stringData = cloud;
              };
              velero = {
                package = import ../../../packages/stable/velero;
                config = lib.recursiveUpdate { backupStorageLocation.objectStorage.bucket = "b"; } config;
              }
              // lib.optionalAttrs withStore { deps.objectStorage = ref.dbns.db; };
            }
            // lib.optionalAttrs (repository != null) {
              ${repository} = {
                package = import ../../../packages/stable/secret;
                aliases = [ "repositoryPassword" ];
                config.stringData.repository-password = "key";
              };
            };
          }
        )
      ]
      ++ lib.optional netpol netpolOn
      ++ lib.optional withPrometheus { instances.monitoring.prometheus.package = prometheusStub; }
    );

  # The package's assertions, evaluated against `config` merged over a
  # bucket. A failed assertion fails the whole cluster before its
  # diagnostics can be read, so the messages are taken from here.
  veleroPackage = import ../../../packages/stable/velero {
    inherit lib;
    kix = kixlib;
    scope = {
      instanceName = "velero";
      namespaceName = "velero";
      selectorLabels = {
        "app.kubernetes.io/name" = "velero";
        "app.kubernetes.io/instance" = "velero";
      };
    };
  };
  failedAssertionMessages =
    config:
    let
      evaluated =
        (lib.evalModules {
          modules = [
            { options = veleroPackage.options; }
            { config = lib.recursiveUpdate { backupStorageLocation.objectStorage.bucket = "b"; } config; }
          ];
        }).config;
    in
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (veleroPackage.assertions { config = evaluated; })
    );

  # The cluster built with `config` fails, and a failed assertion of the
  # package contains every string in `needles`.
  refusedWith =
    needles: config:
    let
      messages = failedAssertionMessages config;
    in
    evalFails (mkVelero {
      inherit config;
    })
    && builtins.all (n: builtins.any (lib.hasInfix n) messages) needles;

  # tryEval drops the message of a throw from the build, so these cases
  # check that the cluster fails while the control cluster, which differs
  # by the one setting, builds. The messages were read in a probe.
  builds = cluster: !(evalFails cluster);
in
{
  # Without the grant, the binding and the all-wildcard ClusterRole each
  # produce a finding naming the resource (and, for the binding, its
  # subject), and the cluster fails at the `error` cap. The one-group
  # wildcard and the RoleBinding produce none.
  velero-no-cluster-admin-without-grant =
    let
      found = findingsOf "security.noClusterAdmin" (mkAdminCluster "warning" [ ]);
      messages = map (f: f.message) found;
      has = needle: builtins.any (lib.hasInfix needle) messages;
    in
    (
      builtins.length found == 2
      && rules.security.noClusterAdmin.severity == "error"
      && has "ClusterRoleBinding 'backup-admin' grants cluster-admin to ServiceAccount backup/backup"
      && has "ClusterRole 'backup-everything' grants every verb"
      && has "scope.rbac"
      && has "meta.unsafe"
      && evalFails (mkAdminCluster "error" [ ])
    )
    || throw "noClusterAdmin without the grant: ${builtins.toJSON found}";

  # With the grant, the rule reports nothing, the cluster builds, and the
  # grant is listed by architecture.unsafeGrants.
  velero-no-cluster-admin-with-grant =
    let
      cluster = mkAdminCluster "error" [ "cluster-admin" ];
      found = findingsOf "security.noClusterAdmin" cluster;
      audit = findingsOf "architecture.unsafeGrants" cluster;
    in
    (
      found == [ ]
      && builtins.any (f: f.severity == "info" && lib.hasInfix "'cluster-admin'" f.message) audit
      && builtins.length (manifests cluster) > 0
    )
    || throw "noClusterAdmin with the grant: findings ${builtins.toJSON found}, audit ${builtins.toJSON audit}";

  # The policies derived for a terminate-declared CR do not require the CR:
  # the location's readiness (Available) needs the store connection those
  # policies open, so requiring it would leave the deploy waiting until it
  # times out.
  velero-operand-policies-do-not-wait-for-cr =
    let
      ms = manifests veleroCluster;
      bslHash = builtins.unsafeDiscardStringContext veleroCluster.instances.velero.velero.raw.backupStorageLocation.out.identityHash;
      cnps = ofKind "CiliumNetworkPolicy" ms;
      egress = byName "velero-backupstoragelocation-default-egress" cnps;
      ingress = byName "velero-backupstoragelocation-default-to-db-ingress" cnps;
      dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
    in
    (
      egress != null
      && ingress != null
      && ingress.metadata.namespace == "dbns"
      && !(lib.hasInfix bslHash (dependsOn egress))
      && !(lib.hasInfix bslHash (dependsOn ingress))
    )
    || throw "operand policies: egress ${builtins.toJSON (egress.metadata or null)}, ingress ${
      builtins.toJSON (ingress.metadata or null)
    }";

  # Each assertion of the package fails the cluster with a message that
  # names the setting and the fix. A second location is built in Velero's
  # namespace through scope.forService.
  velero-refuses-invalid-config =
    let
      cases = {
        location-credential =
          refusedWith
            [
              "backupStorageLocation sets credential"
              "(scope.forService velero).mkCR velero.out.crds.BackupStorageLocation"
            ]
            {
              backupStorageLocation.credential = {
                name = "other";
                key = "cloud";
              };
            };
        snapshot-credential = refusedWith [ "volumeSnapshotLocation sets credential" ] {
          volumeSnapshotLocation.credential.name = "other";
        };
        aws-plugin-off = refusedWith [ "awsPlugin.enabled is false" ] {
          awsPlugin.enabled = false;
        };
        node-agent-off-with-fs-backup = refusedWith [ "nodeAgent.enabled is false" ] {
          nodeAgent.enabled = false;
          volumePolicies = [
            {
              conditions.storageClass = [ "local" ];
              action.type = "fs-backup";
            }
          ];
        };
        csi-attributes-without-driver =
          refusedWith [ "conditions.csi.volumeAttributes without conditions.csi.driver" ]
            {
              volumePolicies = [
                {
                  conditions.csi.volumeAttributes.fsType = "ext4";
                  action.type = "skip";
                }
              ];
            };
        pod-labels-collision =
          refusedWith [ "nodeAgent.settings.podLabels sets app.kubernetes.io/component" ]
            {
              nodeAgent.settings.podLabels."app.kubernetes.io/component" = "mine";
            };
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
    failed == [ ] || throw "velero refusals without the expected message: ${toString failed}";

  # Each case differs from a building cluster by one setting that the build
  # refuses with a throw: an image of another minor release, a missing or
  # misnamed repository Secret, a flag or an env var the package owns, and
  # an s3Url beside an objectStorage dependency.
  velero-build-refusals =
    let
      cases = {
        control = !(builds (mkVelero { }));
        control-with-store =
          !(builds (mkVelero {
            withStore = true;
          }));
        image-of-another-release = builds (mkVelero {
          config.image.tag = "v1.17.1";
        });
        no-repository-secret = builds (mkVelero {
          repository = null;
        });
        misnamed-repository-secret = builds (mkVelero {
          repository = "other";
        });
        owned-flag = builds (mkVelero {
          config.server.extraArgs = [ "--features=EnableCSI" ];
        });
        owned-env = builds (mkVelero {
          config.nodeAgent.env.NODE_NAME = "node";
        });
        owned-key-pair-env = builds (mkVelero {
          cloud = awsKeyPair;
          config.server.env.AWS_ACCESS_KEY_ID = "id";
        });
        file-and-key-pair = builds (mkVelero {
          cloud = awsKeyPair // {
            cloud = "[default]";
          };
        });
        no-credentials-key = builds (mkVelero {
          cloud.other = "x";
        });
        s3-url-beside-store = builds (mkVelero {
          withStore = true;
          config.backupStorageLocation.config.s3Url = "https://s3.example.com";
        });
      };
      wrong = lib.attrNames (lib.filterAttrs (_: bad: bad) cases);
    in
    wrong == [ ] || throw "velero build refusals: these cases did not behave: ${toString wrong}";

  # With the key pair form, the server and node-agent read the pair from the
  # cloud Secret as environment variables, mount no credentials file, and
  # the locations name no credential.
  velero-key-pair-credentials =
    let
      cluster = mkVelero {
        cloud = awsKeyPair;
        config.volumeSnapshotLocation = {
          provider = "velero.io/aws";
          config.region = "gra";
        };
      };
      ms = manifests cluster;
      specOf = kind: n: (byName n (ofKind kind ms)).spec.template.spec;
      envNames = c: map (e: e.name) c.env;
      keyRefOf = c: n: (lib.findFirst (e: e.name == n) { } c.env).valueFrom.secretKeyRef or null;
      checks =
        lib.concatMap
          (
            { kind, n }:
            let
              spec = specOf kind n;
              c = builtins.head spec.containers;
            in
            [
              {
                name = "${n}-key-id";
                ok =
                  keyRefOf c "AWS_ACCESS_KEY_ID" == {
                    name = "cloud";
                    key = "AWS_ACCESS_KEY_ID";
                  };
              }
              {
                name = "${n}-secret-key";
                ok =
                  keyRefOf c "AWS_SECRET_ACCESS_KEY" == {
                    name = "cloud";
                    key = "AWS_SECRET_ACCESS_KEY";
                  };
              }
              {
                name = "${n}-no-file-env";
                ok = !(builtins.elem "AWS_SHARED_CREDENTIALS_FILE" (envNames c));
              }
              {
                name = "${n}-no-file-volume";
                ok = !(builtins.any (v: v.name == "cloud-credentials") spec.volumes);
              }
            ]
          )
          [
            {
              kind = "Deployment";
              n = "velero";
            }
            {
              kind = "DaemonSet";
              n = "node-agent";
            }
          ];
      locations = ofKind "BackupStorageLocation" ms ++ ofKind "VolumeSnapshotLocation" ms;
      failed =
        map (c: c.name) (builtins.filter (c: !c.ok) checks)
        ++ lib.optional (builtins.length locations != 2) "location-count"
        ++ lib.optional (builtins.any (l: l.spec ? credential) locations) "location-credential";
    in
    failed == [ ] || throw "velero key pair credentials: these checks failed: ${toString failed}";

  # `server.annotations` and `nodeAgent.annotations` land on the workloads'
  # own metadata, where a controller such as Reloader reads them.
  velero-workload-annotations =
    let
      ms = manifests (mkVelero {
        config = {
          server.annotations.a = "server";
          nodeAgent.annotations.a = "node-agent";
        };
      });
      annotationOf = kind: n: (byName n (ofKind kind ms)).metadata.annotations.a or null;
    in
    (
      annotationOf "Deployment" "velero" == "server"
      && annotationOf "DaemonSet" "node-agent" == "node-agent"
    )
    || throw "velero workload annotations: server ${toString (annotationOf "Deployment" "velero")}, node-agent ${toString (annotationOf "DaemonSet" "node-agent")}";

  # With node-agent off, no repository Secret is needed; an unowned env var
  # reaches the container.
  velero-optional-parts =
    let
      cluster = mkVelero {
        repository = null;
        config = {
          nodeAgent.enabled = false;
          server.env.HTTPS_PROXY = "http://proxy:3128";
        };
      };
      server = byName "velero" (ofKind "Deployment" (manifests cluster));
      env = (builtins.head server.spec.template.spec.containers).env;
    in
    builtins.any (e: e.name == "HTTPS_PROXY" && e.value == "http://proxy:3128") env
    || throw "velero with node-agent off: env ${builtins.toJSON env}";

  # A schedule on the default location reaches it through storageLocation,
  # so the package adds no `requires` entry that Kix reports as redundant.
  velero-schedule-requires-no-warning =
    let
      cluster = mkVelero { config.schedules.nightly.schedule = "@daily"; };
      warnings = cluster.instances.velero.velero._diagnostics.warnings;
    in
    (builds cluster && !(builtins.any (lib.hasInfix "already references") warnings))
    || throw "velero schedule warnings: ${builtins.toJSON warnings}";

  # Under network policy, a store outside the cluster gets the
  # velero-external-store policy over every pod of the instance; an
  # objectStorage dependency replaces it with the location's operand
  # policies.
  velero-external-store-policy =
    let
      names = cluster: map (m: m.metadata.name) (ofKind "CiliumNetworkPolicy" (manifests cluster));
      external = names (mkVelero {
        netpol = true;
      });
      inCluster = names (mkVelero {
        netpol = true;
        withStore = true;
      });
    in
    (
      builtins.elem "velero-external-store" external
      && !(builtins.elem "velero-external-store" inCluster)
      && builtins.elem "velero-backupstoragelocation-default-egress" inCluster
    )
    || throw "velero external store policy: without a store ${builtins.toJSON external}, with one ${builtins.toJSON inCluster}";

  # Each schedule's VeleroBackupMissing threshold is its metrics.maxBackupAge
  # entry, else kix.schedules.staleAfter of its cron line. An age up to 6d
  # reads the counters over that window; a longer one compares the
  # last-success timestamp. Both rules aggregate by namespace and schedule.
  velero-backup-alerts =
    let
      cluster = mkVelero {
        withPrometheus = true;
        config = {
          schedules = {
            daily.schedule = "CRON_TZ=UTC 0 2 * * *";
            frequent.schedule = "@every 6h";
            weekly.schedule = "0 3 * * 0";
            monthly.schedule = "0 2 1 * *";
          };
          metrics.maxBackupAge.monthly = "5d";
        };
      };
      rules = alertRulesOf "PrometheusRule" "velero" (manifests cluster);
      missing = rules.VeleroBackupMissing.expr;
      failed = rules.VeleroBackupFailed.expr;
      sel = schedule: ''namespace="velero",service="velero",schedule="${schedule}"'';
      counterForm =
        schedule: age:
        lib.hasInfix "velero_backup_attempt_total{${sel schedule}} offset ${age})" missing
        && lib.hasInfix "increase(velero_backup_success_total{${sel schedule}}[${age}])" missing;
      checks = {
        daily-derived = counterForm "daily" "50h";
        every-derived = counterForm "frequent" "14h";
        override = counterForm "monthly" "5d";
        weekly-timestamp = lib.hasInfix "time() - max by (namespace, schedule) (velero_backup_last_successful_timestamp{${sel "weekly"}}) > 1216800" missing;
        weekly-no-counter = !(lib.hasInfix "velero_backup_attempt_total{${sel "weekly"}}" missing);
        missing-keeps-namespace = !(lib.hasInfix "by (schedule)" missing);
        failed-keeps-namespace = lib.hasPrefix "sum by (namespace, schedule) (" failed;
        # Schedules the package does not render (out.mkSchedule) share
        # metrics.otherSchedulesMaxAge, so the rule renders with no
        # `schedules` too.
        others-exclude-declared = lib.hasInfix ''schedule!="",schedule!~"daily|frequent|monthly|weekly"} offset 50h'' missing;
        no-schedules-still-covers-others =
          let
            r = alertRulesOf "PrometheusRule" "velero" (
              manifests (mkVelero {
                withPrometheus = true;
              })
            );
          in
          r ? VeleroBackupMissing && lib.hasInfix ''schedule!=""} offset 50h'' r.VeleroBackupMissing.expr;
      };
      failedChecks = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
    in
    failedChecks == [ ]
    || throw "velero backup alerts: ${toString failedChecks}: ${
      builtins.toJSON { inherit missing failed; }
    }";

  # metrics.maxBackupAge refuses a key that names no schedule. A schedule
  # whose period cannot be read and has no entry fails the build while the
  # alerts render; with an entry, or without a prometheus dependency, it
  # builds.
  velero-backup-age-refusals =
    let
      unreadable = {
        schedules.monthly.schedule = "0 2 1 * *";
      };
      cases = {
        unknown-key =
          refusedWith
            [
              "metrics.maxBackupAge names nightly, which is not a schedule in schedules"
              "Its keys are schedule names: daily."
            ]
            {
              schedules.daily.schedule = "@daily";
              metrics.maxBackupAge.nightly = "50h";
            };
        unreadable-refused =
          !(builds (mkVelero {
            withPrometheus = true;
            config = unreadable;
          }));
        unreadable-with-entry = builds (mkVelero {
          withPrometheus = true;
          config = unreadable // {
            metrics.maxBackupAge.monthly = "64d";
          };
        });
        unreadable-without-alerts = builds (mkVelero {
          config = unreadable;
        });
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
    failed == [ ] || throw "velero backup age refusals: these cases did not behave: ${toString failed}";
}

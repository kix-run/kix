# Evaluates every package under kix/packages/ in a synthetic kind cluster
# of its own, so a package that no cluster names still runs through the
# builders, the validators and the scorecard.
#
# Each package becomes one instance in a namespace named after it, with the
# catalog as `availablePackages` so its dependencies are auto-instantiated.
# Forcing `rawManifests` forces the cluster's diagnostics and cross-resource
# checks first (`eval/cluster.nix`), the PackageInstance wiring is validated
# as `mkFlake` validates a real cluster's, and `scorecard.maxSeverity = "error"`
# matches the cap `clusters/flake.nix` and `ludo/flake.nix` set. Nothing is
# built except the Helm template derivations that chart packages read at
# evaluation time.
#
# `knownFailures` lists the error-severity scorecard rules a package is known
# to fail. Its cluster downgrades those rules to warnings so the rest of the
# package is still checked, and the check fails when a listed rule produces
# no finding, so an entry is removed once the package is fixed.
#
# Each cluster uses a clusterDomain other than cluster.local, so the
# `architecture.clusterDomainLiteral` rule sees addresses a package spells
# out instead of deriving. Two static checks cover what never renders: the package's source
# must not contain `cluster.local` outside comments, and `meta.version`
# must parse as a version (kix/lib/core/version.nix).
# `sourceDomainLiteralExceptions` and `versionExceptions` list the packages
# known to fail them; like `knownFailures`, a listed package that passes
# fails the check until its entry is removed.
#
# Every package's options must satisfy the option contract
# (kix/lib/eval/options.nix). Instance evaluation does not check it, so
# this file is where it is enforced: once per package and availability
# level (`kix.checkPackageOptions`), before any synthetic cluster is
# evaluated.
#
# Every package is evaluated twice: on the kind flavour alone (availability
# "none") and with three availability zones declared ("zone"). Replica
# counts depend on the level, and a builder ceiling (`availability.max` on
# one workload) can leave them level-dependent, so a package can pass at
# "none" and fail the replica guard under a `none` ceiling at "zone".

{ kix, lib }:

let
  piChecks = import ./pi-checks.nix { inherit lib; };
  versions = import ./lib/core/version.nix { inherit lib; };

  # The clusterDomain of every synthetic cluster.
  evalClusterDomain = "eval.kix.test";

  packages =
    let
      entries = builtins.readDir ./packages;
      dirs = lib.filterAttrs (_: type: type == "directory") entries;
    in
    # Every package cluster reads every package through `availablePackages`,
    # so a parse error would otherwise be reported under whichever package
    # happens to be evaluated first.
    lib.mapAttrs (
      name: _: builtins.addErrorContext "while loading kix/packages/${name}" (import ./packages/${name})
    ) dirs;

  # Auto-instantiation refuses a key that two shelf packages answer, so the
  # shelf keeps one implementation per contested required key: the
  # single-node clickhouse for `clickhouse`, and StackGres for `postgres`
  # and `database`. The packages left out are still evaluated as their own
  # instances.
  availablePackages = removeAttrs packages [
    "clickhouse-cluster"
    "cnpg-cluster"
    "cnpg-database"
  ];

  # A `credentials` secret for packages that read one.
  credentials = {
    package = packages.secret;
    aliases = [ "credentials" ];
    config.stringData = {
      username = "user";
      password = "password";
      host = "host";
      port = "5432";
    };
  };

  # A claim for packages that take a `storage` dependency. Its alias comes
  # from the package's `defaultAliases`.
  storage = {
    package = packages.persistent-volume-claim;
    config.size = "1Gi";
  };

  # A `valkeyPassword` secret for packages that connect to valkey.
  valkeyPassword = {
    package = packages.secret;
    aliases = [ "valkeyPassword" ];
    config.stringData.password = "password";
  };

  # Error-severity scorecard rules each package fails, with the file that
  # records why. A housekeeping file may cover several packages.
  knownFailures = { };

  # What a package needs beyond its defaults. `config` is the instance
  # config, `instances` are added to the package's namespace, and `module`
  # is a cluster module that takes the namespace name.
  settings = {
    arc-runner-set = {
      config = {
        githubConfigUrl = "https://github.com/example/example";
        maxRunners = 2;
      };
      instances.github-config = {
        package = packages.secret-ref;
        aliases = [ "githubConfigSecret" ];
        config.keys = [ "github_token" ];
      };
    };
    # The HorizontalPodAutoscaler scales on CPU, which needs a metricsApi
    # provider.
    caddy = {
      module = _: {
        cluster.roles.loadBalancer = {
          binding = "exclusive";
          provider = "test";
        };
      };
      instances.metrics-server.package = packages.metrics-server;
    };
    cilium.module = _: {
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
    };
    clickhouse.instances = { inherit credentials storage; };
    clickhouse-cluster.instances = { inherit credentials; };
    clickhouse-database = {
      config.password = "password";
      instances = { inherit credentials storage; };
    };
    clickhouse-keeper.instances = { inherit credentials; };
    clickhouse-logs.instances = {
      inherit credentials storage;
      clickhouse-database = {
        package = packages.clickhouse-database;
        config.password = "password";
      };
    };
    clickhouse-operator.instances = { inherit credentials; };
    cloudflared.config.token = "eval-only";
    # A Prometheus provider, so the PodMonitor is built.
    cnpg-cluster.instances.prometheus-operator.package = packages.prometheus-operator;
    # cnpg-cluster is off the shelf, so the database's cluster is declared.
    cnpg-database = {
      config = {
        password = "password";
        extensions = [ "citext" ];
      };
      instances.postgres.package = packages.cnpg-cluster;
    };
    # cnpg-cluster is off the shelf, so the pooled cluster is declared, and
    # a Prometheus provider, so the PodMonitor is built.
    cnpg-pooler.instances = {
      postgres.package = packages.cnpg-cluster;
      prometheus-operator.package = packages.prometheus-operator;
    };
    cluster-issuer.config.spec.selfSigned = { };
    # A real Prometheus provider, so the ServiceMonitor, the alert rules,
    # and the Service's metrics port are built against its builders.
    coredns = {
      config.clusterIP = "10.96.0.53";
      instances.prometheus-operator.package = packages.prometheus-operator;
    };
    external-dns = {
      config = {
        provider = "cloudflare";
        policy = "upsert-only";
        txtOwnerId = "package-eval";
        secretEnv.CF_API_TOKEN = "api-token";
      };
      instances.provider-credentials = {
        package = packages.secret;
        aliases = [ "providerCredentials" ];
        config.stringData.api-token = "token";
      };
    };
    filebrowser.instances = { inherit storage; };
    firezone.config = {
      domain = "firezone.example.com";
      admin = {
        email = "admin@example.com";
        password = "password";
      };
      wireguard.privateKey = "key";
      # The three salts are optional; clusters/test-immich.nix sets them.
      secrets = {
        guardianSecretKey = "guardian";
        secretKeyBase = "base";
        databaseEncryptionKey = "encryption";
      };
    };
    # The administrator's login, and a Prometheus provider, so the
    # ServiceMonitor is built.
    grafana.instances = {
      grafana-admin = {
        package = packages.secret;
        aliases = [ "grafanaAdmin" ];
        config.stringData = {
          admin-user = "admin";
          admin-password = "password";
        };
      };
      prometheus-operator.package = packages.prometheus-operator;
    };
    harbor = {
      instances = {
        inherit storage;
        valkey-password = valkeyPassword;
        database = {
          package = packages.stackgres-database;
          config.password = "password";
        };
        harbor-secrets = {
          package = packages.secret;
          aliases = [ "harborSecrets" ];
          config.stringData = {
            adminPassword = "admin";
            secretKey = "0123456789abcdef";
            coreSecret = "core";
            jobserviceSecret = "jobservice";
            csrfKey = "0123456789abcdef0123456789abcdef";
            registryHttpSecret = "registry-http";
            registryPassword = "registry";
            tokenPrivateKey = "key";
          };
        };
      };
      config.externalURL = "https://harbor.example.com";
    };
    # A Prometheus provider, so the metrics ports and the ServiceMonitor are
    # built.
    immich.instances = {
      inherit storage;
      valkey-password = valkeyPassword;
      database = {
        package = packages.stackgres-database;
        config.password = "password";
      };
      prometheus-operator.package = packages.prometheus-operator;
    };
    # Nothing routes to the instance here, so the URL comes from
    # env.KC_HOSTNAME. A Prometheus provider, so the metrics port and the
    # ServiceMonitor are built.
    keycloak = {
      config.env.KC_HOSTNAME = "https://auth.example.com";
      instances = {
        prometheus-operator.package = packages.prometheus-operator;
        database = {
          package = packages.stackgres-database;
          config.password = "password";
        };
        bootstrap-admin = {
          package = packages.secret;
          aliases = [ "bootstrapAdmin" ];
          config.stringData = {
            username = "admin";
            password = "password";
          };
        };
      };
    };
    loki.instances = { inherit storage; };
    # loki-logs auto-instantiates loki, which needs a claim.
    loki-logs.instances = { inherit storage; };
    # A class, a pool, and a Prometheus provider, so the StorageClass, the
    # DiskPool and its CRD reference, and the io-engine metrics Service,
    # ServiceMonitor, and alerts are built.
    mayastor = {
      config = {
        storageClasses.mayastor-1.parameters.repl = "1";
        diskPools.pool-1 = {
          node = "node-1";
          disks = [ "/dev/disk/by-id/example" ];
        };
      };
      instances.prometheus-operator.package = packages.prometheus-operator;
    };
    metabase.instances = {
      database = {
        package = packages.stackgres-database;
        config.password = "password";
      };
      encryption-key = {
        package = packages.secret;
        aliases = [ "encryptionKey" ];
        config.stringData.key = "0123456789abcdef";
      };
    };
    # metrics.enabled with a prometheus provider renders the ServiceMonitor
    # and N8N_METRICS.
    n8n = {
      config.metrics.enabled = true;
      instances = {
        prometheus-operator.package = packages.prometheus-operator;
        valkey-password = valkeyPassword;
        database = {
          package = packages.stackgres-database;
          config.password = "password";
        };
        n8n-encryption-key = {
          package = packages.secret;
          aliases = [ "encryptionKey" ];
          config.stringData.key = "0123456789abcdef0123456789abcdef";
        };
      };
    };
    persistent-volume-claim.config.size = "1Gi";
    priority-class.config.value = 1000;
    secret.config.stringData.password = "password";
    secret-echo.instances = { inherit credentials; };
    secret-ref.config.keys = [ "password" ];
    # A Prometheus provider, so the metrics Service and the ServiceMonitor
    # are built.
    snapshot-controller.instances.prometheus-operator.package = packages.prometheus-operator;
    # Backups to an object storage, so the SGObjectStorage reference, the
    # backups entries, and archive_timeout are built; a pooler and a script,
    # so the SGPoolingConfig and the SGScript are built.
    stackgres-cluster = {
      config = {
        backups = [ { cronSchedule = "0 1 * * *"; } ];
        pooling = { };
        scripts = [
          {
            name = "init";
            script = "SELECT 1";
          }
        ];
      };
      instances = {
        s3-credentials = {
          package = packages.secret;
          aliases = [ "storageCredentials" ];
          config.stringData = {
            accessKeyId = "id";
            secretAccessKey = "key";
          };
        };
        stackgres-object-storage = {
          package = packages.stackgres-object-storage;
          config = {
            type = "s3Compatible";
            bucket = "backups";
          };
        };
      };
    };
    stackgres-database.config.password = "password";
    stackgres-object-storage = {
      config = {
        type = "s3Compatible";
        bucket = "backups";
      };
      instances.s3-credentials = {
        package = packages.secret;
        aliases = [ "storageCredentials" ];
        config.stringData = {
          accessKeyId = "id";
          secretAccessKey = "key";
        };
      };
    };
    # No default annotation: the kind flavour already has a default class.
    storage-classes.config.classes.local-path-retain = {
      provisioner = "rancher.io/local-path";
      reclaimPolicy = "Retain";
      volumeBindingMode = "WaitForFirstConsumer";
    };
    tailscale.instances.oauth-credentials = {
      package = packages.secret;
      aliases = [ "oauthCredentials" ];
      config.stringData = {
        client_id = "id";
        client_secret = "secret";
      };
    };
    valkey.instances.valkey-password = valkeyPassword;
    # Nothing routes to the instance here, so the URL comes from `domain`.
    vaultwarden = {
      instances = {
        inherit storage;
        database = {
          package = packages.stackgres-database;
          config.password = "password";
        };
      };
      config.domain = "https://vault.example.com";
    };
    velero = {
      config.backupStorageLocation.objectStorage.bucket = "backups";
      instances = {
        velero-cloud-credentials = {
          package = packages.secret;
          aliases = [ "cloudCredentials" ];
          config.stringData.cloud = "[default]\naws_access_key_id = key\naws_secret_access_key = secret\n";
        };
        velero-repo-credentials = {
          package = packages.secret;
          aliases = [ "repositoryPassword" ];
          config.stringData.repository-password = "password";
        };
      };
    };
    # Every node option set, and a snapshot controller so the snapshotter
    # sidecar and the VolumeSnapshotClass are built.
    zfs-localpv = {
      config = {
        storageClasses.zfs.parameters.poolname = "tank/k8s";
        volumeSnapshotClasses.zfs = { };
        node = {
          kubeletDir = "/var/lib/k0s/kubelet";
          encrKeysDir = "/home/keys";
          zfsBin = "/run/current-system/sw/bin/zfs";
          nodeSelector."example.com/zfs-pool" = "true";
          tolerations = [
            {
              key = "example.com/storage";
              operator = "Exists";
              effect = "NoSchedule";
            }
          ];
        };
      };
      instances.snapshot-controller.package = packages.snapshot-controller;
    };
  };

  # Packages whose source writes cluster.local outside a comment.
  sourceDomainLiteralExceptions = [ ];

  # Packages whose meta.version is not a version, with the reason.
  versionExceptions = { };

  # Packages that cannot be evaluated on their own, with the reason.
  skip = { };

  # Every `.nix` file of a package outside `crds/`, scanned line by line. A
  # line whose first non-space character is `#` is skipped. Two limits: a
  # trailing comment (`x = 1; # svc.cluster.local`) is a hit, and a `#` line
  # inside a `''` string is skipped (the clusterDomainLiteral rule covers
  # strings that render).
  sourceDomainLiterals =
    name:
    let
      dir = ./packages + "/${name}";
      nixFiles =
        rel:
        lib.concatLists (
          lib.mapAttrsToList (
            entry: type:
            let
              path = if rel == "" then entry else "${rel}/${entry}";
            in
            if type == "directory" && !(rel == "" && entry == "crds") then
              nixFiles path
            else if type == "regular" && lib.hasSuffix ".nix" entry then
              [ path ]
            else
              [ ]
          ) (builtins.readDir (if rel == "" then dir else dir + "/${rel}"))
        );
      hitsIn =
        file:
        lib.concatLists (
          lib.imap1 (
            i: line:
            lib.optional (
              !(lib.hasPrefix "#" (lib.trimWith { start = true; } line)) && lib.hasInfix "cluster.local" line
            ) "kix/packages/${name}/${file}:${toString i}"
          ) (lib.splitString "\n" (builtins.readFile (dir + "/${file}")))
        );
    in
    builtins.concatMap hitsIn (nixFiles "");

  checkSource =
    name:
    let
      hits = sourceDomainLiterals name;
      excepted = builtins.elem name sourceDomainLiteralExceptions;
    in
    if excepted then
      lib.assertMsg (hits != [ ])
        "${name} no longer writes cluster.local in its source; remove it from sourceDomainLiteralExceptions in kix/package-eval.nix"
    else
      lib.assertMsg (hits == [ ]) (
        lib.concatMapStringsSep "\n" (
          h:
          "${h} contains \"cluster.local\". Build in-cluster addresses from a Service's out.fqdn or out.url, or read clusterConfig.clusterDomain; in option text write <clusterDomain>."
        ) hits
      );

  checkVersion =
    name: package:
    let
      version =
        (kix.peekPackageMeta {
          inherit package;
          inherit (kix) kixlib;
        }).version or null;
      ok = version == null || versions.isVersion version;
    in
    if versionExceptions ? ${name} then
      lib.assertMsg (!ok)
        "kix/packages/${name}: meta.version ${builtins.toJSON version} is a version now; remove it from versionExceptions in kix/package-eval.nix and update ${versionExceptions.${name}}"
    else
      lib.assertMsg ok "kix/packages/${name}: meta.version ${builtins.toJSON version} is not a version. Use the upstream release the package targets, e.g. \"1.19.6\" or \"v1.19.6\".";

  checkOptions =
    name: package:
    kix.checkPackageOptions {
      inherit package;
      who = "kix/packages/${name}";
      scope = {
        instanceName = name;
        namespaceName = name;
      };
    };

  # True when every package in `packages` passes the option contract;
  # throws with the violations otherwise.
  checkOptionContracts = packages: builtins.deepSeq (lib.mapAttrsToList checkOptions packages) true;

  # The availability levels every package is evaluated at, as cluster
  # modules added after the kind flavour.
  levelModules = {
    none = { };
    zone = {
      cluster.capabilities = {
        multiNode = true;
        availabilityZones = [
          "a"
          "b"
          "c"
        ];
      };
    };
  };

  evaluatePackage =
    level: name: package:
    let
      s = settings.${name} or { };
      failures = knownFailures.${name} or [ ];
      cluster = kix.buildCluster {
        name = "package-${name}";
        modules = [
          kix.flavors.kind
          levelModules.${level}
          {
            clusterDomain = evalClusterDomain;
            scorecard.maxSeverity = "error";
            # By rule rather than by namespace, because a cluster-level rule
            # such as `architecture.monitorSelectorMatchesService` is not
            # matched by a namespace override. The cluster holds only this
            # package and the dependencies it auto-instantiates.
            scorecard.ruleOverrides.byRule = lib.listToAttrs (
              map (f: lib.nameValuePair f.rule { severity = "warning"; }) failures
            );
            inherit availablePackages;
            namespaces.${name} = { };
            instances.${name} = {
              ${name} = {
                inherit package;
                config = s.config or { };
              };
            }
            // s.instances or { };
          }
          ((s.module or (_: { })) name)
        ];
      };
    in
    assert checkSource name;
    assert checkVersion name package;
    builtins.addErrorContext
      "while evaluating kix/packages/${name} in its synthetic cluster at availability \"${level}\""
      (
        builtins.deepSeq cluster.rawManifests (
          builtins.seq (piChecks.validatePIWiring "package-${name}" cluster) (
            builtins.deepSeq cluster.scorecardReport (
              builtins.foldl' (
                acc: f:
                assert lib.assertMsg (cluster.scorecardReport.summary.byRule ? ${f.rule})
                  "${name} no longer fails ${f.rule}; remove it from knownFailures in kix/package-eval.nix ${
                    if lib.hasPrefix "housekeeping/" f.reason then
                      "and update or delete ${f.reason}"
                    else
                      "and the exception described in ${f.reason}"
                  }";
                acc
              ) name failures
            )
          )
        )
      );

  strayKeys = lib.filter (key: !(packages ? ${key})) (
    builtins.attrNames settings
    ++ builtins.attrNames knownFailures
    ++ builtins.attrNames skip
    ++ sourceDomainLiteralExceptions
    ++ builtins.attrNames versionExceptions
  );

  levels = builtins.attrNames levelModules;

  evaluated = lib.concatMap (
    level: lib.mapAttrsToList (evaluatePackage level) (removeAttrs packages (builtins.attrNames skip))
  ) levels;
in
{
  inherit
    packages
    knownFailures
    skip
    sourceDomainLiteralExceptions
    versionExceptions
    levels
    ;

  # One package at one level ("none" or "zone"), for finding the failure
  # when `names` throws.
  evaluate = level: name: evaluatePackage level name packages.${name};

  # The option contract of one package: null when its options pass, a
  # throw listing each violation otherwise.
  checkOptionContract = name: checkOptions name packages.${name};

  inherit checkOptionContracts;

  # Forcing this checks the option contract of every package, then
  # evaluates every package that is not skipped, at every level. Each
  # package name appears once per level.
  names =
    assert lib.assertMsg (strayKeys == [ ])
      "kix/package-eval.nix: `settings`, `knownFailures`, `skip`, `sourceDomainLiteralExceptions` or `versionExceptions` names ${lib.concatStringsSep ", " strayKeys}, which is not a directory under kix/packages/";
    assert checkOptionContracts packages;
    builtins.deepSeq evaluated evaluated;
}

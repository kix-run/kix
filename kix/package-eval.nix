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

{ kix, lib }:

let
  piChecks = import ./pi-checks.nix { inherit lib; };

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

  # kube-prometheus-stack claims the `prometheus` and `prometheusOperator`
  # aliases that prometheus-operator also claims. Auto-instantiation takes
  # the alphabetically first package for a shared key, so leaving it in
  # would give every monitoring consumer the Helm stack.
  availablePackages = removeAttrs packages [ "kube-prometheus-stack" ];

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

  nonRoot = {
    rule = "security.nonRoot";
    reason = "housekeeping/2026-09-27-five-packages-fail-non-root-rule.md";
  };
  lokiLabels = {
    rule = "architecture.distinctSameKindLabels";
    reason = "housekeeping/2026-09-27-loki-chart-services-share-labels.md";
  };

  # Error-severity scorecard rules each package fails, with the file that
  # records why. A housekeeping file may cover several packages.
  knownFailures = {
    caddy = [ nonRoot ];
    clickhouse-logs = [
      {
        rule = "security.nonRoot";
        # The Vector agent runs as root to read pod logs.
        reason = "kix/packages/clickhouse-logs/default.nix";
      }
    ];
    dns-exporter = [ nonRoot ];
    event-logger = [ nonRoot ];
    loki = [ lokiLabels ];
    metabase = [ nonRoot ];
    # The labels finding comes from the auto-instantiated loki.
    promtail = [ lokiLabels ];
    redis = [
      {
        rule = "architecture.distinctSameKindLabels";
        reason = "housekeeping/2026-09-27-redis-services-share-labels.md";
      }
    ];
    smartctl-exporter = [
      {
        rule = "architecture.monitorSelectorMatchesService";
        reason = "housekeeping/2026-09-27-smartctl-exporter-monitor-selects-helm-labels.md";
      }
    ];
    tailscale = [ nonRoot ];
  };

  # What a package needs beyond its defaults. `config` is the instance
  # config, `instances` are added to the package's namespace, and `module`
  # is a cluster module that takes the namespace name.
  settings = {
    arc-runner-set.config.values = {
      githubConfigUrl = "https://github.com/example/example";
      githubConfigSecret = "arc-github";
      controllerServiceAccount = {
        name = "arc-gha-rs-controller";
        namespace = "arc-systems";
      };
    };
    caddy.module = _: {
      cluster.roles.loadBalancer = {
        binding = "exclusive";
        provider = "test";
      };
    };
    cilium.module = _: {
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
    };
    cilium-rke2 = {
      config = {
        internalCidr = "10.44.0.0/14";
        clusterNodes.node1 = {
          role = "server";
          ip = "192.0.2.1";
          hostNumber = 1;
        };
      };
      module = _: {
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
      };
    };
    clickhouse.instances = { inherit credentials; };
    clickhouse-cluster.instances = { inherit credentials; };
    clickhouse-database = {
      config.password = "password";
      instances = { inherit credentials; };
    };
    clickhouse-keeper.instances = { inherit credentials; };
    clickhouse-logs.instances = {
      inherit credentials;
      clickhouse-database = {
        package = packages.clickhouse-database;
        config.password = "password";
      };
    };
    clickhouse-operator.instances = { inherit credentials; };
    firezone.config = {
      domain = "firezone.example.com";
      admin = {
        email = "admin@example.com";
        password = "password";
      };
      wireguard.privateKey = "key";
      secrets = {
        guardianSecretKey = "guardian";
        secretKeyBase = "base";
        databaseEncryptionKey = "encryption";
        liveViewSigningSalt = "live-view";
        cookieSigningSalt = "cookie";
        cookieEncryptionSalt = "cookie-encryption";
      };
    };
    harbor = {
      instances.database = {
        package = packages.stackgres-database;
        config.password = "password";
      };
      config.externalURL = "https://harbor.example.com";
      config.secrets.values = {
        adminPassword = "admin";
        secretKey = "0123456789abcdef";
        coreSecret = "core";
        jobserviceSecret = "jobservice";
        csrfKey = "0123456789abcdef0123456789abcdef";
        registryHttpSecret = "registry-http";
        registryPassword = "registry";
        registryHtpasswd = "harbor_registry_user:hash";
        tokenPrivateKey = "key";
      };
    };
    immich.instances.database = {
      package = packages.stackgres-database;
      config.password = "password";
    };
    posthog-proxy.config.host = "posthog.example.com";
    priority-classes.config.classes.default.value = 1000;
    python-app.config.backend.image = {
      repository = "ghcr.io/example/python-app";
      tag = "1.0.0";
    };
    # housekeeping/2026-09-27-promtail-needs-an-undeclared-priority-class.md
    promtail.instances.priority-classes = {
      package = packages.priority-classes;
      config.classes.monitoring-loki.value = 1000;
    };
    secret.config.stringData.password = "password";
    secret-echo.instances = { inherit credentials; };
    secret-ref.config.keys = [ "password" ];
    stackgres-database.config.password = "password";
    stackgres-object-storage.config = {
      bucket = "backups";
      credentialsSecretName = "backup-credentials";
    };
  };

  # Packages that cannot be evaluated on their own, with the reason.
  skip = { };

  evaluatePackage =
    name: package:
    let
      s = settings.${name} or { };
      failures = knownFailures.${name} or [ ];
      cluster = kix.buildCluster {
        name = "package-${name}";
        modules = [
          kix.flavors.kind
          {
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
    builtins.addErrorContext "while evaluating kix/packages/${name} in its synthetic cluster" (
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
    builtins.attrNames settings ++ builtins.attrNames knownFailures ++ builtins.attrNames skip
  );

  evaluated = lib.mapAttrsToList evaluatePackage (removeAttrs packages (builtins.attrNames skip));
in
{
  inherit packages knownFailures skip;

  # One package, for finding the failure when `names` throws.
  evaluate = name: evaluatePackage name packages.${name};

  # Forcing this evaluates every package that is not skipped.
  names =
    assert lib.assertMsg (strayKeys == [ ])
      "kix/package-eval.nix: `settings`, `knownFailures` or `skip` names ${lib.concatStringsSep ", " strayKeys}, which is not a directory under kix/packages/";
    builtins.deepSeq evaluated evaluated;
}

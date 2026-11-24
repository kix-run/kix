# Evaluates every package under kix/packages/ in a synthetic kind cluster
# of its own, so a package that no cluster names still runs through the
# builders, the validators and the scorecard.
#
# Each package becomes one instance in a namespace named after it, with the
# catalog as `availablePackages` so its dependencies are auto-instantiated.
# Forcing `rawManifests` forces the cluster's diagnostics and cross-resource
# checks first (`eval/cluster.nix`), the PackageInstance wiring is validated
# as `mkFlake` validates a real cluster's, and `scorecard.maxSeverity = "error"`
# matches the cap the repository's `flake.nix` sets. Nothing is
# built. Only `kix` renders the charts that chart packages read, so plain
# `nix flake check` stops at the first one. The kix-cli test
# `flake_checks_evaluate_with_helm` evaluates this check through `kix`.
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
#
# A package whose default image tag names its `meta.version` must publish
# that version as `out.version` (`checkPublishedVersion`).
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

  byLevel = import ./packages/by-level.nix { inherit lib; };

  # Every package of both levels by name. Every package cluster reads every
  # package through `availablePackages`, experimental ones included.
  packages =
    let
      both = builtins.attrNames (builtins.intersectAttrs byLevel.stable byLevel.experimental);
    in
    assert lib.assertMsg (both == [ ])
      "kix/package-eval.nix: ${lib.concatStringsSep ", " both} is both a stable and an experimental package. Give the experimental rework a key of its own here.";
    byLevel.stable // byLevel.experimental;

  levelOf = name: if byLevel.stable ? ${name} then "stable" else "experimental";

  # The folder of a package, relative to the repository root.
  folderOf = name: "kix/packages/${levelOf name}/${name}";

  # Auto-instantiation refuses a key that two shelf packages answer, so the
  # shelf keeps one implementation per contested required key: the
  # single-node clickhouse for `clickhouse`, and StackGres for `postgres`
  # and `database`. The packages left out are still evaluated as their own
  # instances.
  #
  # Kix refuses to add a package that runs once per cluster, such as an
  # operator, beside its only consumer, so those entries name a namespace of
  # their own: the package's name.
  availablePackages =
    lib.mapAttrs
      (
        name: package:
        let
          meta = import ./lib/meta.nix { inherit lib; };
          packageMeta = kix.peekPackageMeta {
            inherit package;
            inherit (kix) kixlib;
          };
        in
        if
          meta.servesCluster {
            inherit packageMeta;
            context = "availablePackages.${name}";
          }
        then
          {
            inherit package;
            namespace = name;
          }
        else
          package
      )
      (
        removeAttrs packages [
          "clickhouse-cluster"
          "cnpg-cluster"
          "cnpg-database"
        ]
      );

  # The `password` secret of every database instance in its namespace, from
  # a SOPS file encrypted to the test-only key in clusters/dev-secrets.
  # Evaluation never decrypts it.
  dbPassword = {
    package = packages.secret;
    aliases = [ "password" ];
    config = {
      source = ./package-eval-password.sops.yaml;
      keys = [ "password" ];
    };
  };

  # The ClickHouse operator runs once per cluster, so the packages that need
  # it declare it in a namespace of its own, with its login.
  clickhouseOperator = {
    clickhouse-operator.package = packages.clickhouse-operator;
    inherit credentials;
  };

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

  # The admin login of a DB Operator DbInstance.
  dbAdminCredentials = {
    package = packages.secret;
    aliases = [ "adminCredentials" ];
    config.stringData = {
      username = "postgres";
      password = "password";
    };
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
      instances = {
        metrics-server.package = packages.metrics-server;
        caddyfile = {
          package = packages.secret;
          aliases = [ "caddyfile" ];
          config.stringData.Caddyfile = ":8080 {\n  respond /healthz 200\n}\n";
        };
      };
    };
    cilium.module = _: {
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
    };
    clickhouse.instances = { inherit credentials storage; };
    clickhouse-cluster = {
      instances = { inherit credentials; };
      module = _: { instances.clickhouse-operator = clickhouseOperator; };
    };
    clickhouse-database.instances = {
      inherit credentials storage;
      database-password = dbPassword;
    };
    clickhouse-keeper = {
      instances = { inherit credentials; };
      module = _: { instances.clickhouse-operator = clickhouseOperator; };
    };
    clickhouse-logs.instances = {
      inherit credentials storage;
      clickhouse-database.package = packages.clickhouse-database;
      database-password = dbPassword;
    };
    clickhouse-operator.instances = { inherit credentials; };
    cloudflared.instances.tunnel-token = {
      package = packages.secret;
      aliases = [ "tunnelToken" ];
      config.stringData.token = "eval-only";
    };
    # A Prometheus provider, so the PodMonitor is built.
    cnpg-cluster.instances.prometheus-operator.package = packages.prometheus-operator;
    # cnpg-cluster is off the shelf, so the database's cluster is declared.
    cnpg-database = {
      config.extensions = [ "citext" ];
      instances = {
        postgres.package = packages.cnpg-cluster;
        database-password = dbPassword;
      };
    };
    # cnpg-cluster is off the shelf, so the pooled cluster is declared, and
    # a Prometheus provider, so the PodMonitor is built.
    cnpg-pooler.instances = {
      postgres.package = packages.cnpg-cluster;
      prometheus-operator.package = packages.prometheus-operator;
    };
    # The DbInstance the database is created on serves the whole cluster,
    # so it is added from the catalog in a namespace of its own, and its
    # admin login is declared there.
    db-operator-database = {
      config = {
        extensions = [ "citext" ];
        templates.DATABASE_URL = "postgresql://{{ .Username }}:{{ .Password }}@{{ .Hostname }}:{{ .Port }}/{{ .Database }}";
      };
      module = _: { instances.db-operator-instance.admin-credentials = dbAdminCredentials; };
    };
    db-operator-instance.instances.admin-credentials = dbAdminCredentials;
    # CloudNativePG finds a plugin only in its own namespace, so the
    # operator is declared beside the plugin.
    cnpg-barman-cloud.instances.cnpg-operator.package = packages.cnpg-operator;
    # An issuer lives in cert-manager's namespace, so cert-manager is
    # declared beside it.
    cluster-issuer = {
      config.spec.selfSigned = { };
      instances.cert-manager.package = packages.cert-manager;
    };
    # A real Prometheus provider, so the ServiceMonitor, the alert rules,
    # and the Service's metrics port are built against its builders.
    coredns = {
      config.clusterIP = "10.96.0.53";
      instances.prometheus-operator.package = packages.prometheus-operator;
    };
    # A Gateway needs the Gateway API CRDs and the controller that serves it.
    envoy-gateway.instances = {
      gateway-api.package = packages.gateway-api;
      envoy-gateway-controller.package = packages.envoy-gateway-controller;
    };
    # A Gateway API implementation needs the Gateway API CRDs.
    envoy-gateway-controller.instances.gateway-api.package = packages.gateway-api;
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
    # The operator comes from the catalog through the externalSecrets
    # dependency.
    external-secret.config = {
      store.name = "vault";
      keys.password = "app/password";
    };
    # A rules file, so the rules ConfigMap and its mount are built, and a
    # Prometheus provider, so the metrics Service and the ServiceMonitor are
    # built.
    falco = {
      config.rules.custom = [
        {
          rule = "Package eval rule";
          desc = "A rule that exercises the rules ConfigMap.";
          condition = "evt.type = open and proc.name = never-matches";
          output = "Package eval rule (proc=%proc.name)";
          priority = "NOTICE";
        }
      ];
      instances.prometheus-operator.package = packages.prometheus-operator;
    };
    filebrowser.instances = { inherit storage; };
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
        database.package = packages.stackgres-database;
        database-password = dbPassword;
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
      database.package = packages.stackgres-database;
      database-password = dbPassword;
      prometheus-operator.package = packages.prometheus-operator;
    };
    # Nothing routes to the instance here, so the URL comes from
    # env.KC_HOSTNAME. A Prometheus provider, so the metrics port and the
    # ServiceMonitor are built.
    keycloak = {
      config.env.KC_HOSTNAME = "https://auth.example.com";
      instances = {
        prometheus-operator.package = packages.prometheus-operator;
        database.package = packages.stackgres-database;
        database-password = dbPassword;
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
      database.package = packages.stackgres-database;
      database-password = dbPassword;
      encryption-key = {
        package = packages.secret;
        aliases = [ "encryptionKey" ];
        config.stringData.key = "0123456789abcdef";
      };
    };
    # BASE_URL from env, since the synthetic cluster routes nothing.
    plausible = {
      config.env.BASE_URL = "https://plausible.example.org";
      instances = {
        inherit credentials storage;
        database.package = packages.stackgres-database;
        clickhouse-database.package = packages.clickhouse-database;
        # One `password` secret for both databases.
        database-password = dbPassword;
        secret-key-base = {
          package = packages.secret;
          aliases = [ "secretKeyBase" ];
          config.stringData.key = "0123456789abcdef0123456789abcdef";
        };
      };
    };
    # metrics.enabled with a prometheus provider renders the ServiceMonitor
    # and N8N_METRICS.
    n8n = {
      config.metrics.enabled = true;
      instances = {
        prometheus-operator.package = packages.prometheus-operator;
        valkey-password = valkeyPassword;
        database.package = packages.stackgres-database;
        database-password = dbPassword;
        n8n-encryption-key = {
          package = packages.secret;
          aliases = [ "encryptionKey" ];
          config.stringData.key = "0123456789abcdef0123456789abcdef";
        };
      };
    };
    # A provider outside the cluster and the client's secret.
    oidc-client = {
      config.realm = "main";
      instances = {
        oidcProvider.package = kix.mkImport {
          out = {
            issuerUrl = realm: "https://auth.example.com/realms/${realm}";
            endpoints = realm: {
              authorizationUrl = "https://auth.example.com/realms/${realm}/auth";
              tokenUrl = "https://auth.example.com/realms/${realm}/token";
              userinfoUrl = "https://auth.example.com/realms/${realm}/userinfo";
            };
          };
        };
        oidc-client-secret = {
          package = packages.secret;
          aliases = [ "oidcClient" ];
          config.stringData = {
            clientId = "app";
            clientSecret = "secret";
          };
        };
      };
    };
    # The login every client must use, and a Prometheus provider, so the
    # metrics Service, the ServiceMonitor, and the alerts are built. The
    # package refuses a mode that disagrees with the availability level, so
    # the instance is clustered wherever the cluster has several nodes:
    # standalone at "none", clustered at "zone".
    nats.module =
      name:
      { config, ... }:
      {
        instances.${name}.${name}.config.clustered = config.cluster.capabilities.multiNode or false;
      };
    nats.instances = {
      nats-auth = {
        package = packages.secret;
        aliases = [ "natsAuth" ];
        config.stringData = {
          username = "app";
          password = "password";
        };
      };
      prometheus-operator.package = packages.prometheus-operator;
    };
    # The static seal, the default, needs the key. A declared policy, role,
    # and engine give the reconcile Job data to apply.
    openbao = {
      instances.openbao-unseal = {
        package = packages.secret;
        aliases = [ "unsealKey" ];
        config.stringData.key = "0123456789abcdef0123456789abcdef";
      };
      config = {
        policies.app-read = ''path "secret/data/app/*" { capabilities = ["read"] }'';
        kubernetesAuth.roles.app = {
          bound_service_account_names = [ "app" ];
          bound_service_account_namespaces = [ "app" ];
          token_policies = [ "app-read" ];
        };
        secretsEngines.secret = {
          type = "kv";
          options.version = "2";
        };
      };
    };
    # The collector refuses to start without a pipeline, and the events
    # pipeline needs no dependency. A Prometheus provider, so the metrics
    # port and the ServiceMonitor are built.
    otel-collector = {
      config.events.enabled = true;
      instances.prometheus-operator.package = packages.prometheus-operator;
    };
    persistent-volume-claim.config.size = "1Gi";
    priority-class.config.value = 1000;
    # A Prometheus provider, so the PodMonitor is built, and a settings
    # entry, so additionalConfig is rendered.
    rabbitmq-cluster = {
      config.settings."vm_memory_high_watermark.relative" = "0.6";
      instances.prometheus-operator.package = packages.prometheus-operator;
    };
    # A Prometheus provider, so the metrics Service and the ServiceMonitor
    # are built.
    rabbitmq-operator.instances.prometheus-operator.package = packages.prometheus-operator;
    secret.config.stringData.password = "password";
    secret-ref.config.keys = [ "password" ];
    service-ref.config = {
      selector."app.kubernetes.io/name" = "old-db";
      ports = [ { port = 5432; } ];
    };
    # A Prometheus provider, so the metrics Service and the ServiceMonitor
    # are built.
    snapshot-controller.instances.prometheus-operator.package = packages.prometheus-operator;
    # The kind flavour declares one node and containerd's discard of
    # unpacked layers, which the package refuses.
    spegel.module = _: {
      cluster.capabilities.multiNode = true;
      cluster.containerd.discardUnpackedLayers = false;
    };
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
    stackgres-database.instances.database-password = dbPassword;
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
    # A Prometheus provider, so the ServiceMonitor is built.
    traefik.instances.gateway-api.package = packages.gateway-api;
    tempo.instances = {
      inherit storage;
      prometheus-operator.package = packages.prometheus-operator;
    };
    valkey.instances.valkey-password = valkeyPassword;
    # Nothing routes to the instance here, so the URL comes from `domain`.
    vaultwarden = {
      instances = {
        inherit storage;
        database.package = packages.stackgres-database;
        database-password = dbPassword;
      };
      config.domain = "https://vault.example.com";
    };
    # The operator needs the VolumeSnapshot API, which kind does not ship.
    volsync.instances.snapshot-controller.package = packages.snapshot-controller;
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
      dir = ./packages + "/${levelOf name}/${name}";
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
            ) "${folderOf name}/${file}:${toString i}"
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
        "${folderOf name}: meta.version ${builtins.toJSON version} is a version now; remove it from versionExceptions in kix/package-eval.nix and update ${versionExceptions.${name}}"
    else
      lib.assertMsg ok "${folderOf name}: meta.version ${builtins.toJSON version} is not a valid version string. Set meta.version to the default upstream release version or tag (for example, \"1.19.6\" or \"v1.19.6\"), or omit it when the package deploys no upstream software.";

  # Collect the image options of an instance's config: every attribute set
  # with a `repository` and a `tag`, up to three levels deep.
  imagesOf =
    depth: value:
    if !builtins.isAttrs value || value ? _type then
      [ ]
    else if value ? repository && value ? tag then
      [ value ]
    else if depth == 0 then
      [ ]
    else
      lib.concatMap (imagesOf (depth - 1)) (builtins.attrValues value);

  # Check that a package whose default image tag names its `meta.version`
  # publishes that version as `out.version`. The package reads it from the
  # image of its main software with `kix.image.version`, so an instance that
  # runs another image reports the version it runs.
  checkPublishedVersion =
    name: package: cluster:
    let
      metaVersion =
        (kix.peekPackageMeta {
          inherit package;
          inherit (kix) kixlib;
        }).version or null;
      instance = cluster.instances.${name}.${name};
      tagNamesVersion =
        image:
        let
          v = kix.image.version image;
        in
        v != null && versions.compare v metaVersion == 0;
      applies =
        metaVersion != null
        && versions.isVersion metaVersion
        && builtins.any tagNamesVersion (imagesOf 3 instance._meta.config);
      published = instance.out.version or null;
    in
    if !applies then
      true
    else if !(instance.out ? version) then
      throw "${folderOf name}: an image's default tag names meta.version ${metaVersion}, and the package publishes no out.version. Add `out.version = kix.image.version config.<image option>;` to `root`, reading the image of the main software."
    else
      lib.assertMsg (published != null && versions.compare published metaVersion == 0)
        "${folderOf name}: on its defaults the package publishes out.version ${builtins.toJSON published}, and meta.version is ${metaVersion}. Publish the full version of the main software's image.";

  checkOptions =
    name: package:
    kix.checkPackageOptions {
      inherit package;
      who = folderOf name;
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
      "while evaluating ${folderOf name} in its synthetic cluster at availability \"${level}\""
      (
        builtins.deepSeq cluster.rawManifests (
          builtins.seq (piChecks.validatePIWiring "package-${name}" cluster) (
            assert checkPublishedVersion name package cluster;
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
  # failure listing each violation otherwise.
  checkOptionContract = name: checkOptions name packages.${name};

  inherit checkOptionContracts;

  # Forcing this checks the option contract of every package, then
  # evaluates every package that is not skipped, at every level. Each
  # package name appears once per level.
  names =
    assert lib.assertMsg (strayKeys == [ ])
      "kix/package-eval.nix: `settings`, `knownFailures`, `skip`, `sourceDomainLiteralExceptions`, or `versionExceptions` names ${lib.concatStringsSep ", " strayKeys}, which is not a package folder under kix/packages/";
    assert checkOptionContracts packages;
    builtins.deepSeq evaluated evaluated;
}

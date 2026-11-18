# Altinity clickhouse-operator: configuration, Deployment, Service, RBAC.
#
# The pod runs two containers from two images of the same release. The
# operator reconciles ClickHouseInstallations and ClickHouseKeeperInstallations
# into StatefulSets, Services, ConfigMaps, and PodDisruptionBudgets. The
# metrics exporter answers one scrape with the ClickHouse metrics of every
# installation, which it collects by querying each server. Both read the same
# configuration tree under /etc/clickhouse-operator, so both get the same
# mounts.
#
# RBAC is transcribed from the upstream ClusterRole (chart 0.27.4,
# templates/generated/ClusterRole-clickhouse-operator-kube-system.yaml), with
# the custom resource rules derived from kinds.nix. It is cluster-wide: the
# operator watches every namespace (`watch.namespaces.include` below) unless
# `operatorConfig` narrows it, and narrowing what it watches does not narrow
# what it is allowed to do.

{
  self,
  config,
  scope,
  lib,
  kix,
  credentials,
  ...
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;

  labels = {
    "app.kubernetes.io/name" = "clickhouse-operator";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/part-of" = "clickhouse-operator";
    "app.kubernetes.io/version" = builtins.unsafeDiscardStringContext config.image.tag;
  };

  configRoot = "/etc/clickhouse-operator";

  # Merge overrides over builtin, deleting keys set to null.
  mergeOver =
    builtin: overrides:
    lib.filterAttrsRecursive (_: v: v != null) (lib.recursiveUpdate builtin overrides);

  # Only what has to be said in config.yaml. Every key absent here is the
  # operator's compiled-in default (pkg/apis/clickhouse.altinity.com/v1/
  # type_configuration_chop.go, the `default*` constants and `normalize*`
  # functions), and upstream's config.yaml restates most of those. What is
  # left falls into three groups: where things are mounted, the credentials,
  # and the settings upstream ships with a value that differs from the one
  # compiled in. The third group is kept because upstream's config.yaml is
  # the configuration the operator is released and tested with.
  builtinOperatorConfig = {
    # A ClickHouseOperatorConfiguration CR in the operator's namespace is
    # merged over this file, but only at startup. Compiled-in is "None".
    watch.configuration.onChange = "restart";

    # With no list the operator decides by where it runs: every namespace
    # when it is in kube-system, only its own anywhere else
    # (type_configuration_chop.go, "assume this is local installation"). A
    # Kix cluster puts it in a namespace of its own and installations in
    # theirs, where it would accept their CRs and never reconcile them. The
    # entries are regular expressions.
    watch.namespaces.include = [ ".*" ];

    clickhouse = {
      # The compiled-in paths have no chi/ prefix (config.d, users.d, ...).
      # A path that does not exist is dropped without an error, and the
      # operand pods then start without the fragments.
      configuration.file.path = {
        common = "chi/config.d";
        host = "chi/conf.d";
        user = "chi/users.d";
      };

      # The `default` user of every installation is reachable from the pod
      # itself and from the installation's other hosts (the regexp below),
      # and from nowhere else. Compiled-in is "::/0", every address.
      configuration.user.default.networksIP = [
        "::1"
        "127.0.0.1"
      ];
      # Matches the pod hostnames and the CR Service of one installation.
      # It spells the cluster domain out: a cluster whose domain is not
      # cluster.local overrides this.
      configuration.network.hostRegexpTemplate = "(chi-{chi}-[^.]+\\d+-\\d+|clickhouse\\-{chi})\\.{namespace}\\.svc\\.cluster\\.local$";

      # Which changes to a CHI's settings make the operator restart the
      # servers, by settings path. There are no compiled-in rules.
      configurationRestartPolicy.rules = [
        {
          version = "*";
          rules = [
            { "settings/*" = "yes"; }
            { "settings/access_control_path" = "no"; }
            { "settings/dictionaries_config" = "no"; }
            { "settings/max_server_memory_*" = "no"; }
            { "settings/max_*_to_drop" = "no"; }
            { "settings/max_concurrent_queries" = "no"; }
            { "settings/models_config" = "no"; }
            { "settings/user_defined_executable_functions_config" = "no"; }
            { "settings/logger/*" = "no"; }
            { "settings/macros/*" = "no"; }
            { "settings/remote_servers/*" = "no"; }
            { "settings/user_directories/*" = "no"; }
            { "settings/display_secrets_in_show_and_select" = "no"; }
            { "zookeeper/*" = "no"; }
            { "files/*.xml" = "yes"; }
            { "files/config.d/*.xml" = "yes"; }
            { "files/config.d/*dict*.xml" = "no"; }
            { "files/config.d/*no_restart*" = "no"; }
            { "profiles/default/background_*_pool_size" = "yes"; }
            { "profiles/default/max_*_for_server" = "yes"; }
          ];
        }
        {
          version = "21.*";
          rules = [ { "settings/logger" = "yes"; } ];
        }
      ];

      access = {
        # The operator reads `username` and `password` from this Secret at
        # startup and creates that user in every installation. With no
        # Secret, or one missing a key, it logs a warning and carries on
        # with the credentials compiled into the binary, which are public.
        # The credentials dep is what rules that out at eval time.
        secret = {
          namespace = (scope.forService credentials).namespaceName;
          name = credentials.out.name;
        };
        # Seconds. Compiled-in is 5; upstream ships it one under the
        # connect timeout.
        timeouts.query = 4;
      };

      # Settings the operator adds to every installation, by ClickHouse
      # version. These let the operator's user manage SQL users and named
      # collections, and let it read secrets back when it compares schema.
      # None are compiled in.
      addons.rules = [
        {
          version = ">= 23.3";
          spec.configuration.users = {
            "{clickhouseOperatorUser}/access_management" = 1;
            "{clickhouseOperatorUser}/named_collection_control" = 1;
            "{clickhouseOperatorUser}/show_named_collections" = 1;
            "{clickhouseOperatorUser}/show_named_collections_secrets" = 1;
          };
        }
        {
          version = ">= 23.5";
          spec.configuration = {
            profiles."clickhouse_operator/format_display_secrets_in_show_and_select" = 1;
            settings.display_secrets_in_show_and_select = 1;
          };
        }
      ];

      metrics = {
        # Compiled-in is 8. It has to stay under the scrape timeout.
        timeouts.collect = 9;
        # One series per CPU core per host otherwise.
        excludeRegexp = [ "^metric\\.(OS.*CPU[0-9]+|CPUFrequencyMHz_[0-9]+)$" ];
      };
    };

    keeper.configuration.file.path = {
      common = "chk/keeper_config.d";
      host = "chk/conf.d";
      user = "chk/users.d";
    };

    # The operator reads templates for ClickHouseInstallations only.
    template.chi.path = "chi/templates.d";

    reconcile = {
      # Compiled-in is one thread for each.
      runtime = {
        reconcileCHIsThreadsNumber = 10;
        reconcileShardsThreadsNumber = 5;
      };
      # Compiled-in is delete a StatefulSet that failed to create, and roll
      # back one that failed to update. Upstream leaves both in place for a
      # person to look at, and stops the reconcile on a failed update.
      statefulSet = {
        create.onFailure = "ignore";
        update.onFailure = "abort";
      };
      # None of these has a compiled-in value, and unset reads as false.
      host = {
        wait = {
          exclude = true;
          queries = true;
          include = false;
          replicas = {
            all = false;
            new = true;
          };
          probes = {
            startup = false;
            readiness = true;
          };
        };
        drop.replicas = {
          onDelete = true;
          onLostVolume = true;
          active = false;
        };
      };
    };

    # Unset reads as false. `status.error` is what says why an installation
    # went to Aborted.
    status.fields = {
      error = true;
      errors = true;
    };
  };

  # Eight directories for operand pod config fragments, which the operator
  # reads at startup and renders into the ConfigMaps of every installation.
  # Four are empty upstream; all eight are mounted so `files` can populate
  # any of them without changing the Deployment shape.
  fragmentDirs = {
    chi = [
      "conf.d"
      "config.d"
      "templates.d"
      "users.d"
    ];
    chk = [
      "conf.d"
      "keeper_config.d"
      "templates.d"
      "users.d"
    ];
  };

  # Read upstream's files verbatim so `diff -r` against the operator's
  # config/ directory shows what a version bump changed.
  upstreamFiles =
    family: dir:
    let
      path = ./files + "/${family}/${dir}";
    in
    lib.optionalAttrs (builtins.pathExists path) (
      lib.mapAttrs (file: _: builtins.readFile (path + "/${file}")) (builtins.readDir path)
    );

  unknownFragmentDirs = lib.concatLists (
    lib.mapAttrsToList (
      family: dirs:
      map (dir: "${family}.${dir}") (
        builtins.filter (dir: !(builtins.elem dir (fragmentDirs.${family} or [ ]))) (
          builtins.attrNames dirs
        )
      )
    ) config.files
  );

  fragmentKey = family: dir: "${family}-${dir}";

  fragments = lib.concatLists (
    lib.mapAttrsToList (
      family: dirs:
      map (dir: {
        inherit family dir;
        key = fragmentKey family dir;
        data = mergeOver (upstreamFiles family dir) (config.files.${family}.${dir} or { });
      }) dirs
    ) fragmentDirs
  );

  mounts = [
    (kix.mount.configMap self.configMap {
      mountPath = configRoot;
      readOnly = true;
    })
  ]
  ++ map (
    f:
    kix.mount.configMap self.fragmentConfigMaps.${f.key} {
      mountPath = "${configRoot}/${f.family}/${f.dir}";
      readOnly = true;
    }
  ) fragments
  ++ [
    # With `security.ipc.mode = "Secure"` in operatorConfig the operator
    # writes a per-pod token here at startup and the exporter reads it. It
    # is the only path either container writes to. Unused in the default
    # Plain mode.
    (kix.mount.emptyDir {
      name = "ipc";
      mountPath = "/etc/clickhouse-operator-ipc";
      medium = "Memory";
      sizeLimit = "1Mi";
    })
  ];

  inherit (scope.rbac)
    group
    core
    grant
    watch
    allow
    full
    restrictTo
    mkClusterRoleSet
    ;

  apps = group "apps" [
    "deployments"
    "replicasets"
    "statefulsets"
  ];
  policy = group "policy" [ "poddisruptionbudgets" ];
  discovery = group "discovery.k8s.io" [ "endpointslices" ];
  apiext = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];

  # One set of grants per kind in kinds.nix, so shipping a CRD and letting
  # the operator use it cannot drift apart. `access` is per kind; the two
  # subresource grants are the same for all of them upstream.
  kindRules = lib.concatLists (
    lib.mapAttrsToList (
      _: def:
      let
        cr = group def.group [ ];
      in
      [
        (cr def.plural |> allow def.access)
        (cr "${def.plural}/finalizers" |> allow [ "update" ])
        (
          cr "${def.plural}/status"
          |> allow [
            "get"
            "update"
            "patch"
            "create"
            "delete"
          ]
        )
      ]
    ) (import ./kinds.nix).crdDefs
  );

  manage = allow [
    "get"
    "patch"
    "update"
    "delete"
  ];

  operatorClusterRoles = mkClusterRoleSet scope {
    subjects = [
      {
        kind = "ServiceAccount";
        name = self.operatorServiceAccount.out.name;
        namespace = ns;
      }
    ];
    inherit labels;
    roles.${name} = grant (
      kindRules
      ++ [
        # What an installation is made of. Secrets are in the list for the
        # ones a CR spec references, in whatever namespace the CR lives, and
        # for the operator's own from the credentials dep.
        (core.configmaps |> full)
        (core.services |> full)
        (core.persistentvolumeclaims |> full)
        (core.secrets |> full)
        (apps.statefulsets |> full)
        (policy.poddisruptionbudgets |> full)

        (core.endpoints |> watch)
        (discovery.endpointslices |> watch)
        (core.events |> allow [ "create" ])
        # The volumes behind an installation's claims.
        (
          core.persistentvolumes
          |> allow [
            "get"
            "list"
            "patch"
            "update"
            "watch"
          ]
        )
        # The operator labels operand pods and deletes one to restart a
        # host. It never creates a pod; the StatefulSets do.
        (
          core.pods
          |> allow [
            "get"
            "list"
            "patch"
            "update"
            "watch"
            "delete"
          ]
        )

        # At startup the operator stamps its version on its own pod, the
        # ReplicaSet above it, and this Deployment. Upstream names the
        # Deployment and leaves the ReplicaSet open, since its name is not
        # known ahead of time.
        (apps.replicasets |> manage)
        (apps.deployments |> restrictTo [ name ] |> manage)

        (
          apiext.customresourcedefinitions
          |> allow [
            "get"
            "list"
          ]
        )
      ]
    );
  };

  # What the binaries read from the environment (config_manager.go lists a
  # few more, which are only logged). The namespace is where the operator
  # looks for its ClickHouseOperatorConfigurations, the name is how it finds
  # itself to stamp labels, and the IP is added to the networks the
  # operator's ClickHouse user may log in from, in every installation.
  env = kix.mkEnvVars {
    OPERATOR_POD_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
    OPERATOR_POD_NAME.valueFrom.fieldRef.fieldPath = "metadata.name";
    OPERATOR_POD_IP.valueFrom.fieldRef.fieldPath = "status.podIP";
  };

  # Both images are distroless static with `USER nobody`. The kubelet cannot
  # check a user name against runAsNonRoot, so the uid is spelled out.
  # Nothing is written outside the ipc mount: the logs go to stderr
  # (`-logtostderr=true` is the image's CMD).
  containerSecurityContext = {
    runAsNonRoot = true;
    allowPrivilegeEscalation = false;
    readOnlyRootFilesystem = true;
    capabilities.drop = [ "ALL" ];
  };

  probeTiming = {
    periodSeconds = 10;
    timeoutSeconds = 3;
    failureThreshold = 3;
  };
  # Build a TCP socket probe for `port`. Neither binary has a health
  # endpoint; each opens its metrics listener once its configuration is
  # loaded and its clients are built.
  portOpen = port: probeTiming // { tcpSocket.port = port; };
in
if unknownFragmentDirs != [ ] then
  scope.fail {
    package = "clickhouse-operator";
    option = "files";
    message = "config.files names ${lib.concatStringsSep ", " unknownFragmentDirs}, which the operator does not read. The directories are ${
      lib.concatStringsSep ", " (
        lib.concatLists (lib.mapAttrsToList (family: map (dir: "${family}.${dir}")) fragmentDirs)
      )
    }.";
  }
else
  {
    operatorServiceAccount = scope.mkResource {
      apiVersion = "v1";
      kind = "ServiceAccount";
      inherit name labels;
      extra.automountServiceAccountToken = true;
    };

    # JSON is YAML, and the operator reads this file through a YAML parser.
    configMap = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "${name}-config";
      inherit labels;
      data."config.yaml" = builtins.toJSON (mergeOver builtinOperatorConfig config.operatorConfig);
    };

    fragmentConfigMaps = lib.listToAttrs (
      map (
        f:
        lib.nameValuePair f.key (
          scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-${lib.replaceStrings [ "." "_" ] [ "-" "-" ] f.key}";
            inherit labels;
            inherit (f) data;
          }
        )
      ) fragments
    );

    operatorDeployment =
      {
        inherit name labels;
        # The operator watches every kind it ships and crashes until the API
        # server serves them. Derived, so a new kinds.nix entry is included.
        requires = builtins.attrValues self.crds;
        spec = {
          replicas = 1;
          # The old pod is gone before the new one starts: there is no
          # leader election, and two operators would both reconcile.
          strategy.type = "Recreate";
          selector.matchLabels = {
            "app.kubernetes.io/name" = "clickhouse-operator";
            "app.kubernetes.io/instance" = name;
          };
          template = {
            metadata = {
              inherit labels;
              # Both binaries read the tree once, at startup.
              annotations = {
                "checksum/config" = self.configMap.out.contentHash;
              }
              // lib.listToAttrs (
                map (
                  f: lib.nameValuePair "checksum/${f.key}" self.fragmentConfigMaps.${f.key}.out.contentHash
                ) fragments
              );
            };
            spec = {
              serviceAccountName = self.operatorServiceAccount.out.name;
              automountServiceAccountToken = true;
              # Long enough for a reconcile step in flight to return. What
              # it leaves half done is picked up by the next start.
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65534;
                runAsGroup = 65534;
                seccompProfile.type = "RuntimeDefault";
              };
              nodeSelector."kubernetes.io/os" = "linux";
              containers = [
                {
                  name = "operator";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  inherit env;
                  ports = [ (kix.port "op-metrics" 9999) ];
                  livenessProbe = portOpen "op-metrics";
                  # The operator's own metrics, cheap to render.
                  readinessProbe = probeTiming // {
                    httpGet = {
                      path = "/metrics";
                      port = "op-metrics";
                    };
                  };
                  inherit (config) resources;
                  securityContext = containerSecurityContext;
                }
                {
                  name = "metrics-exporter";
                  image = kix.image.ref config.metricsExporterImage;
                  imagePullPolicy = config.metricsExporterImage.pullPolicy;
                  inherit env;
                  ports = [ (kix.port "ch-metrics" 8888) ];
                  # Not an HTTP probe: a GET on /metrics here queries every
                  # ClickHouse host of every installation.
                  livenessProbe = portOpen "ch-metrics";
                  readinessProbe = portOpen "ch-metrics";
                  resources = config.metricsExporterResources;
                  securityContext = containerSecurityContext;
                }
              ];
            };
          };
        };
      }
      |> kix.withMountsOn [ "operator" "metrics-exporter" ] mounts
      |> scope.mkDeployment;

    operatorService =
      self.operatorDeployment
      |> kix.service.fromWorkload {
        name = "${name}-metrics";
        inherit labels;
      }
      |> scope.mkResource;
  }
  // operatorClusterRoles

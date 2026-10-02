# grafana: Grafana observability dashboard.
#
# Deployment with optional k8s-sidecar containers for auto-provisioning
# dashboards and datasources from ConfigMaps/Secrets labeled with
# grafana_dashboard=1 / grafana_datasource=1.
#
# Limits: one pod (`availability.max = "none"` on the Deployment). The
# package wires no alerting HA (ha_peers or ha_redis_address), and the
# default SQLite database and data claim take one writer.
#
# DI deps:
#   storage ? null            optional PVC for /var/lib/grafana. When absent,
#                             an emptyDir is used. Provision via a sibling
#                             `persistent-volume-claim` instance (immich pattern);
#                             storage sizing/class stays with the cluster op.
#   prometheus ? null         prometheus-operator, for ServiceMonitor creation
#   prometheusServer ? null   auto-wires Prometheus datasource via out.serviceUrl
#   alertmanager ? null       auto-wires Alertmanager datasource via out.serviceUrl
#   loki ? null               auto-wires the Loki datasource from loki.out.serviceUrl
#
# Each auto-wired datasource has a fixed uid, set by `prometheusDatasource`,
# `alertmanagerDatasource` and `lokiDatasource`. Dashboards find their
# datasource by uid, so a fixed one lets a dashboard move between clusters.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;

  # `fsGroup` is what gives Grafana its data volume: the kubelet makes the
  # volume group 472, group-writable and setgid. `OnRootMismatch` limits
  # that to mounts where the top directory is wrong, rather than walking
  # the whole volume on every start.
  defaultSecurityContext = {
    runAsNonRoot = true;
    runAsUser = 472;
    runAsGroup = 472;
    fsGroup = 472;
    fsGroupChangePolicy = "OnRootMismatch";
  };

  # The display name and uid of one auto-wired datasource.
  autoDatasourceOption =
    kind: dep: defaultName: defaultUid:
    lib.mkOption {
      type = lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = defaultName;
            description = "Display name in the datasource picker.";
          };
          uid = lib.mkOption {
            type = lib.types.str;
            default = defaultUid;
            description = "Stable identifier that dashboards refer to.";
          };
        };
      };
      default = { };
      description = "Name and uid of the ${kind} datasource wired from the `${dep}` dependency.";
    };
in
{
  meta = {
    version = "13.1.1";
    description = "Grafana: observability and data visualization";
    owner = "platform";
    defaultAliases = [ "grafana" ];
    k8s.minVersion = "1.25";
    # persistence.inlinePvc hand-rolls a claim; the preferred path is the
    # `storage` dep + sibling persistent-volume-claim instance. Grant kept
    # until the inline option is removed (audited by unsafeGrants).
    # With `initChownData.enabled`, init-chown-data runs as root to hand the
    # data volume to uid 472. Off by default; the grafana container itself
    # always runs as 472.
    unsafe = [
      "raw-pvc"
      "run-as-root"
    ];
  };

  # Grafana's own default login. Anyone who reaches Grafana can use it.
  warnings =
    { config, ... }:
    lib.optional (config.admin.existingSecret == "" && config.adminPassword == "admin")
      "grafana: the admin password is the default `admin`. Set `admin.existingSecret` to a Secret holding the credentials.";

  assertions =
    { config, ... }:
    [
      {
        assertion =
          !(config.sidecar.dashboards.enabled || config.sidecar.datasources.enabled)
          || config.sidecar.sources.configMaps
          || config.sidecar.sources.secrets;
        message = "grafana: the sidecars are on but `sidecar.sources` turns off both ConfigMaps and Secrets, so they have nothing to read.";
      }
    ];

  options = {
    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Merged over the default kubernetes.io/os=linux selector.";
    };
    image = kix.options.image {
      repository = "docker.io/grafana/grafana";
      tag = "13.1.1";
    };
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
    };
    sidecar = {
      image = kix.options.image {
        repository = "quay.io/kiwigrid/k8s-sidecar";
        tag = "2.8.1";
        description = "Image for the k8s-sidecar containers that load dashboards, datasources and alerting resources from labelled ConfigMaps and Secrets.";
      };
      # The grafana chart (10.5.15) leaves its `sidecar.resources` value
      # empty and suggests these values in a comment.
      resources = kix.options.resources {
        requests = {
          cpu = "50m";
          memory = "50Mi";
        };
        limits = {
          cpu = "100m";
          memory = "100Mi";
        };
        description = "Resources for each k8s-sidecar container.";
      };
      # What the sidecars read. Reading Secrets means watching every Secret in
      # the cluster, so a Grafana that is broken into exposes all of them.
      # Dashboards and datasources rarely need to be secret; a datasource
      # password can come from the environment instead.
      sources = lib.mkOption {
        type = lib.types.submodule {
          options = {
            configMaps = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                When true, Grafana loads dashboards and datasources from
                ConfigMaps. The sidecars watch for ConfigMaps labelled
                `grafana_dashboard: "1"` or `grafana_datasource: "1"` (set
                in `sidecar.dashboards` and `sidecar.datasources`) and
                load each one within seconds, including changes and
                deletions. By default,
                dashboards come from every namespace and datasources only
                from Grafana's own; `sidecar.*.searchNamespace` changes that.
                Grafana gets read access to every ConfigMap in the cluster,
                whatever `searchNamespace` says.
              '';
            };
            secrets = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                When true, Grafana loads dashboards and datasources from
                Secrets, with the same labels and namespaces as `configMaps`.
                Grafana gets read access to every Secret in the cluster, so
                anyone who breaks into Grafana can read all of them. Turn it
                on only if a datasource definition has to hold a credential
                and cannot take it from Grafana's environment.
              '';
            };
          };
        };
        default = { };
      };
      dashboards = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run the k8s-sidecar container that loads dashboards from labelled ConfigMaps or Secrets.";
        };
        searchNamespace = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "ALL";
          description = "Namespace the sidecar searches (k8s-sidecar's NAMESPACE): `ALL` or one namespace name. Null leaves NAMESPACE unset, so the sidecar searches Grafana's own namespace.";
        };
        label = lib.mkOption {
          type = lib.types.str;
          default = "grafana_dashboard";
          description = "Label key that marks a ConfigMap or Secret as holding dashboards.";
        };
        labelValue = lib.mkOption {
          type = lib.types.str;
          default = "1";
          description = "Value of `label` that the sidecar matches.";
        };
      };
      datasources = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run the k8s-sidecar container that loads datasources from labelled ConfigMaps or Secrets.";
        };
        searchNamespace = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Namespace the sidecar searches (k8s-sidecar's NAMESPACE): `ALL` or one namespace name. Null leaves NAMESPACE unset, so the sidecar searches Grafana's own namespace.";
        };
        label = lib.mkOption {
          type = lib.types.str;
          default = "grafana_datasource";
          description = "Label key that marks a ConfigMap or Secret as holding datasources.";
        };
        labelValue = lib.mkOption {
          type = lib.types.str;
          default = "1";
          description = "Value of `label` that the sidecar matches.";
        };
      };
    };
    # grafana.ini overrides merged on top of defaults
    grafanaIni = lib.mkOption {
      type = lib.types.anything;
      default = { };
      description = "Extra grafana.ini sections merged on top of defaults.";
    };
    rootUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Grafana root URL (server.root_url in grafana.ini).";
    };
    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
    };
    adminPassword = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Default admin password. Override via secret in production.";
    };

    # ── Existing-secret admin credentials ─────────────────────────────────
    # Mirrors chart's `admin.existingSecret` + `userKey`/`passwordKey`.
    # When `existingSecret` is set, kix skips the inline Secret and wires
    # both the grafana container and the sidecars to the user-provided
    # Secret. Sealed-secret / ExternalSecret-friendly.
    admin = lib.mkOption {
      type = lib.types.submodule {
        options = {
          existingSecret = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              Name of an existing Secret holding admin creds. When something
              creates that Secret at deploy time, such as an operator,
              pass `kix.untrackedRef { kind = "Secret"; name = "..."; }` so
              the deploy waits for it before starting Grafana.
            '';
          };
          userKey = lib.mkOption {
            type = lib.types.str;
            default = "admin-user";
          };
          passwordKey = lib.mkOption {
            type = lib.types.str;
            default = "admin-password";
          };
        };
      };
      default = { };
    };

    # ── Persistence (inline PVC mode) ─────────────────────────────────────
    # Mirrors chart's `persistence` block. Default-off matches upstream.
    # When `enabled = true && type = "pvc"` and the package isn't already
    # receiving a PVC via the `storage` DI alias, kix emits a sibling PVC
    # and mounts it at `/var/lib/grafana`. The chart's `type = "sts"`
    # (StatefulSet) path is intentionally not implemented. Use the DI
    # `storage` alias and a sibling persistent-volume-claim instance for
    # that workflow.
    persistence = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          # Upstream's chart also offers "sts" (a StatefulSet with a volume
          # claim template); kix implements only an inline PVC.
          type = lib.mkOption {
            type = lib.types.enum [ "pvc" ];
            default = "pvc";
            description = "How grafana persists its data. Only `pvc` is implemented; for other storage, wire the `storage` dependency to a persistent-volume-claim instance.";
          };
          size = lib.mkOption {
            type = lib.types.str;
            default = "10Gi";
          };
          storageClassName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          accessModes = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ReadWriteOnce" ];
          };
          annotations = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
          finalizers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "kubernetes.io/pvc-protection" ];
          };
          existingClaim = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "If set, mount this PVC instead of creating one.";
          };
          subPath = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
        };
      };
      default = { };
    };

    # ── Extra mounts ──────────────────────────────────────────────────────
    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra volume entries appended to the pod template.";
    };
    extraVolumeMounts = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra volumeMount entries appended to the grafana container.";
    };
    extraConfigmapMounts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            mountPath = lib.mkOption { type = lib.types.str; };
            configMap = lib.mkOption { type = lib.types.str; };
            subPath = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            readOnly = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            optional = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        }
      );
      default = [ ];
      description = "ConfigMap mounts. Each entry creates a volume + volumeMount pair.";
    };
    extraSecretMounts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            mountPath = lib.mkOption { type = lib.types.str; };
            secretName = lib.mkOption { type = lib.types.str; };
            subPath = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            readOnly = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            optional = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            defaultMode = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
          };
        }
      );
      default = [ ];
      description = "Secret mounts. Each entry creates a volume + volumeMount pair.";
    };

    # ── envFrom shortcuts ────────────────────────────────────────────────
    # Chart distinguishes envFromSecret (single string) from envFromSecrets
    # / envFromConfigMaps (lists). All three are appended to the
    # container's envFrom; `envFrom` (free-form) above remains the most
    # general entry point.
    envFromSecret = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Single Secret name appended to the grafana container's envFrom. As
        with `admin.existingSecret`, pass `kix.untrackedRef { kind =
        "Secret"; name = "..."; }` for a Secret created at deploy time.
      '';
    };
    envFromSecrets = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            optional = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
            };
          };
        }
      );
      default = [ ];
    };
    envFromConfigMaps = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            optional = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
            };
          };
        }
      );
      default = [ ];
    };
    # Rename the Prometheus one when VictoriaMetrics answers the alias, so
    # the picker says what it is. Keep the uid, so dashboards still find it.
    # To rename a datasource an existing Grafana already has, also list its
    # old name in `deleteDatasources`.
    prometheusDatasource =
      autoDatasourceOption "Prometheus" "prometheusServer" "Prometheus"
        "prometheus";
    alertmanagerDatasource =
      autoDatasourceOption "Alertmanager" "alertmanager" "Alertmanager"
        "alertmanager";
    lokiDatasource = autoDatasourceOption "Loki" "loki" "Loki" "loki";
    datasources = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra datasources appended to auto-discovered ones.";
    };
    deleteDatasources = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            orgId = lib.mkOption {
              type = lib.types.int;
              default = 1;
            };
          };
        }
      );
      default = [ ];
      example = [ { name = "Prometheus"; } ];
      description = ''
        Datasources Grafana deletes from its database, by name, before it
        provisions the ones above. Grafana matches a provisioned datasource
        by name, so a renamed one looks new, and adding it fails while the
        old entry still holds its uid ("data source with the same uid
        already exists"). List the old name here to rename one. Deleting a
        name that does not exist does nothing, so the entry can stay.
      '';
    };
    dashboardProviders = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Dashboard providers in addition to the sidecar's. None by default.";
    };
    securityContext = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      defaultText = lib.literalExpression (lib.generators.toPretty { } defaultSecurityContext);
      description = "Pod securityContext, deep-merged over the package's, which runs Grafana as user and group 472. A null value removes the package's key, for example `fsGroupChangePolicy = null`.";
    };
    initChownData.enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run a root init container that chowns /var/lib/grafana to 472:472
        before Grafana starts. Only for a volume whose driver ignores
        `fsGroup`; everywhere else `securityContext.fsGroup` already gives
        Grafana the volume. The container carries DAC_READ_SEARCH as well as
        CHOWN, because Grafana creates directories with mode 0700 and root
        needs it to read inside them on the next start.
      '';
    };
    metrics = kix.options.monitor;
    extraEnv = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = ''
        Extra env entries appended to the grafana container. Escape hatch for
        e.g. OIDC client_secret (`{ name = "GF_AUTH_..."; valueFrom.secretKeyRef = ...; }`).
      '';
    };
    envFrom = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = ''
        envFrom entries on the grafana container, typically `secretRef` /
        `configMapRef`. Use to bulk-inject GF_AUTH_GENERIC_OAUTH_* from a Secret.
      '';
    };
    ingress = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          ingressClassName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          annotations = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
          labels = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
          hosts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          path = lib.mkOption {
            type = lib.types.str;
            default = "/";
          };
          pathType = lib.mkOption {
            type = lib.types.str;
            default = "Prefix";
          };
          tls = lib.mkOption {
            type = lib.types.listOf lib.types.anything;
            default = [ ];
          };
          extraPaths = lib.mkOption {
            type = lib.types.listOf lib.types.anything;
            default = [ ];
          };
        };
      };
      default = { };
      description = "Ingress for Grafana. Mirrors upstream chart's `grafana.ingress`.";
    };
  };

  build =
    {
      self,
      config,
      # Sibling PVC instance (persistent-volume-claim package). Optional:
      # when absent the Deployment falls back to emptyDir (useful for
      # ephemeral/kind clusters).
      storage ? null,
      # prometheus-operator, for ServiceMonitor creation (alias: "prometheus")
      prometheus ? null,
      # prometheus server, for datasource URL (alias: "prometheusServer")
      prometheusServer ? null,
      alertmanager ? null,
      loki ? null,
      ...
    }:
    let
      hasMetrics = config.metrics.enabled && prometheus != null;
      mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;

      sidecarImg = kix.image.ref config.sidecar.image;

      # k8s-sidecar's RESOURCE: which kinds the sidecars watch.
      sidecarResource =
        if config.sidecar.sources.configMaps && config.sidecar.sources.secrets then
          "both"
        else if config.sidecar.sources.secrets then
          "secret"
        else
          "configmap";

      # ── Admin secret indirection ────────────────────────────────────────
      # Chart's `admin.existingSecret` lets users supply pre-existing creds.
      # When set, kix skips its own Secret and wires both the grafana
      # container env and the sidecars' REQ_USERNAME/REQ_PASSWORD to the
      # external Secret via `secretKeyRef`. The external-secret name passes
      # through `kix.untrackedRef` so the DI-tracking check accepts it; as
      # with the mounts below, a caller's `{ kind = "Secret"; ... }`
      # reference survives the wrap.
      useExternalAdminSecret = config.admin.existingSecret != "";

      adminUserEnv =
        envName:
        if useExternalAdminSecret then
          {
            name = envName;
            valueFrom.secretKeyRef = {
              name = kix.untrackedRef config.admin.existingSecret;
              key = config.admin.userKey;
            };
          }
        else
          self.secret.out.keyRef "admin-user" // { name = envName; };

      adminPasswordEnv =
        envName:
        if useExternalAdminSecret then
          {
            name = envName;
            valueFrom.secretKeyRef = {
              name = kix.untrackedRef config.admin.existingSecret;
              key = config.admin.passwordKey;
            };
          }
        else
          self.secret.out.keyRef "admin-password" // { name = envName; };

      # ── Persistence (inline PVC) ────────────────────────────────────────
      # Storage precedence: DI alias `storage` wins (existing behaviour);
      # falls back to inline PVC when `persistence.enabled = true && type =
      # "pvc"` AND no DI storage is supplied; falls back to emptyDir
      # otherwise.

      useInlinePvc =
        storage == null
        && config.persistence.enabled
        && config.persistence.type == "pvc"
        && config.persistence.existingClaim == "";
      useExistingClaim =
        storage == null
        && config.persistence.enabled
        && config.persistence.type == "pvc"
        && config.persistence.existingClaim != "";
      inlinePvcName = "${name}";

      # Volume entry that mounts grafana's /var/lib/grafana. Picks PVC
      # (DI / inline / existing-claim) or falls back to emptyDir.
      grafanaStorageVolume =
        if storage != null then
          {
            name = self.storageMount.name;
          }
          // self.storageMount.source
        else if useInlinePvc then
          {
            name = "storage";
            persistentVolumeClaim.claimName = self.persistencePvc.out.name;
          }
        else if useExistingClaim then
          {
            name = "storage";
            persistentVolumeClaim.claimName = config.persistence.existingClaim;
          }
        else
          {
            name = "storage";
            emptyDir = { };
          };

      # ── Extra mount conversion ──────────────────────────────────────────
      # Names supplied via `extraConfigmapMounts`/`extraSecretMounts`/
      # `envFromSecret*`/`envFromConfigMaps` reference external resources
      # the package doesn't manage. Wrap with `kix.untrackedRef` so the
      # DI-tracking check passes without forcing every caller to wrap by
      # hand. Wrapping keeps the context a caller's value already carries,
      # so a caller that passes `kix.untrackedRef { kind = "Secret"; name =
      # "..."; }` still makes kix wait for that Secret to exist before it
      # applies the Deployment.
      extraConfigmapVolumes = map (m: {
        inherit (m) name;
        configMap = {
          name = kix.untrackedRef m.configMap;
        }
        // lib.optionalAttrs m.optional { optional = true; };
      }) config.extraConfigmapMounts;
      extraConfigmapVolumeMounts = map (
        m:
        {
          inherit (m) name mountPath readOnly;
        }
        // lib.optionalAttrs (m.subPath != "") { inherit (m) subPath; }
      ) config.extraConfigmapMounts;

      extraSecretVolumes = map (m: {
        inherit (m) name;
        secret = {
          secretName = kix.untrackedRef m.secretName;
        }
        // lib.optionalAttrs m.optional { optional = true; }
        // lib.optionalAttrs (m.defaultMode != null) {
          inherit (m) defaultMode;
        };
      }) config.extraSecretMounts;
      extraSecretVolumeMounts = map (
        m:
        {
          inherit (m) name mountPath readOnly;
        }
        // lib.optionalAttrs (m.subPath != "") { inherit (m) subPath; }
      ) config.extraSecretMounts;

      extraEnvFromSecret = lib.optional (config.envFromSecret != "") {
        secretRef.name = kix.untrackedRef config.envFromSecret;
      };
      extraEnvFromSecrets = map (
        s:
        {
          secretRef.name = kix.untrackedRef s.name;
        }
        // lib.optionalAttrs (s.optional != null) {
          secretRef.optional = s.optional;
        }
      ) config.envFromSecrets;
      extraEnvFromConfigMaps = map (
        c:
        {
          configMapRef.name = kix.untrackedRef c.name;
        }
        // lib.optionalAttrs (c.optional != null) {
          configMapRef.optional = c.optional;
        }
      ) config.envFromConfigMaps;

      # ── Auto-wired datasources from DI ──────────────────────────────────
      autoDatasources =
        lib.optional (prometheusServer != null) {
          inherit (config.prometheusDatasource) name uid;
          type = "prometheus";
          url = prometheusServer.out.serviceUrl;
          access = "proxy";
          isDefault = true;
          jsonData.httpMethod = "POST";
        }
        ++ lib.optional (alertmanager != null) {
          inherit (config.alertmanagerDatasource) name uid;
          type = "alertmanager";
          url = alertmanager.out.serviceUrl;
          access = "proxy";
          jsonData = {
            handleGrafanaManagedAlerts = false;
            implementation = "prometheus";
          };
        }
        ++ lib.optional (loki != null) {
          inherit (config.lokiDatasource) name uid;
          type = "loki";
          url =
            loki.out.serviceUrl
              or (throw "grafana ${ns}/${name}: deps.loki resolved to an instance without out.serviceUrl, the base URL of Loki's HTTP API. Wire a loki instance, or set out.serviceUrl in the kix.mkImport that answers loki.");
          access = "proxy";
        };

      allDatasources = autoDatasources ++ config.datasources;

      # ── grafana.ini ─────────────────────────────────────────────────────
      # No calls home: no usage reports, no update checks.
      defaultIni = {
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          check_for_plugin_updates = false;
        };
        "dataproxy".keep_alive_seconds = 600;
        "dataproxy".timeout = 600;
        log.mode = "console";
        paths = {
          data = "/var/lib/grafana/";
          logs = "/var/log/grafana";
          plugins = "/var/lib/grafana/plugins";
          provisioning = "/etc/grafana/provisioning";
        };
        server = lib.optionalAttrs (config.rootUrl != null) {
          root_url = config.rootUrl;
        };
      };

      mergedIni = lib.recursiveUpdate defaultIni config.grafanaIni;

      # Booleans render as `true`/`false`. `toString` would give `1` and an
      # empty string, and Grafana reads an empty value as the setting's
      # default, so `false` would be lost.
      renderIniValue = v: if builtins.isBool v then (if v then "true" else "false") else toString v;

      renderIniSection =
        sectionName: attrs:
        let
          lines = lib.mapAttrsToList (k: v: "${k} = ${renderIniValue v}") attrs;
        in
        "[${sectionName}]\n${lib.concatStringsSep "\n" lines}\n";

      grafanaIniStr = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          section: value:
          if builtins.isAttrs value then
            renderIniSection section value
          else
            renderIniSection section { "${section}" = value; }
        ) mergedIni
      );

      # ── Dashboard providers ─────────────────────────────────────────────
      sidecarProvider = {
        name = "sidecarProvider";
        orgId = 1;
        folder = "";
        folderUid = "";
        type = "file";
        disableDeletion = false;
        allowUiUpdates = false;
        updateIntervalSeconds = 30;
        options = {
          foldersFromFilesStructure = false;
          path = "/tmp/dashboards";
        };
      };

      # Only with `initChownData.enabled`; see the option.
      initChownContainer = {
        name = "init-chown-data";
        image = "docker.io/library/busybox:1.38.0";
        command = [
          "chown"
          "-R"
          "472:472"
          "/var/lib/grafana"
        ];
        # The chart's commented `initChownData.resources` example
        # (grafana chart 10.5.15).
        resources = {
          requests = {
            cpu = "100m";
            memory = "128Mi";
          };
          limits = {
            cpu = "100m";
            memory = "128Mi";
          };
        };
        # chown writes only to the mounted volume.
        securityContext = {
          runAsNonRoot = false;
          runAsUser = 0;
          readOnlyRootFilesystem = true;
          capabilities = {
            add = [
              "CHOWN"
              "DAC_READ_SEARCH"
            ];
            drop = [ "ALL" ];
          };
          seccompProfile.type = "RuntimeDefault";
        };
        volumeMounts = [
          {
            name = "storage";
            mountPath = "/var/lib/grafana";
          }
        ];
      };

      # ── Sidecar security context ────────────────────────────────────────
      # The sidecars write only to their mounted folders. The
      # grafana-community chart (13.2.6) sets a read-only root for them.
      sidecarSecCtx = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        readOnlyRootFilesystem = true;
        seccompProfile.type = "RuntimeDefault";
      };

      # k8s-sidecar serves /healthz on HEALTH_PORT (default 8080): 503 until
      # the first sync completes, and again if the watchers die or the
      # Kubernetes API has not answered for 60s. The sidecars share the pod
      # network, so each needs its own port; these are the
      # grafana-community chart's (13.2.6), as is the startupProbe. The other
      # timings are the k8s-sidecar 2.8.1 README's examples. On kind, under
      # the 100m CPU limit, a sidecar took longer than the README's 35s
      # liveness delay to open the port and was restarted; the startupProbe
      # holds liveness off for up to five minutes.
      sidecarHealth = port: {
        env = kix.mkEnvVars { HEALTH_PORT = toString port; };
        probes = {
          startupProbe = {
            httpGet = {
              path = "/healthz";
              inherit port;
            };
            initialDelaySeconds = 5;
            periodSeconds = 5;
            failureThreshold = 60;
          };
          readinessProbe = {
            httpGet = {
              path = "/healthz";
              inherit port;
            };
            initialDelaySeconds = 20;
            periodSeconds = 5;
          };
          livenessProbe = {
            httpGet = {
              path = "/healthz";
              inherit port;
            };
            initialDelaySeconds = 35;
            periodSeconds = 10;
          };
        };
      };
      dashboardHealth = sidecarHealth 8084;
      datasourceHealth = sidecarHealth 8082;

      # ── Sidecar containers ──────────────────────────────────────────────
      dashboardSidecar = lib.optional config.sidecar.dashboards.enabled (
        {
          name = "grafana-sc-dashboard";
          image = sidecarImg;
          imagePullPolicy = config.sidecar.image.pullPolicy;
          env =
            kix.mkEnvVars {
              FOLDER = "/tmp/dashboards";
              LABEL = config.sidecar.dashboards.label;
              LABEL_VALUE = config.sidecar.dashboards.labelValue;
              METHOD = "WATCH";
              NAMESPACE = config.sidecar.dashboards.searchNamespace;
              REQ_METHOD = "POST";
              REQ_URL = "http://localhost:3000/api/admin/provisioning/dashboards/reload";
              RESOURCE = sidecarResource;
            }
            ++ dashboardHealth.env
            ++ [
              (adminUserEnv "REQ_USERNAME")
              (adminPasswordEnv "REQ_PASSWORD")
            ];
          resources = config.sidecar.resources;
          securityContext = sidecarSecCtx;
          volumeMounts = [
            {
              name = "sc-dashboard-volume";
              mountPath = "/tmp/dashboards";
            }
          ];
        }
        // dashboardHealth.probes
      );

      datasourceSidecar = lib.optional config.sidecar.datasources.enabled (
        {
          name = "grafana-sc-datasources";
          image = sidecarImg;
          imagePullPolicy = config.sidecar.image.pullPolicy;
          env =
            kix.mkEnvVars (
              {
                FOLDER = "/etc/grafana/provisioning/datasources";
                LABEL = config.sidecar.datasources.label;
                LABEL_VALUE = config.sidecar.datasources.labelValue;
                METHOD = "WATCH";
                REQ_METHOD = "POST";
                REQ_URL = "http://localhost:3000/api/admin/provisioning/datasources/reload";
                RESOURCE = sidecarResource;
              }
              // lib.optionalAttrs (config.sidecar.datasources.searchNamespace != null) {
                NAMESPACE = config.sidecar.datasources.searchNamespace;
              }
            )
            ++ datasourceHealth.env
            ++ [
              (adminUserEnv "REQ_USERNAME")
              (adminPasswordEnv "REQ_PASSWORD")
            ];
          resources = config.sidecar.resources;
          securityContext = sidecarSecCtx;
          volumeMounts = [
            {
              name = "sc-datasources-volume";
              mountPath = "/etc/grafana/provisioning/datasources";
            }
          ];
        }
        // datasourceHealth.probes
      );

      # ── RBAC for sidecars ───────────────────────────────────────────────
      # Sidecars watch the kinds in `sidecar.sources` across all namespaces.
      needsClusterRbac = config.sidecar.dashboards.enabled || config.sidecar.datasources.enabled;

      inherit (scope.rbac)
        core
        grant
        watch
        mkClusterRoleSet
        ;

      clusterRoles = lib.optionalAttrs needsClusterRbac (
        mkClusterRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = ns;
            }
          ];
          labels = scope.selectorLabels;
          roles = {
            "${name}" = grant (
              lib.optional config.sidecar.sources.configMaps (core.configmaps |> watch)
              ++ lib.optional config.sidecar.sources.secrets (core.secrets |> watch)
            );
          };
        }
      );

    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        extra.automountServiceAccountToken = true;
      };

      # ── Config ──────────────────────────────────────────────────────────

      configMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-config";
        extra.data = {
          "grafana.ini" = grafanaIniStr;
          "dashboardproviders.yaml" = builtins.toJSON {
            apiVersion = 1;
            providers = config.dashboardProviders;
          };
        };
      };

      scDashboardProvider =
        if config.sidecar.dashboards.enabled then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-sc-dashboard-provider";
            extra.data = {
              "provider.yaml" = builtins.toJSON {
                apiVersion = 1;
                providers = [ sidecarProvider ];
              };
            };
          }
        else
          null;

      datasourcesConfigMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-datasources";
        extra = {
          metadata.labels = {
            grafana_datasource = "1";
          };
          data = {
            "datasources.yaml" = builtins.toJSON (
              {
                apiVersion = 1;
                datasources = allDatasources;
              }
              // lib.optionalAttrs (config.deleteDatasources != [ ]) {
                inherit (config) deleteDatasources;
              }
            );
          };
        };
      };

      # When `admin.existingSecret` is set, the user-provided Secret is the
      # source of truth: kix skips its own Secret resource. Reading
      # `self.secret` in that mode is a programmer error; gate consumers
      # off `useExternalAdminSecret` instead.
      secret =
        if useExternalAdminSecret then
          null
        else
          scope.mkSecret {
            inherit name;
            stringData = {
              admin-user = config.adminUser;
              admin-password = config.adminPassword;
            };
          };

      # Inline PVC, only when persistence is enabled in pvc mode and no DI
      # storage is supplied (DI takes precedence). `existingClaim` skips
      # this; we mount the user's PVC directly.
      persistencePvc =
        if useInlinePvc then
          scope.mkResource (
            {
              apiVersion = "v1";
              kind = "PersistentVolumeClaim";
              name = inlinePvcName;
              annotations = config.persistence.annotations;
              spec = {
                accessModes = config.persistence.accessModes;
                resources.requests.storage = config.persistence.size;
              }
              // lib.optionalAttrs (config.persistence.storageClassName != null) {
                inherit (config.persistence) storageClassName;
              };
            }
            // lib.optionalAttrs (config.persistence.finalizers != [ ]) {
              extra.metadata.finalizers = config.persistence.finalizers;
            }
          )
        else
          null;

      # ── Storage mount (DI) ──────────────────────────────────────────────
      # Grafana's /var/lib/grafana is backed by the sibling `storage`
      # instance when present. `kix.mount.pvc` returns null if storage is
      # null, which we use below to pick an emptyDir fallback.
      storageMount =
        if storage != null then
          kix.mount.pvc storage {
            name = "storage";
            mountPath = "/var/lib/grafana";
          }
        else
          null;

      # ── Deployment ──────────────────────────────────────────────────────

      # One pod: the package wires no alerting HA (ha_peers or
      # ha_redis_address), and the default SQLite database and data claim
      # take one writer. A partsOverlays entry that rebuilds this Deployment
      # without availability.max can run more once those are configured.
      deployment =
        {
          inherit name;
          availability.max = "none";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            strategy.type = "Recreate";
            # The datasource sidecar reads the datasources ConfigMap through
            # the API, so no volume links it to the pod. This annotation
            # carries its Service addresses into the pod spec, which gives
            # Grafana derived egress to each datasource, and restarts the pod
            # when a datasource changes.
            template.metadata.annotations = lib.optionalAttrs config.sidecar.datasources.enabled {
              "checksum/datasources" = self.datasourcesConfigMap.out.identityHash;
            };
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              automountServiceAccountToken = true;
              # Kubernetes' default, set explicitly; the grafana chart
              # (10.5.15) sets none.
              terminationGracePeriodSeconds = 30;
              securityContext = lib.filterAttrsRecursive (_: v: v != null) (
                lib.recursiveUpdate defaultSecurityContext config.securityContext
              );
              containers = [
                {
                  name = "grafana";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  env = [
                    {
                      name = "GF_PATHS_DATA";
                      value = "/var/lib/grafana/";
                    }
                    {
                      name = "GF_PATHS_LOGS";
                      value = "/var/log/grafana";
                    }
                    {
                      name = "GF_PATHS_PLUGINS";
                      value = "/var/lib/grafana/plugins";
                    }
                    {
                      name = "GF_PATHS_PROVISIONING";
                      value = "/etc/grafana/provisioning";
                    }
                    (adminUserEnv "GF_SECURITY_ADMIN_USER")
                    (adminPasswordEnv "GF_SECURITY_ADMIN_PASSWORD")
                    {
                      name = "POD_IP";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "status.podIP";
                      };
                    }
                  ]
                  ++ config.extraEnv;
                  envFrom = config.envFrom ++ extraEnvFromSecret ++ extraEnvFromSecrets ++ extraEnvFromConfigMaps;
                  ports = [
                    (kix.port "grafana" 3000)
                  ];
                  resources = config.resources;
                  # Grafana writes to /var/lib/grafana (storage) and /tmp;
                  # the grafana-community chart (13.2.6) runs it read-only
                  # with the same /tmp emptyDir. Logs go to the console.
                  # Grafana 13 installs zipkin and elasticsearch into
                  # /var/lib/grafana/plugins at startup and deletes the
                  # copies in plugins-bundled first; on a read-only root the
                  # delete fails and neither plugin loads. The emptyDir over
                  # that directory is the chart's `shadowBundledPlugins`.
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  livenessProbe = {
                    httpGet = {
                      path = "/api/health";
                      port = 3000;
                    };
                    initialDelaySeconds = 60;
                    periodSeconds = 10;
                    failureThreshold = 10;
                    timeoutSeconds = 30;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/api/health";
                      port = 3000;
                    };
                    periodSeconds = 10;
                    failureThreshold = 3;
                    timeoutSeconds = 1;
                  };
                  volumeMounts = [
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                    {
                      name = "plugins-bundled";
                      mountPath = "/usr/share/grafana/data/plugins-bundled";
                    }
                    {
                      name = "config";
                      mountPath = "/etc/grafana/grafana.ini";
                      subPath = "grafana.ini";
                    }
                    {
                      name = "config";
                      mountPath = "/etc/grafana/provisioning/dashboards/dashboardproviders.yaml";
                      subPath = "dashboardproviders.yaml";
                    }
                  ]
                  ++ lib.optional config.sidecar.dashboards.enabled {
                    name = "sc-dashboard-provider";
                    mountPath = "/etc/grafana/provisioning/dashboards/sc-dashboardproviders.yaml";
                    subPath = "provider.yaml";
                  }
                  ++ lib.optional config.sidecar.datasources.enabled {
                    name = "sc-datasources-volume";
                    mountPath = "/etc/grafana/provisioning/datasources";
                  }
                  ++ lib.optional config.sidecar.dashboards.enabled {
                    name = "sc-dashboard-volume";
                    mountPath = "/tmp/dashboards";
                  }
                  ++ [
                    (
                      if self.storageMount != null then
                        {
                          inherit (self.storageMount) name mountPath;
                        }
                      else
                        (
                          {
                            name = "storage";
                            mountPath = "/var/lib/grafana";
                          }
                          // lib.optionalAttrs (config.persistence.subPath != "") {
                            inherit (config.persistence) subPath;
                          }
                        )
                    )
                  ]
                  ++ extraConfigmapVolumeMounts
                  ++ extraSecretVolumeMounts
                  ++ config.extraVolumeMounts;
                }
              ]
              ++ dashboardSidecar
              ++ datasourceSidecar;
              volumes = [
                {
                  name = "tmp";
                  emptyDir = { };
                }
                {
                  name = "plugins-bundled";
                  emptyDir = { };
                }
                {
                  name = "config";
                  configMap.name = self.configMap.out.name;
                }
              ]
              ++ lib.optional (self.scDashboardProvider != null) {
                name = "sc-dashboard-provider";
                configMap.name = self.scDashboardProvider.out.name;
              }
              ++ lib.optional config.sidecar.dashboards.enabled {
                name = "sc-dashboard-volume";
                emptyDir = { };
              }
              ++ lib.optional config.sidecar.datasources.enabled {
                name = "sc-datasources-volume";
                emptyDir = { };
              }
              ++ [ grafanaStorageVolume ]
              ++ extraConfigmapVolumes
              ++ extraSecretVolumes
              ++ config.extraVolumes;
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              }
              // config.nodeSelector;
            }
            // lib.optionalAttrs config.initChownData.enabled {
              initContainers = [ initChownContainer ];
            };
          };
        }
        |> scope.mkDeployment;

      # ── Service ─────────────────────────────────────────────────────────

      service =
        self.deployment
        |> kix.service.fromWorkload {
          inherit name;
          type = "ClusterIP";
          ports = [
            {
              name = "http-web";
              port = 80;
              targetPort = 3000;
              protocol = "TCP";
            }
          ];
        }
        |> scope.mkResource;

      # ── Ingress (optional) ──────────────────────────────────────────────

      ingress =
        if config.ingress.enabled then
          scope.mkResource {
            apiVersion = "networking.k8s.io/v1";
            kind = "Ingress";
            inherit name;
            annotations = config.ingress.annotations;
            labels = config.ingress.labels;
            spec = {
              rules = map (host: {
                inherit host;
                http.paths = config.ingress.extraPaths ++ [
                  {
                    inherit (config.ingress) path pathType;
                    backend.service = {
                      name = self.service.out.name;
                      port.number = 80;
                    };
                  }
                ];
              }) config.ingress.hosts;
            }
            // lib.optionalAttrs (config.ingress.ingressClassName != null) {
              inherit (config.ingress) ingressClassName;
            }
            // lib.optionalAttrs (config.ingress.tls != [ ]) {
              inherit (config.ingress) tls;
            };
          }
        else
          null;

      # ── Monitoring (optional via DI) ────────────────────────────────────

      serviceMonitor =
        if hasMetrics then
          mkServiceMonitor {
            name = "${name}-monitor";
            spec = {
              # A ServiceMonitor selects Services, not pods.
              selector.matchLabels = self.service.out.selector;
              endpoints = [
                (
                  {
                    port = "http-web";
                    path = "/metrics";
                  }
                  // lib.optionalAttrs (config.metrics.interval != null) {
                    inherit (config.metrics) interval;
                  }
                )
              ];
            };
          }
        else
          null;

      root = {
        resource = self.service;
        requires = [
          self.serviceAccount
          self.configMap
          self.datasourcesConfigMap
        ]
        ++ lib.optional (self.secret != null) self.secret
        ++ [ self.deployment ]
        ++ lib.optional (self.persistencePvc != null) self.persistencePvc
        ++ lib.optional (self.scDashboardProvider != null) self.scDashboardProvider
        ++ lib.optional (self.serviceMonitor != null) self.serviceMonitor
        ++ lib.optional (self.ingress != null) self.ingress;
      };
    }
    // clusterRoles;
}

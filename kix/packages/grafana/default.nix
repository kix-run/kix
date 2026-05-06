# grafana — Grafana observability dashboard.
#
# Deployment with optional k8s-sidecar containers for auto-provisioning
# dashboards and datasources from ConfigMaps/Secrets labeled with
# grafana_dashboard=1 / grafana_datasource=1.
#
# DI deps:
#   storage ? null          — optional PVC for /var/lib/grafana. When absent,
#                             an emptyDir is used. Provision via a sibling
#                             `persistent-volume-claim` instance (immich pattern);
#                             storage sizing/class stays with the cluster op.
#   prometheus ? null       — prometheus-operator, for ServiceMonitor creation
#   prometheusServer ? null — auto-wires Prometheus datasource via out.serviceUrl
#   alertmanager ? null     — auto-wires Alertmanager datasource via out.serviceUrl
#   loki ? null             — auto-wires Loki datasource (if out.serviceUrl exists)
#
# Exposes:
#   out.serviceUrl — "http://<name>.<ns>.svc.cluster.local:80"

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
in
{
  meta = {
    version = "11.6.1";
    description = "Grafana — observability and data visualization";
    provides = [ "dashboards" ];
    defaultAliases = [ "grafana" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "docker.io/grafana/grafana";
        tag = "11.6.1";
        pullPolicy = "IfNotPresent";
      };
    };
    sidecarImage = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/kiwigrid/k8s-sidecar";
        tag = "1.30.0";
        pullPolicy = "IfNotPresent";
      };
    };
    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
    };
    # Note: persistence (PVC size / storageClass) is now controlled by a
    # sibling `storage` instance of `persistent-volume-claim`. Leaving this
    # option out of grafana keeps package config focused on grafana itself.
    sidecar = lib.mkOption {
      type = lib.types.anything;
      default = {
        dashboards = {
          enabled = true;
          searchNamespace = "ALL";
          label = "grafana_dashboard";
          labelValue = "1";
        };
        datasources = {
          enabled = true;
          # null = inherit k8s-sidecar default ("the pod's namespace" — kix
          # also grants cluster-wide RBAC so cross-namespace discovery still
          # works without the env). Set to "ALL" or a specific namespace
          # to override. Matches chart's `sidecar.datasources.searchNamespace`.
          searchNamespace = null;
          label = "grafana_datasource";
          labelValue = "1";
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
            description = "Name of an existing Secret holding admin creds.";
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
    # (StatefulSet) path is intentionally not implemented — use the DI
    # `storage` alias and a sibling persistent-volume-claim instance for
    # that workflow.
    persistence = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          type = lib.mkOption {
            type = lib.types.str;
            default = "pvc";
            description = "pvc | sts. Only `pvc` is implemented in kix.";
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
      description = "Single Secret name appended to the grafana container's envFrom.";
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
    datasources = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra datasources appended to auto-discovered ones.";
    };
    dashboardProviders = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "Extra dashboard providers appended to defaults.";
    };
    securityContext = lib.mkOption {
      type = lib.types.anything;
      default = {
        runAsNonRoot = true;
        runAsUser = 472;
        runAsGroup = 472;
        fsGroup = 472;
      };
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
      # Sibling PVC instance (persistent-volume-claim package). Optional —
      # when absent the Deployment falls back to emptyDir (useful for
      # ephemeral/kind clusters).
      storage ? null,
      # prometheus-operator — for ServiceMonitor creation (alias: "prometheus")
      prometheus ? null,
      # prometheus server — for datasource URL (alias: "prometheusServer")
      prometheusServer ? null,
      alertmanager ? null,
      loki ? null,
      ...
    }:
    let
      hasMetrics = config.metrics.enabled && prometheus != null;
      mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;

      sidecarImg = "${config.sidecarImage.repository}:${config.sidecarImage.tag}";

      # ── Admin secret indirection ────────────────────────────────────────
      # Chart's `admin.existingSecret` lets users supply pre-existing creds.
      # When set, kix skips its own Secret and wires both the grafana
      # container env and the sidecars' REQ_USERNAME/REQ_PASSWORD to the
      # external Secret via `secretKeyRef`. The external-secret name passes
      # through `kix.untrackedRef` so the DI-tracking check accepts it.
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
      # otherwise. STS mode is not implemented — surface a clear error.
      _stsRequested = config.persistence.enabled && config.persistence.type == "sts";
      _ = lib.optional _stsRequested (throw ''
        [grafana] persistence.type = "sts" is not implemented in kix.
        Either use the `storage` DI alias with a sibling
        persistent-volume-claim instance, or set persistence.type = "pvc".
      '');

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
      # the package doesn't manage — wrap with `kix.untrackedRef` so the
      # DI-tracking check passes without forcing every caller to wrap by
      # hand. Users who want a tracked edge to a kix-managed resource can
      # pass the resource's `out.name` directly (already context-bearing,
      # so `untrackedRef` is a no-op equivalent).
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
          name = "Prometheus";
          type = "prometheus";
          uid = "prometheus";
          url = prometheusServer.out.serviceUrl;
          access = "proxy";
          isDefault = true;
          jsonData.httpMethod = "POST";
        }
        ++ lib.optional (alertmanager != null) {
          name = "Alertmanager";
          type = "alertmanager";
          uid = "alertmanager";
          url = alertmanager.out.serviceUrl;
          access = "proxy";
          jsonData = {
            handleGrafanaManagedAlerts = false;
            implementation = "prometheus";
          };
        }
        # Loki wiring: if the loki instance exposes out.serviceUrl, use it.
        # For Helm-wrapped Loki, pass the URL via config.datasources instead.
        ++ lib.optional (loki != null && loki ? out && loki.out ? serviceUrl) {
          name = "Loki";
          type = "loki";
          url = loki.out.serviceUrl;
          access = "proxy";
        };

      allDatasources = autoDatasources ++ config.datasources;

      # ── grafana.ini ─────────────────────────────────────────────────────
      defaultIni = {
        analytics.check_for_updates = true;
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

      # Serialize grafana.ini as INI format
      renderIniSection =
        sectionName: attrs:
        let
          lines = lib.mapAttrsToList (k: v: "${k} = ${toString v}") attrs;
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
      defaultProviders = [
        {
          name = "default";
          orgId = 1;
          folder = "default";
          type = "file";
          disableDeletion = false;
          editable = true;
          options.path = "/var/lib/grafana/dashboards/standard";
        }
      ];

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

      allProviders =
        defaultProviders
        ++ lib.optional config.sidecar.dashboards.enabled sidecarProvider
        ++ config.dashboardProviders;

      dashboardProvidersYaml = builtins.toJSON {
        apiVersion = 1;
        providers = allProviders;
      };

      # ── Sidecar security context ────────────────────────────────────────
      sidecarSecCtx = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        seccompProfile.type = "RuntimeDefault";
      };

      # ── Sidecar containers ──────────────────────────────────────────────
      dashboardSidecar = lib.optional config.sidecar.dashboards.enabled {
        name = "grafana-sc-dashboard";
        image = sidecarImg;
        imagePullPolicy = config.sidecarImage.pullPolicy;
        env =
          kix.mkEnvVars {
            FOLDER = "/tmp/dashboards";
            LABEL = config.sidecar.dashboards.label;
            LABEL_VALUE = config.sidecar.dashboards.labelValue;
            METHOD = "WATCH";
            NAMESPACE = config.sidecar.dashboards.searchNamespace;
            REQ_METHOD = "POST";
            REQ_URL = "http://localhost:3000/api/admin/provisioning/dashboards/reload";
            RESOURCE = "both";
          }
          ++ [
            (adminUserEnv "REQ_USERNAME")
            (adminPasswordEnv "REQ_PASSWORD")
          ];
        securityContext = sidecarSecCtx;
        volumeMounts = [
          {
            name = "sc-dashboard-volume";
            mountPath = "/tmp/dashboards";
          }
        ];
      };

      datasourceSidecar = lib.optional config.sidecar.datasources.enabled {
        name = "grafana-sc-datasources";
        image = sidecarImg;
        imagePullPolicy = config.sidecarImage.pullPolicy;
        env =
          kix.mkEnvVars (
            {
              FOLDER = "/etc/grafana/provisioning/datasources";
              LABEL = config.sidecar.datasources.label;
              LABEL_VALUE = config.sidecar.datasources.labelValue;
              METHOD = "WATCH";
              REQ_METHOD = "POST";
              REQ_URL = "http://localhost:3000/api/admin/provisioning/datasources/reload";
              RESOURCE = "both";
            }
            // lib.optionalAttrs ((config.sidecar.datasources.searchNamespace or null) != null) {
              NAMESPACE = config.sidecar.datasources.searchNamespace;
            }
          )
          ++ [
            (adminUserEnv "REQ_USERNAME")
            (adminPasswordEnv "REQ_PASSWORD")
          ];
        securityContext = sidecarSecCtx;
        volumeMounts = [
          {
            name = "sc-datasources-volume";
            mountPath = "/etc/grafana/provisioning/datasources";
          }
        ];
      };

      # ── RBAC for sidecars ───────────────────────────────────────────────
      # Sidecars need to watch ConfigMaps and Secrets across all namespaces
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
            "${name}" = grant [
              (core.configmaps |> watch)
              (core.secrets |> watch)
            ];
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
            providers = defaultProviders;
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
            "datasources.yaml" = builtins.toJSON {
              apiVersion = 1;
              datasources = allDatasources;
            };
          };
        };
      };

      # When `admin.existingSecret` is set, the user-provided Secret is the
      # source of truth — kix skips its own Secret resource. Reading
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
      # this — we mount the user's PVC directly.
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

      deployment =
        {
          inherit name;
          spec = {
            replicas = config.replicas;
            selector.matchLabels = scope.selectorLabels;
            strategy.type = "Recreate";
            template.spec = {
              serviceAccountName = self.serviceAccount.out.name;
              automountServiceAccountToken = true;
              securityContext = config.securityContext;
              initContainers = [
                {
                  name = "init-chown-data";
                  image = "docker.io/library/busybox:1.37.0";
                  command = [
                    "chown"
                    "-R"
                    "472:472"
                    "/var/lib/grafana"
                  ];
                  securityContext = {
                    runAsNonRoot = false;
                    runAsUser = 0;
                    capabilities = {
                      add = [ "CHOWN" ];
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
                }
              ];
              containers = [
                {
                  name = "grafana";
                  image = "${config.image.repository}:${config.image.tag}";
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
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
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
              };
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
              targetPort = "grafana";
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
              selector.matchLabels = self.deployment.out.selector;
              endpoints = [
                {
                  port = "http-web";
                  interval = config.metrics.interval or "30s";
                  path = "/metrics";
                }
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
        out = {
          serviceUrl = "http://${name}.${ns}.svc.cluster.local:80";
        };
      };
    }
    // clusterRoles;
}

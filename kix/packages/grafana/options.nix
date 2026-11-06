# Options of the grafana package. Kept free of `scope` so
# `docs/nix/reference.nix` can evaluate options statically.
{
  lib,
  kix,
  release,
}:
let
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

  iniValue = lib.types.nullOr (
    lib.types.oneOf [
      lib.types.bool
      lib.types.int
      lib.types.float
      lib.types.str
    ]
  );

  sidecarOptions = kind: label: searchNamespace: {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the k8s-sidecar container that loads ${kind} from labelled ConfigMaps or Secrets.";
    };
    searchNamespace = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = searchNamespace;
      description = "Namespace the sidecar searches (k8s-sidecar's NAMESPACE): `ALL` or one namespace name. Null leaves NAMESPACE unset, so the sidecar searches Grafana's own namespace.";
    };
    label = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = label;
      description = "Label key that marks a ConfigMap or Secret as holding ${kind}.";
    };
    labelValue = lib.mkOption {
      type = lib.types.str;
      default = "1";
      description = "Value of `label` that the sidecar matches.";
    };
  };
in
{
  image = kix.options.image {
    repository = "docker.io/grafana/grafana";
    tag = release;
    digest = "sha256:1a8e58976a6cd349d1ffdd27a14b92053816c7c60e6b7e157013e9bf0b9cec5f";
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
  settings = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf iniValue);
    default = { };
    example = {
      server.root_url = "https://grafana.example.com";
      "auth.generic_oauth" = {
        enabled = true;
        client_id = "grafana";
      };
    };
    description = ''
      grafana.ini sections and keys, merged over the package defaults. The
      package disables calls to grafana.com (`analytics.reporting_enabled`,
      `analytics.check_for_updates`, `analytics.check_for_plugin_updates`,
      `plugins.public_key_retrieval_disabled`, `plugins.preinstall_disabled`,
      and `news.news_feed_enabled`), sets `log.mode = "console"`, sets data
      proxy timeouts, and sets `server.root_url` from the route. A null value
      removes a key. The `paths` section, `server.http_port`,
      `security.admin_user`, and `security.admin_password` are refused because
      the mounts, Service, and `grafanaAdmin` dependency own them. Pass
      credentials through `env` (`secretKeyRef`) or `$__file{...}` rather than
      writing them into this ConfigMap.
    '';
  };
  env = kix.options.env // {
    description = "Extra environment variables for Grafana, such as `GF_<SECTION>_<KEY>` settings: a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The `GF_PATHS_*` variables and the administrator login from `grafanaAdmin` are refused.";
  };
  sidecar = {
    image = kix.options.image {
      repository = "quay.io/kiwigrid/k8s-sidecar";
      tag = "2.8.1";
      digest = "sha256:abb55b2165c60e8f97e473862c7a3123df6f67d44f592949577c29b8fb2df9d6";
      description = "Image for the k8s-sidecar containers that load dashboards and datasources from labelled ConfigMaps and Secrets.";
    };
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
    sources = {
      configMaps = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Load dashboards and datasources from ConfigMaps matching `sidecar.dashboards` and `sidecar.datasources` labels. Grants Grafana cluster-wide ConfigMap read access regardless of `searchNamespace`.";
      };
      secrets = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also load dashboards and datasources from labelled Secrets. Grants Grafana cluster-wide Secret read access; enable only when a datasource definition cannot read its credential from Grafana's environment.";
      };
    };
    dashboards = sidecarOptions "dashboards" "grafana_dashboard" "ALL";
    datasources = sidecarOptions "datasources" "grafana_datasource" null;
  };
  initChownData = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run a root init container that chowns /var/lib/grafana to 472:472
        before Grafana starts. Enable only when the storage driver ignores
        `fsGroup`. Carries `CHOWN` and `DAC_READ_SEARCH` so root can traverse
        mode-0700 directories Grafana created on prior starts.
      '';
    };
    image = kix.options.image {
      repository = "docker.io/library/busybox";
      tag = "1.38.0";
      digest = "sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e";
      description = "Image of the init-chown-data container.";
    };
  };
  prometheusDatasource =
    autoDatasourceOption "Prometheus" "prometheusServer" "Prometheus"
      "prometheus";
  alertmanagerDatasource =
    autoDatasourceOption "Alertmanager" "alertmanager" "Alertmanager"
      "alertmanager";
  lokiDatasource = autoDatasourceOption "Loki" "loki" "Loki" "loki";
  tempoDatasource = autoDatasourceOption "Tempo" "tempo" "Tempo" "tempo";
  datasources = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.anything;
        options = {
          name = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Display name in the datasource picker.";
          };
          type = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Datasource plugin id, such as `prometheus`, `loki`, or `postgres`.";
          };
        };
      }
    );
    default = [ ];
    example = [
      {
        name = "Pyroscope";
        type = "grafana-pyroscope-datasource";
        uid = "pyroscope";
        url = "https://pyroscope.example.com";
        access = "proxy";
      }
    ];
    description = "Datasources provisioned after the wired ones, in Grafana's provisioning format. Under default deny Grafana gets no automatic egress to their URLs; add a network policy that allows it. Because entries land in a ConfigMap, credentials in `secureJsonData`, `password`, or `basicAuthPassword` must use a reference Grafana expands (`$VAR` from `env` or `$__file{<path>}`); literal strings are refused.";
  };
  deleteDatasources = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Name of the datasource to delete before provisioning.";
          };
          orgId = lib.mkOption {
            type = lib.types.int;
            default = 1;
            description = "Organization ID of the datasource to delete.";
          };
        };
      }
    );
    default = [ ];
    example = [ { name = "Prometheus"; } ];
    description = ''
      Datasources Grafana deletes from its database by name before
      provisioning. Grafana matches provisioned datasources by name, so
      renaming one while keeping its uid fails unless the old name is listed
      here. Deleting a nonexistent name is a no-op.
    '';
  };
  ingress = kix.options.ingress // {
    host = kix.options.ingress.host // {
      description = "Public hostname of Grafana's route. Null means no route: Grafana does not default to `<instance>.<cluster.domain>` because the route also serves unauthenticated `/metrics`.";
    };
  };
  metrics = kix.options.monitor;
  oidc = kix.options.oidc {
    scopes = [
      "openid"
      "profile"
      "email"
    ];
    autoLogin = "`auth.generic_oauth.auto_login`";
  };
}

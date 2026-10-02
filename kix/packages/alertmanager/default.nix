# alertmanager: an Alertmanager, run by the Prometheus Operator from an
# Alertmanager resource.
#
# Installs the Alertmanager resource, its ServiceAccount, the configuration
# Secret (alertmanager.yaml from `settings`), the egress policy of the
# Alertmanager pods, and, while `metrics.enabled`, a ServiceMonitor through
# which Prometheus scrapes it. The operator turns the resource into a
# StatefulSet and a headless Service `alertmanager-operated` (port `web`,
# 9093), which `service` describes.
#
# Dependencies:
#   prometheusOperator (required)  the operator, whose `out.crds.Alertmanager`
#                                  builds the resource.
#   storageClasses (optional)      the class of the data volumes when
#                                  `storage.size` is set and
#                                  `storage.storageClassName` is null.
#   priorityClass (optional)       the Alertmanager pods' PriorityClass.
#
# Minimal instance, with a prometheus-operator in the same cluster:
#
#   instances.monitoring-system.alertmanager.package = packages.alertmanager;
#
# Without `settings` every alert goes to the receiver `null`, which drops it.
#
# `out`: the `alertmanager-operated` Service's `name`, `fqdn`, and `port`,
# plus `namespace` and `portName`, which a Prometheus resource's
# `spec.alerting` names (the prometheus package reads them), and
# `serviceUrl`, the base URL of the API (Grafana's datasource).
#
# Replicas follow the instance's availability: one up to `pod`, three from
# `node`, gossiping silences and the notification log, spread across the
# level's failure domain, with a PodDisruptionBudget that keeps two up.
#
# Network policy: the egress policy opens DNS, the gossip port between the
# replicas, and the world on the ports of the receivers in `settings`: the
# port in each receiver URL (443 or 80 by scheme when the URL has none, 443
# for a receiver whose URL comes from a file or Alertmanager's default), and
# the port of each email smarthost. A receiver inside the cluster, or one
# reached through `http_config.proxy_url`, needs a policy of its own.
#
# Escape hatches: `settings` for alertmanager.yaml, `extraSpec` for the
# Alertmanager resource's spec, and the instance's `partsOverlays`.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "v0.33.1";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "alertmanager ${ns}/${name}";

  defaultSettings = import ./default-settings.nix;

  replicas = kix.availability.pick availability {
    none = 1;
    pod = 1;
    node = 3;
    zone = 3;
  };

  # The ports Alertmanager dials to deliver notifications (see the header).
  receiverPorts = import ./receiver-ports.nix { inherit lib who; };
in
{
  meta = {
    version = release;
    description = "Alertmanager: alert routing and deduplication";
    owner = "platform";
    defaultAliases = [ "alertmanager" ];
    k8s.minVersion = "1.25";
    # Silences and notification state are recoverable, so expendable on
    # storage backend swaps. See v2_discussions/67_stateful_migration_orchestration.md.
    lifecycle = "ephemeral";
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = config.storage.size != null || config.storage.storageClassName == null;
        message = "storage.storageClassName is set but storage.size is null, so Alertmanager keeps its data in an emptyDir and the class is unused. Set storage.size, or remove storage.storageClassName.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "quay.io/prometheus/alertmanager";
      tag = release;
      digest = "sha256:9e082985f56f4c8c9f724e18f2288c6708f472e56a5286b8863d080434ea065d";
      pullPolicy = null;
    };
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
    };
    settings = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      defaultText = lib.literalMD "null: the package's configuration, which routes every alert to the receiver `null`";
      description = "The Alertmanager configuration file, alertmanager.yaml (`global`, `route`, `receivers`, `inhibit_rules`, `templates`). A value replaces the package's configuration as a whole rather than merging into it, because the package's routing tree names its own `null` receiver. Null uses the package's configuration, which routes every alert to the receiver `null`. The receivers' URLs and smarthosts decide the egress policy (see the package header). The configuration lands in a Secret that Kix renders, so take a credential from a file (`api_url_file`, `password_file`, `credentials_file`) mounted through `extraSpec.secrets` rather than writing it here.";
    };
    storage = {
      size = lib.mkOption {
        type = lib.types.nullOr kix.types.quantity;
        default = null;
        example = "1Gi";
        description = "Size of each pod's data volume, holding silences and the notification log, a claim the operator creates from the resource's volume claim template. Null keeps them in an emptyDir, which a pod restart empties.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "StorageClass of the data volumes. Null takes the `storageClasses` dependency's class, or the cluster's default class without one.";
      };
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        externalUrl = "https://alertmanager.example.com";
        secrets = [ "alertmanager-slack" ];
        alertmanagerConfigSelector = { };
      };
      description = ''
        Fields deep-merged into the Alertmanager resource's spec, such as
        `externalUrl`, `routePrefix`, `secrets` and `configMaps` (mounted
        at /etc/alertmanager/{secrets,configmaps}/<name>), `web`, or
        `alertmanagerConfigSelector` and its namespace selector. The package
        refuses `image`, `version`, and `imagePullPolicy`, which image sets,
        `replicas`, which follows the instance's availability, `resources`,
        `serviceAccountName`, `storage`, `configSecret`, which holds
        `settings`, and, when the instance has the dependency,
        `priorityClassName`.
      '';
    };
    metrics = kix.options.monitor;
  };

  build =
    {
      self,
      config,
      clusterConfig,
      prometheusOperator,
      storageClasses ? null,
      priorityClass ? null,
      ...
    }:
    let
      settings = if config.settings == null then defaultSettings else config.settings;
      ports = receiverPorts settings;

      # The labels the operator puts on this resource's pods.
      podSelector = prometheusOperator.out.operandSelectors.alertmanager name;

      storageClassName =
        if config.storage.storageClassName != null then
          config.storage.storageClassName
        else if storageClasses != null then
          storageClasses.out.storageClassName
        else
          null;

      baseSpec = {
        inherit replicas;
        image = kix.image.ref config.image;
        version = config.image.tag;
        serviceAccountName = self.serviceAccount.out.name;
        resources = config.resources;
        configSecret = self.configSecret.out.name;
      }
      // lib.optionalAttrs (config.image.pullPolicy != null) {
        imagePullPolicy = config.image.pullPolicy;
      }
      // lib.optionalAttrs (config.storage.size != null) {
        storage.volumeClaimTemplate.spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = toString config.storage.size;
        }
        // lib.optionalAttrs (storageClassName != null) { inherit storageClassName; };
      }
      // lib.optionalAttrs (priorityClass != null) {
        priorityClassName = priorityClass.out.name;
      }
      // lib.optionalAttrs (replicas > 1) {
        topologySpreadConstraints = kix.availability.spreadConstraints {
          level = availability;
          selector = podSelector;
          topology = clusterConfig.cluster.topology;
        };
      };

      spec = kix.mergeGuarded {
        inherit who;
        locked = [
          [ "image" ]
          [ "version" ]
          [ "imagePullPolicy" ]
          [ "replicas" ]
          [ "resources" ]
          [ "serviceAccountName" ]
          [ "storage" ]
          [ "configSecret" ]
        ]
        ++ lib.optional (priorityClass != null) [ "priorityClassName" ];
      } baseSpec config.extraSpec;

      # Read only when the scope has an enforcer (kix.operandPolicy).
      netpol = scope.networkPolicyEnforcer.netpol;
      peers = netpol.mkSelfRules { selector = podSelector; };
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        # Alertmanager makes no Kubernetes API calls.
        extra.automountServiceAccountToken = false;
      };

      configSecret = scope.mkSecret {
        name = "${name}-config";
        stringData."alertmanager.yaml" = builtins.toJSON settings;
      };

      alertmanager = scope.mkCR prometheusOperator.out.crds.Alertmanager {
        inherit name spec;
      };

      # The operator creates the pods, so no workload policy is derived for
      # them. Prometheus and Grafana reach them through the scrape policies
      # and their own derived egress.
      egress =
        if ports == [ ] && replicas == 1 then
          null
        else
          kix.operandPolicy {
            inherit scope;
            name = "${name}-egress";
            spec = {
              endpointSelector.matchLabels = podSelector;
              egress = [
                netpol.dnsEgressRule
              ]
              ++ lib.optionals (replicas > 1) peers.egress
              ++
                lib.optionals (ports != [ ])
                  (netpol.translateIntentRules {
                    intents.receivers.egress = [
                      {
                        to = "world";
                        ports = map (port: {
                          inherit port;
                          protocol = "TCP";
                        }) ports;
                      }
                    ];
                  }).egressRules;
            };
          };

      # Gossip between the replicas.
      peerIngress =
        if replicas > 1 then
          kix.operandPolicy {
            inherit scope;
            name = "${name}-peers";
            spec = {
              endpointSelector.matchLabels = podSelector;
              ingress = peers.ingress;
            };
          }
        else
          null;

      # The operator renders no PodDisruptionBudget, and the availability
      # plugin derives one only for workloads Kix renders.
      podDisruptionBudget =
        if replicas > 1 then
          scope.mkResource {
            apiVersion = "policy/v1";
            kind = "PodDisruptionBudget";
            inherit name;
            annotations.${kix.keys.operandOf} = "monitoring.coreos.com/Alertmanager/${self.alertmanager.name}";
            requires = [ self.alertmanager ];
            spec = {
              maxUnavailable = 1;
              selector.matchLabels = podSelector;
            };
          }
        else
          null;

      # The operator creates `alertmanager-operated` (headless, port web
      # 9093) over the pods of every Alertmanager in the namespace. A
      # ServiceRef describes it; the prometheus package's `service` part
      # gives the reasons (v2_discussions/135).
      service = scope.mkServiceRef {
        name = "alertmanager-operated";
        selector = podSelector;
        # The label the operator puts on alertmanager-operated.
        labels."operated-alertmanager" = "true";
        ports = [
          {
            name = "web";
            port = 9093;
            protocol = "TCP";
          }
        ];
        requires = [ self.alertmanager ];
      };

      selfMonitor =
        if config.metrics.enabled then
          prometheusOperator.out.mkServiceMonitor scope {
            inherit name;
            spec = {
              # A ServiceMonitor selects Services, not pods, so this uses the
              # labels of the operator's Service from its ref.
              selector.matchLabels = self.service.out.labels;
              namespaceSelector.matchNames = [ ns ];
              endpoints = [
                (
                  {
                    port = "web";
                  }
                  // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
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
          self.configSecret
          self.alertmanager
        ]
        ++ builtins.filter (p: p != null) [
          self.egress
          self.peerIngress
          self.podDisruptionBudget
          self.selfMonitor
        ];
        out = {
          namespace = ns;
          portName = "web";
          serviceUrl = "http://${self.service.out.fqdn}:${self.service.out.port}";
          # The operator runs this image in a StatefulSet that Kix does not
          # render.
          extraImages = [ (kix.image.ref config.image) ];
        };
      };
    };
}

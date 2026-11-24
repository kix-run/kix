# alertmanager: an Alertmanager, run by the Prometheus Operator from an
# Alertmanager resource.
#
# Installs the Alertmanager resource, its ServiceAccount, the configuration
# Secret (alertmanager.yaml from `settings`), a headless Service named after
# the instance (port `web`, 9093) that the resource names as its governing
# Service (`spec.serviceName`), the egress policy of the Alertmanager pods,
# and, while `metrics.enabled`, a ServiceMonitor through which Prometheus
# scrapes it. The operator turns the resource into a StatefulSet; with
# `spec.serviceName` set it creates no `alertmanager-operated` Service, and
# it reports an error for a governing Service that does not select the pods.
#
# Dependencies:
#   prometheusOperator (required)  the operator, whose `out.crds.Alertmanager`
#                                  builds the resource.
#   storageClasses (optional)      the class of the data volumes when
#                                  `storage.size` is set. Without one the
#                                  claims take the cluster's default class.
#                                  For another class, set
#                                  `deps.storageClasses = ref.<ns>.<instance>`.
#   priorityClass (optional)       the Alertmanager pods' PriorityClass.
#   alertmanagerConfig (optional)  a secret with the key `alertmanager.yaml`,
#                                  the configuration file, in place of
#                                  `settings`. For a site that keeps the
#                                  configuration in a secrets operator or a
#                                  SOPS file. The package then renders no
#                                  configuration Secret, derives no egress
#                                  from the receivers (see Network policy),
#                                  and refuses `settings`.
#
# Minimal instance, with a prometheus-operator in the same cluster:
#
#   instances.monitoring-system.alertmanager.package = packages.experimental.alertmanager;
#
# Without `settings` every alert goes to the receiver `null`, which drops it.
#
# Where the configuration comes from: `settings` is rendered into a Secret
# the package classifies as `configuration` (`kix.run/classification`),
# because Alertmanager reads its configuration from a Secret and the
# package refuses the credential keys it knows. A cluster whose
# `cluster.secrets.accept` leaves out `configuration` wires the
# `alertmanagerConfig` dependency instead.
#
# `out`: the Service's `name` and `fqdn`, plus `namespace` and
# `portName`, which a Prometheus resource's `spec.alerting` names (the
# prometheus package reads them), and `serviceUrl`, the base URL of the API
# (Grafana's datasource), and `version`, the Alertmanager version
# `image.tag` names. Each instance has its own Service, so two instances in
# one namespace do not share one.
#
# Replicas follow the instance's availability: one at `none`, two above,
# gossiping silences and the notification log. With
# more than one, the pods spread across the level's failure domain and a
# PodDisruptionBudget lets one be down at a time.
#
# Credentials: `settings` lands in a Secret that Kix renders, so the package
# refuses a credential written inline (`auth_password`, `routing_key`,
# `api_key`, a Slack `api_url`, and the rest in
# ../../stable/victoria-metrics-alert/alertmanager-inline-secrets.nix). Put
# the value in a Secret, list it in `extraSpec.secrets`, and name the mounted
# file in the `_file` key. Kix renders no dependency on that Secret: the
# deploy neither waits for it nor checks its keys.
#
# Network policy: the egress policy opens DNS, the gossip port between the
# replicas, and the world on the ports the receivers in `settings` dial
# (../../stable/victoria-metrics-alert/alertmanager-receiver-ports.nix): the
# port in each receiver's URL (443 or 80 by scheme
# when the URL has none, 443 when it comes from a file or from
# Alertmanager's built-in address), and the port of each email smarthost.
# Three kinds of receiver get no egress and need a policy of their own: one
# inside the cluster, one reached through `http_config.proxy_url`, and one
# that an AlertmanagerConfig resource adds
# (`extraSpec.alertmanagerConfigSelector`). A configuration from the
# `alertmanagerConfig` dependency opens no receiver ports either, since Kix
# cannot read it; add a `networkPolicy.platformIntents` entry for the pods.
#
# Upgrades: v0.35.0 takes over directly from v0.33.1. The operator rolls the
# StatefulSet one pod at a time, and the new pods read the silences and the
# notification log the old ones left on their claims. Replicas of the two
# versions gossip with each other during the roll. Going back works too.
# Deploying the v0.33.1 package restarts the pods on v0.33.1, which read the
# files v0.35.0 wrote. Upstream gives no upgrade or downgrade policy beyond
# the CHANGE entries in its release notes. From v0.34.2 the API sends no CORS
# headers, so a browser page served from another origin cannot call it.
# Restore them with `extraSpec.additionalArgs = [ { name =
# "web.cors.origin"; value = "<origin regex>"; } ]`. From v0.35.0 each
# event recorder output needs a `name`.
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
  release = "v0.35.0";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "alertmanager ${ns}/${name}";

  defaultSettings = import ../../stable/victoria-metrics-alert/alertmanager-default-settings.nix;

  # Two from `pod` up: peers share silences and notification state by
  # gossip and need no majority, so the one left after a lost pod, node,
  # or zone still notifies.
  replicas = kix.availability.pick availability {
    none = 1;
    pod = 2;
    node = 2;
    zone = 2;
  };

  webPort = 9093;

  # The ports Alertmanager dials to deliver notifications (see the header).
  receiverPorts = import ../../stable/victoria-metrics-alert/alertmanager-receiver-ports.nix {
    inherit lib;
    inherit (scope) fail;
  };
  refuseInlineSecrets = import ../../stable/victoria-metrics-alert/alertmanager-inline-secrets.nix {
    inherit lib;
    inherit (scope) fail;
  };
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "Alertmanager: alert routing and deduplication";
    owner = "platform";
    defaultAliases = [ "alertmanager" ];
    k8s.minVersion = "1.25";
    # Silences and notification state are recoverable, so expendable on
    # storage backend swaps.
    lifecycle = "ephemeral";
  };

  options = {
    image = kix.options.image {
      repository = "quay.io/prometheus/alertmanager";
      tag = release;
      digest = "sha256:5f6e66c01bd610aef6dd671642a52eee775fd3a89bd8788ebada33efaf373d10";
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
      description = "The Alertmanager configuration file, alertmanager.yaml (`global`, `route`, `receivers`, `inhibit_rules`, `templates`). A value replaces the package's configuration as a whole rather than merging into it, because the package's routing tree names its own `null` receiver. Null uses the package's configuration, which routes every alert to the receiver `null`. The receivers' URLs and smarthosts decide the egress policy (see the package header). The configuration lands in a Secret that Kix renders, so a credential written inline (`auth_password`, `routing_key`, `api_key`, a Slack `api_url`, and the like) is refused: take it from a file (`api_url_file`, `password_file`, `credentials_file`) mounted through `extraSpec.secrets`.";
    };
    storage = {
      size = lib.mkOption {
        type = lib.types.nullOr kix.types.quantity;
        default = null;
        example = "1Gi";
        description = "Size of each pod's data volume, holding silences and the notification log, a claim the operator creates from the resource's volume claim template, in the `storageClasses` dependency's class. Null keeps them in an emptyDir, which a pod restart empties.";
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
        `replicas` and `topologySpreadConstraints`, which follow the
        instance's availability, `resources`, `serviceAccountName`,
        `serviceName`, `storage`, `configSecret`, and
        `alertmanagerConfiguration`, which `settings` decides, and, when the
        instance has the dependency, `priorityClassName`.
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
      alertmanagerConfig ? null,
      ...
    }:
    let
      configDep =
        if alertmanagerConfig != null && config.settings != null then
          scope.fail {
            package = "alertmanager";
            message = "both settings and the alertmanagerConfig dependency are set, and each supplies the whole configuration file.";
            fix = "Remove one.";
          }
        else
          kix.contracts.secret.helpers.use {
            inherit who;
            arg = "alertmanagerConfig";
            dep = alertmanagerConfig;
            keys = [ "alertmanager.yaml" ];
          };

      # Null when the configuration comes from the dependency, whose
      # content Kix cannot read.
      settings =
        if configDep != null then
          null
        else
          refuseInlineSecrets (if config.settings == null then defaultSettings else config.settings);
      # Only the header warns that receivers inside the cluster, behind
      # http_config.proxy_url, or from AlertmanagerConfig resources get no
      # egress. Candidates for evaluation errors while network policy is on.
      # A configuration from the dependency opens no receiver ports.
      ports = if settings == null then [ ] else receiverPorts settings;

      # The labels the operator puts on this resource's pods.
      podSelector = prometheusOperator.out.operandSelectors.alertmanager name;

      baseSpec = {
        inherit replicas;
        image = kix.image.ref config.image;
        version = builtins.unsafeDiscardStringContext config.image.tag;
        serviceAccountName = self.serviceAccount.out.name;
        serviceName = self.service.out.name;
        resources = config.resources;
        configSecret = if configDep != null then configDep.out.name else self.configSecret.out.name;
      }
      // lib.optionalAttrs (config.image.pullPolicy != null) {
        imagePullPolicy = config.image.pullPolicy;
      }
      // lib.optionalAttrs (config.storage.size != null) {
        storage.volumeClaimTemplate.spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = toString config.storage.size;
        }
        // lib.optionalAttrs (storageClasses != null) {
          inherit (storageClasses.out) storageClassName;
        };
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
        inherit scope;
        locked = [
          [ "image" ]
          [ "version" ]
          [ "imagePullPolicy" ]
          [ "replicas" ]
          [ "resources" ]
          [ "topologySpreadConstraints" ]
          [ "serviceAccountName" ]
          [ "serviceName" ]
          [ "storage" ]
          [ "configSecret" ]
          # The operator then ignores configSecret.
          [ "alertmanagerConfiguration" ]
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

      configSecret =
        if settings == null then
          null
        else
          scope.mkSecret {
            name = "${name}-config";
            stringData."alertmanager.yaml" = builtins.toJSON settings;
            # Configuration Alertmanager reads from a Secret; the credential
            # keys the package knows are refused above.
            meta.classification = "configuration";
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

      # The governing Service of the operator's StatefulSet, named in
      # `spec.serviceName`. The operator gives each peer its
      # `<pod>.<service>` address for gossip, so the Service is headless and
      # publishes pods before they are ready. Check 4 cannot see the
      # operator's pods; the annotation names the resource that creates them.
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        annotations.${kix.keys.operandOf} = "monitoring.coreos.com/Alertmanager/${name}";
        spec = {
          clusterIP = "None";
          publishNotReadyAddresses = true;
          selector = podSelector;
          ports = [
            {
              name = "web";
              port = webPort;
              targetPort = webPort;
              protocol = "TCP";
            }
          ];
        };
      };

      selfMonitor =
        if config.metrics.enabled then
          prometheusOperator.out.mkServiceMonitor scope {
            inherit name;
            spec = {
              # A Service's out.selector is its metadata labels, which a
              # ServiceMonitor matches.
              selector.matchLabels = self.service.out.selector;
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
          self.alertmanager
        ]
        ++ builtins.filter (p: p != null) [
          self.configSecret
          self.egress
          self.peerIngress
          self.podDisruptionBudget
        ];
        out = {
          version = kix.image.version config.image;
          namespace = ns;
          portName = "web";
          serviceUrl = self.service.out.url { };
          # The operator runs this image in a StatefulSet that Kix does not
          # render.
          extraImages = [ (kix.image.ref config.image) ];
        };
      };
    };
}

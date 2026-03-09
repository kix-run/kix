# CoreDNS resource construction and config wiring.
#
# This is a plain function (not a NixOS module) called by mkChartModule.
# It receives kixlib' (chart-scoped) and labels from mkChartModule, plus
# the full module environment for cross-references.
#
# Returns { manifestList, extraConfig } where:
#   - manifestList: resources to serialize into config.manifests
#   - extraConfig: registry, monitoring, networkPolicies declarations
#
# Source Helm chart: coredns/coredns (v1.45.0, appVersion 1.13.1)

{
  lib,
  config,
  kixlib,
  kixlib',
  cfg,
  labels,
  ...
}:

let
  # Extracted: used in registry, monitoring target, and potentially elsewhere.
  hasPrometheus = builtins.any (s: builtins.any (p: p.name == "prometheus") s.plugins) cfg.servers;

  # --- Corefile builder ---
  # Generates the CoreDNS configuration file from the servers option.
  # Mirrors the Helm chart's configmap.yaml template logic.

  buildCorefile =
    let
      inherit (lib)
        concatStringsSep
        optionalString
        concatMapStrings
        splitString
        ;

      renderZone = zone: (if zone.scheme != null then zone.scheme else "") + zone.zone;
      renderZones = zones: if zones == [ ] then "." else concatStringsSep " " (map renderZone zones);

      renderPlugin =
        plugin:
        let
          params = optionalString (plugin.parameters != null) (" " + plugin.parameters);
          block = optionalString (plugin.configBlock != null) (
            " {\n"
            + concatMapStrings (line: "        " + line + "\n") (splitString "\n" plugin.configBlock)
            + "    }"
          );
        in
        "    " + plugin.name + params + block + "\n";

      renderServer =
        server:
        let
          zones = renderZones server.zones;
          port = optionalString (server.port != null) (":" + toString server.port);
          plugins = concatStringsSep "" (map renderPlugin server.plugins);
          # No trailing newline — concatStringsSep handles separation between servers,
          # and we don't want an extra newline at the end (Helm doesn't produce one).
        in
        zones + port + " {\n" + plugins + "}";

    in
    concatStringsSep "\n" (map renderServer cfg.servers);

  # --- Port derivation ---
  # Derives service/container ports from server blocks, matching the Helm
  # chart's _helpers.tpl coredns.servicePorts / coredns.containerPorts logic.
  derivePorts =
    let
      inherit (lib)
        flatten
        concatMap
        groupBy
        mapAttrs
        any
        optional
        ;

      zoneToProtocol =
        server: zone:
        let
          scheme = if zone.scheme != null then zone.scheme else "";
        in
        {
          port = toString server.port;
          istcp =
            (zone.use_tcp or false)
            || (builtins.elem scheme [
              "tls://"
              "grpc://"
              "https://"
            ]);
          isudp = builtins.elem scheme [
            "dns://"
            ""
          ];
        };

      pluginToProtocol =
        plugin:
        if plugin.name == "prometheus" && plugin.parameters != null then
          let
            port = lib.last (lib.splitString ":" (toString plugin.parameters));
          in
          [
            {
              inherit port;
              istcp = true;
              isudp = false;
            }
          ]
        else
          [ ];

      zoneReqs = concatMap (server: map (zoneToProtocol server) server.zones) cfg.servers;
      zoneGrouped = groupBy (r: r.port) zoneReqs;
      allReqs = zoneReqs ++ concatMap (server: concatMap pluginToProtocol server.plugins) cfg.servers;
      allGrouped = groupBy (r: r.port) allReqs;

      mergeProtocols = port: reqs: {
        inherit port;
        istcp = any (r: r.istcp) reqs;
        isudp = any (r: r.isudp) reqs || (!any (r: r.istcp) reqs && !any (r: r.isudp) reqs);
      };

      zoneMerged = mapAttrs mergeProtocols zoneGrouped;
      allMerged = mapAttrs mergeProtocols allGrouped;

      toServicePorts =
        portConfig:
        (optional portConfig.isudp {
          port = lib.toInt portConfig.port;
          targetPort = lib.toInt portConfig.port;
          protocol = "UDP";
          name = "udp-${portConfig.port}";
        })
        ++ (optional portConfig.istcp {
          port = lib.toInt portConfig.port;
          targetPort = lib.toInt portConfig.port;
          protocol = "TCP";
          name = "tcp-${portConfig.port}";
        });

      toContainerPorts =
        portConfig:
        (optional portConfig.isudp {
          containerPort = lib.toInt portConfig.port;
          protocol = "UDP";
          name = "udp-${portConfig.port}";
        })
        ++ (optional portConfig.istcp {
          containerPort = lib.toInt portConfig.port;
          protocol = "TCP";
          name = "tcp-${portConfig.port}";
        });

    in
    {
      servicePorts = flatten (map toServicePorts (builtins.attrValues zoneMerged));
      containerPorts = flatten (map toContainerPorts (builtins.attrValues allMerged));
    };

  ports = derivePorts;

  # --- Labels ---
  # CoreDNS adds cluster-service labels as extras and a coredns-specific
  # "k8s-app" selector label when isClusterService is true.
  # We extend the labels provided by mkChartModule.
  selectorLabels =
    labels.selector
    // lib.optionalAttrs cfg.isClusterService {
      "k8s-app" = "coredns";
    };

  allLabels =
    labels.all
    // lib.optionalAttrs cfg.isClusterService {
      "kubernetes.io/cluster-service" = "true";
      "kubernetes.io/name" = "CoreDNS";
      "k8s-app" = "coredns";
    };

  # Override kixlib' to use coredns-specific labels (with cluster-service extras).
  kixlibCoredns = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = allLabels;
    name = "coredns";
  };

  # FQDN used in registry endpoints.
  corednsFqdn = kixlib.mkFqdn {
    name = "coredns";
    namespace = cfg.namespace;
    clusterDomain = cfg.clusterDomain;
  };

  # --- Resource construction ---

  sa = kixlibCoredns.rbac.mkServiceAccount { };

  clusterRole = kixlibCoredns.rbac.mkClusterRole {
    rules = [
      {
        apiGroups = [ "" ];
        resources = [
          "endpoints"
          "services"
          "pods"
          "namespaces"
        ];
        verbs = [
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "discovery.k8s.io" ];
        resources = [ "endpointslices" ];
        verbs = [
          "list"
          "watch"
        ];
      }
    ];
  };

  serviceAccountName = if cfg.serviceAccount.create then kixlibCoredns.resourceName sa else "default";

  binding = kixlibCoredns.rbac.mkClusterRoleBindingWith {
    inherit clusterRole;
    serviceAccount = sa;
    subjects = [
      {
        kind = "ServiceAccount";
        name = serviceAccountName;
        namespace = cfg.namespace;
      }
    ];
  };

  coreDnsConfigMap =
    kixlibCoredns.configMap.mkConfigMap { }
    |> kixlibCoredns.configMap.withEntry "Corefile" buildCorefile;

  configVolume =
    coreDnsConfigMap
    |> kixlibCoredns.configMap.asVolume {
      name = "config-volume";
      items = [
        {
          key = "Corefile";
          path = "Corefile";
        }
      ]
      ++ map (zf: {
        key = zf.filename;
        path = zf.filename;
      }) cfg.zoneFiles;
    };

  container =
    kixlibCoredns.pod.mkContainer {
      name = "coredns";
      image = kixlib.imageRef cfg.image;
      imagePullPolicy = cfg.image.pullPolicy;
      args = [
        "-conf"
        "/etc/coredns/Corefile"
      ];
      resources = cfg.resources;
      ports = ports.containerPorts;
      securityContext = cfg.securityContext;
    }
    |> kixlibCoredns.pod.withVolumeMount {
      name = configVolume.name;
      mountPath = "/etc/coredns";
    }
    |> (
      c:
      if cfg.livenessProbe.enabled then
        kixlibCoredns.pod.withLivenessProbe {
          httpGet = {
            path = "/health";
            port = 8080;
            scheme = "HTTP";
          };
          inherit (cfg.livenessProbe)
            initialDelaySeconds
            periodSeconds
            timeoutSeconds
            failureThreshold
            successThreshold
            ;
        } c
      else
        c
    )
    |> (
      c:
      if cfg.readinessProbe.enabled then
        kixlibCoredns.pod.withReadinessProbe {
          httpGet = {
            path = "/ready";
            port = 8181;
            scheme = "HTTP";
          };
          inherit (cfg.readinessProbe)
            initialDelaySeconds
            periodSeconds
            timeoutSeconds
            failureThreshold
            successThreshold
            ;
        } c
      else
        c
    );

  # Capability output labels for the metrics Service.
  # Guard MUST match the mkIf on capabilities.monitoring.coredns declaration below.
  # If the guard drifts from the target declaration, the chart crashes when monitoring
  # is disabled (attribute-missing on a non-existent target). See doc 12 rule #10.
  monitoringLabels =
    if (hasPrometheus && cfg.prometheus.service.enabled && cfg.prometheus.monitor.enabled) then
      config.capabilities.monitoring.coredns.output.labels
    else
      { };
  monitoringAnnotations =
    if (hasPrometheus && cfg.prometheus.service.enabled && cfg.prometheus.monitor.enabled) then
      config.capabilities.monitoring.coredns.output.annotations
    else
      { };

  pdbEnabled =
    cfg.podDisruptionBudget.minAvailable != null || cfg.podDisruptionBudget.maxUnavailable != null;

  # --- Main resource group: Deployment + Service + optional HPA/PDB/metrics ---
  # Pipeline replaces 5 separate resource definitions (deployment, service,
  # metricsService, pdb, hpa) with a single composition chain.
  inherit (kixlibCoredns.combinators)
    mkServiceDeployment
    optionalPipe
    withAutoscaler
    withPodDisruptionBudget
    withMetrics
    groupToManifestList
    ;

  mainGroup =
    mkServiceDeployment {
      name = "coredns";
      containers = [ container ];
      inherit selectorLabels;
      servicePorts = ports.servicePorts;
      replicas = if cfg.hpa.enabled || cfg.autoscaler.enabled then null else cfg.replicaCount;
      serviceType = cfg.serviceType;
      strategy = {
        type = "RollingUpdate";
        rollingUpdate = {
          maxUnavailable = 1;
          maxSurge = "25%";
        };
      };
      volumes = [ configVolume ];
      inherit serviceAccountName;
      deploymentLabels = {
        "app.kubernetes.io/version" = cfg.image.tag;
      };
      podAnnotations = lib.optionalAttrs cfg.isClusterService {
        "scheduler.alpha.kubernetes.io/tolerations" =
          ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
      };
      podSpec = {
        terminationGracePeriodSeconds = 30;
      }
      // lib.optionalAttrs cfg.isClusterService { dnsPolicy = "Default"; };
    }
    |> optionalPipe (hasPrometheus && cfg.prometheus.service.enabled) (withMetrics {
      workloadKey = "coredns-deployment";
      metricsName = "coredns-service-metrics";
      metricsServiceName = "coredns-metrics";
      metricsPort = 9153;
      monitoringLabels = monitoringLabels;
      monitoringAnnotations = monitoringAnnotations;
      extraServiceAnnotations = cfg.prometheus.service.annotations;
    })
    |> optionalPipe cfg.hpa.enabled (withAutoscaler {
      workloadKey = "coredns-deployment";
      hpaName = "coredns-hpa";
      hpaArgs = { inherit (cfg.hpa) minReplicas maxReplicas metrics; };
    })
    |> optionalPipe pdbEnabled (withPodDisruptionBudget {
      workloadKey = "coredns-deployment";
      pdbName = "coredns-poddisruptionbudget";
      pdbArgs =
        { }
        // lib.optionalAttrs (cfg.podDisruptionBudget.minAvailable != null) {
          minAvailable = cfg.podDisruptionBudget.minAvailable;
        }
        // lib.optionalAttrs (cfg.podDisruptionBudget.maxUnavailable != null) {
          maxUnavailable = cfg.podDisruptionBudget.maxUnavailable;
        };
    });

  # --- Cluster-proportional autoscaler ---
  autoscalerName = "coredns-autoscaler";

  autoscalerLabelSet = kixlib.mkLabels {
    chart = autoscalerName;
    clusterLabels = config.cluster.labels;
    extra = lib.optionalAttrs cfg.isClusterService {
      "kubernetes.io/cluster-service" = "true";
      "kubernetes.io/name" = "CoreDNS";
    };
  };

  autoscalerSelectorLabels = autoscalerLabelSet.selector // {
    "k8s-app" = autoscalerName;
  };

  autoscalerLabels = autoscalerLabelSet.all // {
    "k8s-app" = autoscalerName;
  };

  autoscalerKixlib = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = autoscalerLabels;
    name = autoscalerName;
  };

  autoscalerSa = autoscalerKixlib.rbac.mkServiceAccount { };

  autoscalerConfigObj = {
    inherit (cfg.autoscaler)
      coresPerReplica
      nodesPerReplica
      preventSinglePointFailure
      min
      max
      includeUnschedulableNodes
      ;
  };
  autoscalerConfigData = builtins.toJSON autoscalerConfigObj;

  autoscalerConfigMap =
    autoscalerKixlib.configMap.mkConfigMap { }
    |> autoscalerKixlib.configMap.withEntry "linear" autoscalerConfigData;

  autoscalerClusterRole = autoscalerKixlib.rbac.mkClusterRole {
    rules = [
      {
        apiGroups = [ "" ];
        resources = [ "nodes" ];
        verbs = [
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "replicationcontrollers/scale" ];
        verbs = [
          "get"
          "update"
        ];
      }
      {
        apiGroups = [
          "extensions"
          "apps"
        ];
        resources = [
          "deployments/scale"
          "replicasets/scale"
        ];
        verbs = [
          "get"
          "update"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "configmaps" ];
        verbs = [
          "get"
          "create"
        ];
      }
    ];
  };

  autoscalerBinding = autoscalerKixlib.rbac.mkClusterRoleBinding autoscalerClusterRole autoscalerSa;

  autoscalerContainer =
    autoscalerKixlib.pod.mkContainer {
      name = "autoscaler";
      image = kixlib.imageRef cfg.autoscaler.image;
      imagePullPolicy = cfg.autoscaler.image.pullPolicy;
      resources = cfg.autoscaler.resources;
      command = [
        "/cluster-proportional-autoscaler"
        "--namespace=${cfg.namespace}"
        "--configmap=${autoscalerName}"
        "--target=Deployment/coredns"
        "--logtostderr=true"
        "--v=2"
      ];
    }
    |> autoscalerKixlib.pod.withLivenessProbe {
      httpGet = {
        path = "/healthz";
        port = 8080;
        scheme = "HTTP";
      };
      initialDelaySeconds = 10;
      periodSeconds = 5;
      timeoutSeconds = 5;
      successThreshold = 1;
      failureThreshold = 3;
    };

  autoscalerDeployment = autoscalerKixlib.workload.mkDeployment {
    replicas = null;
    selectorLabels = autoscalerSelectorLabels;
    template = autoscalerKixlib.pod.mkPodTemplate {
      metadata = {
        labels = autoscalerSelectorLabels;
        annotations = {
          "checksum/configmap" = builtins.hashString "sha256" autoscalerConfigData;
        }
        // lib.optionalAttrs cfg.isClusterService {
          "scheduler.alpha.kubernetes.io/tolerations" =
            ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
        };
      };
      spec = {
        containers = [ autoscalerContainer ];
        serviceAccountName = autoscalerName;
      };
    };
  };

in
{
  manifestList =
    # Main group: deployment + service + optional metrics/hpa/pdb via pipeline
    groupToManifestList mainGroup ++ [
      {
        name = "coredns-configmap";
        resource = coreDnsConfigMap;
        enable = true;
      }
      {
        name = "coredns-clusterrole";
        resource = clusterRole;
        enable = true;
      }
      {
        name = "coredns-clusterrolebinding";
        resource = binding;
        enable = true;
      }
      {
        name = "coredns-serviceaccount";
        resource = sa;
        enable = cfg.serviceAccount.create;
      }
      # Autoscaler resources — all gated on cfg.autoscaler.enabled, use their own kixlib
      {
        name = "coredns-autoscaler-serviceaccount";
        resource = autoscalerSa;
        enable = cfg.autoscaler.enabled;
        kixlib = autoscalerKixlib;
      }
      {
        name = "coredns-autoscaler-configmap";
        resource = autoscalerConfigMap;
        enable = cfg.autoscaler.enabled;
        kixlib = autoscalerKixlib;
      }
      {
        name = "coredns-autoscaler-clusterrole";
        resource = autoscalerClusterRole;
        enable = cfg.autoscaler.enabled;
        kixlib = autoscalerKixlib;
      }
      {
        name = "coredns-autoscaler-clusterrolebinding";
        resource = autoscalerBinding;
        enable = cfg.autoscaler.enabled;
        kixlib = autoscalerKixlib;
      }
      {
        name = "coredns-autoscaler-deployment";
        resource = autoscalerDeployment;
        enable = cfg.autoscaler.enabled;
        kixlib = autoscalerKixlib;
      }
    ];

  extraConfig = {
    # Level 2: service registry
    registry.coredns = {
      endpoints = {
        dns-udp = {
          host = corednsFqdn;
          port = 53;
          protocol = "dns-udp";
        };
        dns-tcp = {
          host = corednsFqdn;
          port = 53;
          protocol = "dns-tcp";
        };
      }
      // lib.optionalAttrs hasPrometheus {
        metrics = {
          host = corednsFqdn;
          port = 9153;
          protocol = "http";
        };
      };
    };

    # V4 capability: monitoring target
    # prometheus.monitor.enabled controls whether the chart declares a monitoring
    # capability — the implementation module creates ServiceMonitors and writes
    # back output labels/annotations. Guard on monitoringLabels/monitoringAnnotations
    # above MUST match this mkIf condition exactly (doc 12 rule #10).
    capabilities.monitoring.coredns =
      lib.mkIf (hasPrometheus && cfg.prometheus.service.enabled && cfg.prometheus.monitor.enabled)
        {
          serviceName = "coredns-metrics";
          namespace = cfg.namespace;
          portName = "metrics";
          port = 9153; # Known duplication with container spec — unavoidable without withMetrics (deferred)
          path = "/metrics";
          selector = selectorLabels // {
            "app.kubernetes.io/component" = "metrics";
          };
        };

    # Level 3: network policy declaration
    networkPolicies.services.coredns = {
      namespace = cfg.namespace;
      podSelector = selectorLabels;
      ingressPorts = [ 53 ];
      egressTo = [ ];
    };
  };
}

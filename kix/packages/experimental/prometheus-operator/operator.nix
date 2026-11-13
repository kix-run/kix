# The operator Deployment, its ServiceAccount and ClusterRole, and the
# optional metrics Service and ServiceMonitor.

{ kubeletService }:
{
  self,
  config,
  scope,
  lib,
  kix,
  priorityClass ? null,
  ...
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "prometheus-operator ${ns}/${name}";

  httpPort = 8080;

  # The vendored ClusterRole grants no access to discovery.k8s.io
  # EndpointSlices, which this flag makes the operator write for the
  # kubelet Service.
  endpointSliceArgs = builtins.filter (
    a: builtins.match "--?kubelet-endpointslice(=.*)?" a != null && a != "--kubelet-endpointslice=false"
  ) config.extraArgs;

  args =
    if endpointSliceArgs != [ ] then
      scope.fail {
        package = "prometheus-operator";
        option = "extraArgs";
        message = "extraArgs sets \"${builtins.head endpointSliceArgs}\", which makes the operator write EndpointSlices for the kubelet Service, and the package's ClusterRole (the upstream role in rbac/) does not grant access to EndpointSlices.";
        fix = "Remove it; the operator keeps the kubelet targets in Endpoints (--kubelet-endpoints, on by default).";
      }
    else
      baseArgs;

  baseArgs = [
    "--web.listen-address=:${toString httpPort}"
    "--kubelet-service=${kubeletService.namespace}/${kubeletService.name}"
    "--prometheus-config-reloader=${kix.image.ref config.operandImages.prometheus-config-reloader}"
  ]
  ++ kix.guardArgs {
    inherit who;
    owned = {
      "--web.listen-address" =
        "the probes and the metrics Service use port ${toString httpPort}; remove it.";
      "--kubelet-service" = "out.kubeletService names the Service it maintains; remove it.";
      "--prometheus-config-reloader" =
        "it is operandImages.prometheus-config-reloader; set that option instead.";
    };
  } config.extraArgs;

  env = kix.mkEnvVars (kix.mergeEnv { inherit who; } config.env);

  probe = {
    httpGet = {
      path = "/healthz";
      port = "http";
    };
  };
in
{
  operatorServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    inherit name;
  };

  # Upstream's ClusterRole (rbac/sources.txt). The operator reads and writes
  # Secrets and ConfigMaps in every namespace that holds a Prometheus or
  # Alertmanager resource, so the role is cluster-wide.
  operatorRbac = scope.rbac.mkClusterRoleSet scope {
    labels = scope.selectorLabels;
    subjects = [
      {
        kind = "ServiceAccount";
        name = self.operatorServiceAccount.out.name;
        namespace = ns;
      }
    ];
    roles.${name} =
      (builtins.fromJSON (builtins.readFile ./rbac/clusterrole-prometheus-operator.json)).rules;
  };

  operatorDeployment = scope.mkDeployment {
    inherit name;
    # The operator watches every monitoring.coreos.com kind and crashes until
    # the API server serves them.
    requires = builtins.attrValues self.crds;
    spec = {
      replicas = 1;
      selector.matchLabels = scope.selectorLabels;
      template.spec = {
        serviceAccountName = self.operatorServiceAccount.out.name;
        # Kubernetes' default; the operator documents no shutdown drain.
        terminationGracePeriodSeconds = 30;
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 65534;
          runAsGroup = 65534;
          fsGroup = 65534;
          seccompProfile.type = "RuntimeDefault";
        };
        containers = [
          (
            {
              name = "prometheus-operator";
              image = kix.image.ref config.image;
              imagePullPolicy = config.image.pullPolicy;
              inherit args;
              ports = [ (kix.port "http" httpPort) ];
              livenessProbe = probe // {
                initialDelaySeconds = 15;
                periodSeconds = 10;
              };
              readinessProbe = probe // {
                periodSeconds = 5;
              };
              resources = config.resources;
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = [ "ALL" ];
              };
            }
            // lib.optionalAttrs (env != [ ]) { inherit env; }
          )
        ];
        nodeSelector."kubernetes.io/os" = "linux";
      }
      // lib.optionalAttrs (priorityClass != null) {
        priorityClassName = priorityClass.out.name;
      };
    };
  };

  operatorService =
    if config.metrics.enabled then
      self.operatorDeployment
      |> kix.service.fromWorkload {
        inherit name;
        ports = [
          {
            name = "http-metrics";
            port = httpPort;
            targetPort = "http";
            protocol = "TCP";
          }
        ];
      }
      |> scope.mkResource
    else
      null;

  # The operator serves the CRDs that a ServiceMonitor needs, so it builds
  # its own monitor from its handle rather than through a `prometheus`
  # dependency on itself.
  operatorServiceMonitor =
    if config.metrics.enabled then
      self.crds.serviceMonitors.out.mkCR scope {
        inherit name;
        spec = {
          namespaceSelector.matchNames = [ ns ];
          selector.matchLabels = self.operatorService.out.selector;
          endpoints = [
            (
              {
                port = "http-metrics";
              }
              // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
            )
          ];
        };
      }
    else
      null;
}

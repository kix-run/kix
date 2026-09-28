# cert-manager CA injector: injects CA bundles into webhooks, API services, and CRDs.

{
  self,
  config,
  clusterConfig,
  scope,
  lib,
  kix,
}:
let
  common = import ./common.nix { instanceName = scope.instanceName; };
  name = scope.instanceName;
  ns = scope.namespaceName;

  inherit (scope.rbac)
    group
    core
    grant
    watch
    allow
    restrictTo
    mkClusterRoleSet
    mkRoleSet
    ;

  cm = group "cert-manager.io" [
    "certificates"
  ];
  coord = group "coordination.k8s.io" [ "leases" ];
  admreg = group "admissionregistration.k8s.io" [
    "validatingwebhookconfigurations"
    "mutatingwebhookconfigurations"
  ];
  apireg = group "apiregistration.k8s.io" [ "apiservices" ];
  apiext = group "apiextensions.k8s.io" [ "customresourcedefinitions" ];

  mkCainjectorSubject = [
    {
      kind = "ServiceAccount";
      name = self.cainjectorServiceAccount.out.name;
      namespace = ns;
    }
  ];

  cainjectorClusterRoles = mkClusterRoleSet scope {
    subjects = mkCainjectorSubject;
    labels = common.cainjectorLabels;
    roles = {
      "${name}-cainjector" = grant [
        (cm.certificates |> watch)
        (core.secrets |> watch)
        (
          core.events
          |> allow [
            "get"
            "create"
            "update"
            "patch"
          ]
        )
        (
          admreg.validatingwebhookconfigurations
          |> allow [
            "get"
            "list"
            "watch"
            "update"
            "patch"
          ]
        )
        (
          admreg.mutatingwebhookconfigurations
          |> allow [
            "get"
            "list"
            "watch"
            "update"
            "patch"
          ]
        )
        (
          apireg.apiservices
          |> allow [
            "get"
            "list"
            "watch"
            "update"
            "patch"
          ]
        )
        (
          apiext.customresourcedefinitions
          |> allow [
            "get"
            "list"
            "watch"
            "update"
            "patch"
          ]
        )
      ];
    };
  };

  cainjectorLeaderElection = mkRoleSet scope {
    subjects = mkCainjectorSubject;
    labels = common.cainjectorLabels;
    roles = {
      "${name}-cainjector:leaderelection" = grant [
        (
          coord.leases
          |> restrictTo [
            "cert-manager-cainjector-leader-election"
            "cert-manager-cainjector-leader-election-core"
          ]
          |> allow [
            "get"
            "update"
            "patch"
          ]
        )
        (coord.leases |> allow [ "create" ])
      ];
    };
  };

in
{
  # -- ServiceAccount --

  cainjectorServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-cainjector";
    labels = common.cainjectorLabels;
    extra.automountServiceAccountToken = true;
  };

  # -- Service --

  cainjectorService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-cainjector";
    labels = common.cainjectorLabels;
    spec = {
      type = "ClusterIP";
      selector = self.cainjectorDeployment.out.selector;
      ports = [
        {
          name = "http-metrics";
          port = 9402;
          protocol = "TCP";
        }
      ];
    };
  };

  # -- Deployment --

  cainjectorDeployment =
    {
      name = "${name}-cainjector";
      labels = common.cainjectorLabels;
      spec = {
        replicas = config.cainjector.replicaCount;
        selector.matchLabels = common.cainjectorLabels;
        template = {
          metadata.annotations = {
            "prometheus.io/path" = "/metrics";
            "prometheus.io/scrape" = "true";
            "prometheus.io/port" = "9402";
          };
          spec = {
            serviceAccountName = self.cainjectorServiceAccount.out.name;
            # Kubernetes' default, set explicitly; the chart (v1.17.1) sets none.
            terminationGracePeriodSeconds = 30;
            enableServiceLinks = false;
            securityContext = common.podSecurityContext;
            containers = [
              {
                name = "cert-manager-cainjector";
                image = kix.image.ref config.cainjector.image;
                imagePullPolicy = config.cainjector.image.pullPolicy;
                args = [
                  "--v=2"
                  "--leader-election-namespace=${ns}"
                ];
                ports = [
                  {
                    name = "http-metrics";
                    containerPort = 9402;
                    protocol = "TCP";
                  }
                ];
                env = [
                  {
                    name = "POD_NAMESPACE";
                    valueFrom.fieldRef = {
                      apiVersion = "v1";
                      fieldPath = "metadata.namespace";
                    };
                  }
                ];
                inherit (config.cainjector) resources;
                securityContext = common.containerSecurityContext;
              }
            ];
            nodeSelector = {
              "kubernetes.io/os" = "linux";
            };
          };
        };
      };
    }
    |> scope.mkDeployment;
}
// cainjectorClusterRoles
// cainjectorLeaderElection

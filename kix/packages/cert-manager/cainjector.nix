# cert-manager CA injector: copies CA bundles into webhook configurations,
# APIServices, and CRDs that carry a cert-manager.io/inject-ca-from*
# annotation.

{
  self,
  config,
  scope,
  lib,
  kix,
  availability,
  prometheus ? null,
  ...
}:
let
  common = import ./common.nix { inherit lib; };
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = common.who scope;
  labels = (common.labels name).cainjector;
  metricsOn = config.metrics.enabled && prometheus != null;

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
    inherit labels;
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

  # The binary fixes these lease names, whatever the instance is called.
  cainjectorLeaderElection = mkRoleSet scope {
    subjects = mkCainjectorSubject;
    inherit labels;
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
  cainjectorServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-cainjector";
    inherit labels;
    extra.automountServiceAccountToken = true;
  };

  # Exists only for scraping.
  cainjectorService =
    if metricsOn then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-cainjector";
        inherit labels;
        spec = {
          type = "ClusterIP";
          selector = self.cainjectorDeployment.out.selector;
          ports = [
            {
              name = "http-metrics";
              port = common.ports.metrics;
              protocol = "TCP";
              targetPort = common.ports.metrics;
            }
          ];
        };
      }
    else
      null;

  cainjectorDeployment =
    {
      name = "${name}-cainjector";
      inherit labels;
      spec = {
        # Leader-elected: one replica serves; from `node` up a standby keeps
        # injecting when a node is lost.
        replicas = kix.availability.pick availability {
          none = 1;
          pod = 1;
          node = 2;
          zone = 2;
        };
        selector.matchLabels = labels;
        template.spec = {
          serviceAccount = self.cainjectorServiceAccount;
          # Kubernetes' default, set because the scorecard asks every
          # workload to set it.
          terminationGracePeriodSeconds = 30;
          enableServiceLinks = false;
          securityContext = common.podSecurityContext;
          containers = [
            {
              name = "cert-manager-cainjector";
              image = kix.image.ref (
                common.checkRelease who config [
                  "cainjector"
                  "image"
                ]
              );
              imagePullPolicy = config.cainjector.image.pullPolicy;
              args = [
                "--v=2"
                "--leader-election-namespace=${ns}"
              ]
              ++ kix.guardArgs {
                inherit who;
                option = "cainjector.extraArgs";
                owned."--leader-election-namespace" =
                  "the leader-election Role lives in the instance's namespace; remove it.";
              } config.cainjector.extraArgs;
              ports = [
                {
                  name = "http-metrics";
                  containerPort = common.ports.metrics;
                  protocol = "TCP";
                }
              ];
              env = [
                {
                  name = "POD_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
              ];
              inherit (config.cainjector) resources;
              securityContext = common.containerSecurityContext;
            }
          ];
          nodeSelector."kubernetes.io/os" = "linux";
        };
      };
    }
    |> scope.mkDeployment;
}
// cainjectorClusterRoles
// cainjectorLeaderElection

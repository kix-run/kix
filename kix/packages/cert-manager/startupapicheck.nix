# cert-manager startupapicheck: post-install Job that verifies the cert-manager
# API is responsive (webhook reachable, CRDs registered) before signaling success.
#
# Upstream Helm chart runs this as a post-install hook with helm.sh/hook
# annotations. In kix we model it as a regular Job; rerunning on apply is fine
# because Job names are stable and the check is idempotent.

{
  self,
  config,
  scope,
  lib,
  kix,
  ...
}:
let
  common = import ./common.nix { instanceName = scope.instanceName; };
  name = scope.instanceName;
  ns = scope.namespaceName;

  inherit (scope.rbac)
    group
    grant
    allow
    mkRoleSet
    ;

  cm = group "cert-manager.io" [ "certificaterequests" ];

  # Helm chart uses a distinct label set for startupapicheck (app=startupapicheck
  # rather than app=cert-manager). Match it so the diff against helm-rendered
  # output is clean.
  startupLabels = {
    "app" = "startupapicheck";
    "app.kubernetes.io/name" = "startupapicheck";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "startupapicheck";
  };

  startupSubject = [
    {
      kind = "ServiceAccount";
      name = self.startupapicheckServiceAccount.out.name;
      namespace = ns;
    }
  ];

  startupRoles = mkRoleSet scope {
    subjects = startupSubject;
    labels = startupLabels;
    roles = {
      "${name}-startupapicheck:create-cert" = grant [
        (cm.certificaterequests |> allow [ "create" ])
      ];
    };
  };

in
{
  startupapicheckServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-startupapicheck";
    labels = startupLabels;
    extra.automountServiceAccountToken = true;
  };

  startupapicheckJob = scope.mkJob {
    name = "${name}-startupapicheck";
    labels = startupLabels;
    spec = {
      backoffLimit = 4;
      template = {
        metadata.labels = startupLabels;
        spec = {
          restartPolicy = "OnFailure";
          serviceAccount = self.startupapicheckServiceAccount;
          enableServiceLinks = false;
          securityContext = common.podSecurityContext;
          containers = [
            {
              name = "cert-manager-startupapicheck";
              image = kix.image.ref config.startupapicheck.image;
              imagePullPolicy = config.startupapicheck.image.pullPolicy;
              args = [
                "check"
                "api"
                "--wait=1m"
                "-v"
              ];
              securityContext = common.containerSecurityContext;
              env = [
                {
                  name = "POD_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
              ];
            }
          ];
          nodeSelector = {
            "kubernetes.io/os" = "linux";
          };
        };
      };
    };
  };
}
// startupRoles

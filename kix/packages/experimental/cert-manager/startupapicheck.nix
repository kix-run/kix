# The API check: a Job running `cmctl check api`, which succeeds once the
# API server admits cert-manager objects (CRDs served, webhook reachable,
# CA injected). The CRD handles in crds.nix make every custom resource built
# from them require this Job, and root.postHooks runs it after the root.

{
  self,
  config,
  scope,
  lib,
  kix,
  ...
}:
let
  common = import ./common.nix { inherit lib; };
  name = scope.instanceName;
  who = common.who scope;
  labels = (common.labels name).startupapicheck;

  inherit (scope.rbac)
    group
    grant
    allow
    mkRoleSet
    ;

  cm = group "cert-manager.io" [ "certificaterequests" ];

  # `check api` creates a CertificateRequest with dry-run, which the webhook
  # must admit.
  apiCheckRoles = mkRoleSet scope {
    subjects = [
      {
        kind = "ServiceAccount";
        name = self.apiCheckServiceAccount.out.name;
        namespace = scope.namespaceName;
      }
    ];
    inherit labels;
    roles."${name}-startupapicheck:create-cert" = grant [
      (cm.certificaterequests |> allow [ "create" ])
    ];
  };
in
{
  apiCheckServiceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-startupapicheck";
    inherit labels;
    extra.automountServiceAccountToken = true;
  };

  apiCheck = scope.mkJob {
    name = "${name}-startupapicheck";
    inherit labels;
    # A Job's pod template is immutable, so the deploy replaces the Job when
    # its own content changes. The checksum annotations below put the
    # content of the webhook and of what serves it into that content, so the
    # check runs again when any of them changes.
    annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
    requires = builtins.attrValues apiCheckRoles;
    spec = {
      backoffLimit = 4;
      template = {
        metadata = {
          inherit labels;
          annotations = {
            "checksum/webhook" = self.webhookDeployment.out.contentHash;
            "checksum/cainjector" = self.cainjectorDeployment.out.contentHash;
            "checksum/mutating-webhook" = self.mutatingWebhookConfiguration.out.contentHash;
            "checksum/validating-webhook" = self.validatingWebhookConfiguration.out.contentHash;
            "checksum/crd" = self.crds.certificateRequests.out.contentHash;
          };
        };
        spec = {
          restartPolicy = "OnFailure";
          serviceAccount = self.apiCheckServiceAccount;
          enableServiceLinks = false;
          securityContext = common.podSecurityContext;
          containers = [
            {
              name = "cert-manager-startupapicheck";
              image = kix.image.ref (
                common.checkRelease who config [
                  "startupapicheck"
                  "image"
                ]
              );
              imagePullPolicy = config.startupapicheck.image.pullPolicy;
              args = [
                "check"
                "api"
                "--wait=1m"
                "-v"
              ];
              securityContext = common.containerSecurityContext;
              # A ResourceQuota on requests or limits in the namespace refuses
              # a pod that does not set them, and every gated custom resource
              # waits on this Job. `check api` makes a few API calls and exits.
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "32Mi";
                };
                limits = {
                  cpu = "100m";
                  memory = "128Mi";
                };
              };
              env = [
                {
                  name = "POD_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
              ];
            }
          ];
          nodeSelector."kubernetes.io/os" = "linux";
        };
      };
    };
  };
}
// apiCheckRoles

# Tests that a CronJob's pods get the same network policies and facts as a
# Job's pods. A CronJob keeps its pod template under
# `spec.jobTemplate.spec.template`, one level deeper than other workloads.

{
  lib,
  mkCluster,
  baseInstances,
  netpolOn,
  manifests,
  ofKind,
  byName,
  ...
}:

let
  # A ServiceAccount bound to a Role, and one workload of `kind` running as
  # that account.
  workloadPackage = kind: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      let
        podTemplate = {
          metadata.labels = scope.selectorLabels;
          spec = {
            serviceAccountName = self.sa.out.name;
            restartPolicy = "Never";
            containers = [
              {
                name = "task";
                image = "task:1";
              }
            ];
          };
        };
      in
      {
        sa = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "task";
        };
        binding = scope.mkResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          name = "task";
          extra = {
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              name = "view";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.sa.out.name;
                namespace = scope.namespaceName;
              }
            ];
          };
        };
        workload =
          if kind == "Job" then
            scope.mkJob {
              name = "task";
              spec.template = podTemplate;
            }
          else
            scope.mkCronJob {
              name = "task";
              spec = {
                schedule = "0 * * * *";
                jobTemplate.spec.template = podTemplate;
              };
            };
        root = self.workload;
      };
  };

  policiesOf =
    kind:
    ofKind "CiliumNetworkPolicy" (
      manifests (mkCluster [
        baseInstances
        netpolOn
        { instances.appns.task.package = workloadPackage kind; }
      ])
    );

  apiserverPolicy = kind: byName "task-${lib.toLower kind}-task-apiserver-egress" (policiesOf kind);
in
{
  # A Job and a CronJob whose ServiceAccount is bound to a role both get a
  # policy that lets their pods reach the API server, selecting the pods by
  # their template labels.
  cronjob-network-apiserver-egress-like-a-job =
    let
      job = apiserverPolicy "Job";
      cron = apiserverPolicy "CronJob";
    in
    (
      job != null
      && cron != null
      && cron.spec.endpointSelector == job.spec.endpointSelector
      && cron.spec.endpointSelector.matchLabels != { }
    )
    || throw "apiserver egress: job=${builtins.toJSON job} cronjob=${builtins.toJSON cron} all=${
      builtins.toJSON (map (p: p.metadata.name) (policiesOf "CronJob"))
    }";
}

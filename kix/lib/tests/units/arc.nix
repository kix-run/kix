# Tests for kix/packages/arc and kix/packages/arc-runner-set: the CRD source
# tag, the runner set contract that out.mkAutoscalingRunnerSet builds, the
# parts that render only with a prometheus provider or an enforcer, and the
# builder's refusals. The controller runs in namespace `arc-systems`, the
# runner set `linux` in `arc-runners`.

{
  lib,
  kixKeys,
  mkCluster,
  netpolOn,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  arcPackage = import ../../../packages/arc;
  runnerSetPackage = import ../../../packages/arc-runner-set;
  secretRefPackage = import ../../../packages/secret-ref;

  clusterWith =
    {
      config ? { },
      keys ? [ "github_token" ],
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.arc-systems.arc.package = arcPackage;
          instances.arc-runners.github-config = {
            package = secretRefPackage;
            aliases = [ "githubConfigSecret" ];
            config = { inherit keys; };
          };
          instances.arc-runners.linux = {
            package = runnerSetPackage;
            config = {
              githubConfigUrl = "https://github.com/example/example/";
              maxRunners = 2;
            }
            // config;
          };
        }
      ]
      ++ modules
    );

  cluster = clusterWith { };
  ms = manifests cluster;
  find = kind: name: byName name (ofKind kind ms);
  arcRaw = cluster.instances.arc-systems.arc.raw;
in
{
  # Every URL in crds/sources.txt fetches from the chart tag of the
  # package's release, so the vendored CRDs match meta.version.
  arc-sources =
    let
      version =
        (arcPackage {
          inherit lib;
          scope = { };
          kix = { };
          availability = "none";
        }).meta.version;
      urls = builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
        lib.splitString "\n" (builtins.readFile ../../../packages/arc/crds/sources.txt)
      );
    in
    (builtins.length urls == 4 && builtins.all (lib.hasInfix "/gha-runner-scale-set-${version}/") urls)
    || throw "arc sources: crds/sources.txt does not fetch every CRD from gha-runner-scale-set-${version}: ${builtins.toJSON urls}";

  # The runner set carries the controller's version and names its three
  # supporting objects; those carry the cleanup finalizer and bind the
  # controller's ServiceAccount.
  arc-runner-set-contract =
    let
      ars = find "AutoscalingRunnerSet" "linux";
      sa = find "ServiceAccount" "linux-runner";
      role = find "Role" "linux-manager";
      binding = find "RoleBinding" "linux-manager";
      finalized = m: (m.metadata.finalizers or [ ]) == [ "actions.github.com/cleanup-protection" ];
      annotations = ars.metadata.annotations;
    in
    (
      ars.metadata.labels."app.kubernetes.io/version" == "0.14.2"
      && annotations."actions.github.com/cleanup-manager-role-binding" == "linux-manager"
      && annotations."actions.github.com/cleanup-manager-role-name" == "linux-manager"
      && annotations."actions.github.com/cleanup-no-permission-service-account-name" == "linux-runner"
      &&
        annotations.${kixKeys.readiness} == builtins.toJSON {
          path = "/status/phase";
          equals = "Running";
        }
      && ars.spec.githubConfigUrl == "https://github.com/example/example"
      && ars.spec.githubConfigSecret == "github-config"
      && ars.spec.template.spec.serviceAccountName == "linux-runner"
      && ars.spec.template.spec.automountServiceAccountToken == false
      && builtins.all finalized [
        sa
        role
        binding
      ]
      &&
        binding.subjects == [
          {
            kind = "ServiceAccount";
            name = "arc";
            namespace = "arc-systems";
          }
        ]
      && find "Role" "linux-runner" == null
    )
    || throw "arc runner set contract: ${builtins.toJSON { inherit ars sa binding; }}";

  # The metrics Service and the listener PodMonitor need a prometheus
  # provider; the listener and runner policies need an enforcer.
  arc-gated-parts =
    let
      enforced = manifests (clusterWith {
        modules = [ netpolOn ];
      });
      operandPolicies = builtins.filter (
        m: (m.metadata.labels or { }).${kixKeys.policyType} or null == "operator-managed-workload"
      ) enforced;
    in
    (
      arcRaw.metricsService == null
      && arcRaw.listenerPodMonitor == null
      && arcRaw.listenerEgress == null
      &&
        lib.sort lib.lessThan (map (m: m.metadata.name) operandPolicies) == [
          "arc-listener-egress"
          "linux-runner-egress"
        ]
    )
    || throw "arc gated parts: ${builtins.toJSON (map (m: m.metadata.name) operandPolicies)}";

  # `rules` adds a Role for the runner ServiceAccount and mounts its token.
  arc-runner-set-rules =
    let
      c = clusterWith {
        config.rules = [
          {
            apiGroups = [ "" ];
            resources = [ "pods" ];
            verbs = [ "get" ];
          }
        ];
      };
      cms = manifests c;
      role = byName "linux-runner" (ofKind "Role" cms);
      ars = byName "linux" (ofKind "AutoscalingRunnerSet" cms);
    in
    (
      role.rules == [
        {
          apiGroups = [ "" ];
          resources = [ "pods" ];
          verbs = [ "get" ];
        }
      ]
      && ars.spec.template.spec.automountServiceAccountToken
    )
    || throw "arc runner set rules: ${builtins.toJSON { inherit role; }}";

  arc-runner-set-refusals =
    let
      fails =
        config:
        evalFails (clusterWith {
          inherit config;
        });
    in
    (
      fails {
        minRunners = 3;
        maxRunners = 1;
      }
      && fails { githubConfigUrl = "github.com/example"; }
      && fails { githubConfigUrl = "https://github.com/a/b/c"; }
      && fails { extraSpec.githubConfigSecret = "other"; }
      && fails {
        extraSpec.template.spec.containers = [
          {
            name = "runner";
            image = "x";
          }
        ];
      }
      && evalFails (clusterWith {
        keys = [ "github_app_id" ];
      })
      && !(evalFails (clusterWith {
        keys = [
          "github_app_id"
          "github_app_installation_id"
          "github_app_private_key"
        ];
      }))
    )
    || throw "arc runner set refusals: a refused configuration evaluated, or a valid one failed";
}

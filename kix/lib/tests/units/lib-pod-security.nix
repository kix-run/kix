# Tests for the Pod Security Standards check (eval/pod-security.nix): what
# each level refuses in a pod template, and the build refusing a workload
# whose namespace enforces a level its pods break. The consumer side, where
# a platform's interface sets the level, is in lib-consumers.nix.

{
  lib,
  eval,
  mkCluster,
  baseInstances,
  evalFails,
  manifests,
  ...
}:

let
  podSecurity = import ../../eval/pod-security.nix { inherit lib; };

  deployment = spec: {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata.name = "app";
    spec.template.spec = spec;
  };

  # A container and pod that meet "restricted".
  restrictedContainer = {
    name = "app";
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
    };
  };
  restrictedPod = {
    securityContext = {
      runAsNonRoot = true;
      seccompProfile.type = "RuntimeDefault";
    };
    containers = [ restrictedContainer ];
  };

  # A container that sets non-root and nothing else.
  echoContainer = {
    name = "echo-server";
    securityContext = {
      runAsNonRoot = true;
      readOnlyRootFilesystem = true;
    };
  };

  problemsOf = level: m: map (v: "${v.where}: ${v.problem}") (podSecurity.violations level m);
  fails = level: spec: podSecurity.violations level (deployment spec) != [ ];
  passes = level: spec: podSecurity.violations level (deployment spec) == [ ];

  withContainer =
    change: restrictedPod // { containers = [ (lib.recursiveUpdate restrictedContainer change) ]; };

  echoPackage = import ../../../packages/stable/echo-server;

  # A package whose one container is `echoContainer`.
  baselinePackage = {
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkDeployment {
          name = "app";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [ (echoContainer // { image = "registry.example.com/app:1"; }) ];
            };
          };
        };
        root = self.deployment;
      };
  };
in
{
  lib-pod-security-restricted-pod-passes =
    (passes "restricted" restrictedPod && passes "baseline" restrictedPod)
    || throw "a restricted pod failed: ${builtins.toJSON (problemsOf "restricted" (deployment restrictedPod))}";

  # A container that sets runAsNonRoot only meets "baseline" and breaks
  # "restricted" on three fields.
  lib-pod-security-echo-server =
    let
      pod.containers = [ echoContainer ];
      problems = problemsOf "restricted" (deployment pod);
    in
    (
      passes "baseline" pod
      &&
        problems == [
          "container 'echo-server': securityContext.allowPrivilegeEscalation is unset; set it to false"
          "container 'echo-server': securityContext.seccompProfile.type is unset here and on the pod; set RuntimeDefault (or Localhost) on the container or in the pod's securityContext"
          "container 'echo-server': securityContext.capabilities.drop does not include ALL; set it to [ \"ALL\" ]"
        ]
    )
    || throw "unexpected echo-server problems: ${builtins.toJSON problems}";

  lib-pod-security-restricted-run-as-non-root =
    let
      unset = restrictedPod // {
        securityContext = removeAttrs restrictedPod.securityContext [ "runAsNonRoot" ];
      };
    in
    (
      fails "restricted" unset
      # The container's own setting is enough.
      && passes "restricted" (
        unset
        // {
          containers = [ (lib.recursiveUpdate restrictedContainer { securityContext.runAsNonRoot = true; }) ];
        }
      )
      # A container's false overrides the pod's true.
      && fails "restricted" (withContainer {
        securityContext.runAsNonRoot = false;
      })
      && fails "restricted" (withContainer {
        securityContext.runAsUser = 0;
      })
    )
    || throw "runAsNonRoot is checked wrongly";

  lib-pod-security-restricted-seccomp =
    let
      unset = restrictedPod // {
        securityContext = removeAttrs restrictedPod.securityContext [ "seccompProfile" ];
      };
    in
    (
      fails "restricted" unset
      && passes "restricted" (
        unset
        // {
          containers = [
            (lib.recursiveUpdate restrictedContainer { securityContext.seccompProfile.type = "Localhost"; })
          ];
        }
      )
      && fails "restricted" (withContainer {
        securityContext.seccompProfile.type = "Unconfined";
      })
      && fails "baseline" (withContainer {
        securityContext.seccompProfile.type = "Unconfined";
      })
    )
    || throw "seccompProfile is checked wrongly";

  lib-pod-security-restricted-privilege-escalation-and-capabilities =
    (
      fails "restricted" (withContainer {
        securityContext.allowPrivilegeEscalation = true;
      })
      && fails "restricted" (
        restrictedPod
        // {
          containers = [ (restrictedContainer // { securityContext.allowPrivilegeEscalation = false; }) ];
        }
      )
      && fails "restricted" (withContainer {
        securityContext.capabilities.drop = [ "NET_RAW" ];
      })
      && passes "restricted" (withContainer {
        securityContext.capabilities.add = [ "NET_BIND_SERVICE" ];
      })
      && fails "restricted" (withContainer {
        securityContext.capabilities.add = [ "CHOWN" ];
      })
      && passes "baseline" (withContainer {
        securityContext.capabilities.add = [ "CHOWN" ];
      })
    )
    || throw "allowPrivilegeEscalation or capabilities are checked wrongly";

  # An init container is checked like any other, and named as one.
  lib-pod-security-init-containers =
    let
      pod = restrictedPod // {
        initContainers = [ (echoContainer // { name = "setup"; }) ];
      };
    in
    builtins.all (lib.hasPrefix "init container 'setup': ") (problemsOf "restricted" (deployment pod))
    && fails "restricted" pod
    || throw "an init container was not checked";

  lib-pod-security-baseline =
    let
      pod.containers = [ { name = "app"; } ];
      container = change: pod // { containers = [ ({ name = "app"; } // change) ]; };
    in
    (
      passes "baseline" pod
      && fails "baseline" (pod // { hostNetwork = true; })
      && fails "baseline" (pod // { hostPID = true; })
      && fails "baseline" (pod // { hostIPC = true; })
      && fails "baseline" (
        pod
        // {
          volumes = [
            {
              name = "root";
              hostPath.path = "/";
            }
          ];
        }
      )
      && fails "baseline" (container {
        securityContext.privileged = true;
      })
      && fails "baseline" (container {
        ports = [
          {
            containerPort = 80;
            hostPort = 80;
          }
        ];
      })
      && fails "baseline" (container {
        securityContext.capabilities.add = [ "SYS_ADMIN" ];
      })
      && passes "baseline" (container {
        securityContext.capabilities.add = [ "NET_BIND_SERVICE" ];
      })
      && passes "privileged" (pod // { hostNetwork = true; })
    )
    || throw "a baseline rule is checked wrongly";

  lib-pod-security-restricted-volume-types =
    fails "restricted" (
      restrictedPod
      // {
        volumes = [
          {
            name = "share";
            nfs.server = "nfs";
          }
        ];
      }
    )
    && passes "restricted" (
      restrictedPod
      // {
        volumes = [
          {
            name = "data";
            persistentVolumeClaim.claimName = "data";
          }
        ];
      }
    )
    || throw "restricted volume types are checked wrongly";

  # Every kind that creates pods, and only those.
  lib-pod-security-pod-kinds =
    let
      bad.containers = [ echoContainer ];
      found = m: podSecurity.violations "restricted" m != [ ];
    in
    (
      builtins.all found [
        {
          apiVersion = "v1";
          kind = "Pod";
          spec = bad;
        }
        {
          apiVersion = "apps/v1";
          kind = "StatefulSet";
          spec.template.spec = bad;
        }
        {
          apiVersion = "apps/v1";
          kind = "DaemonSet";
          spec.template.spec = bad;
        }
        {
          apiVersion = "batch/v1";
          kind = "Job";
          spec.template.spec = bad;
        }
        {
          apiVersion = "batch/v1";
          kind = "CronJob";
          spec.jobTemplate.spec.template.spec = bad;
        }
      ]
      && !found {
        apiVersion = "example.com/v1";
        kind = "Deployment";
        spec.template.spec = bad;
      }
    )
    || throw "a pod-creating kind was missed, or another kind checked";

  # A cluster that sets a namespace's level itself gets the same check.
  # echo-server meets "restricted".
  lib-pod-security-cluster-namespace-level =
    let
      with' =
        level: package:
        mkCluster [
          baseInstances
          {
            namespaces.web.podSecurity = level;
            instances.web.app.package = package;
          }
        ];
    in
    (
      evalFails (with' "restricted" baselinePackage)
      && builtins.deepSeq (manifests (with' "baseline" baselinePackage)) true
      && builtins.deepSeq (manifests (with' "restricted" echoPackage)) true
    )
    || throw "a baseline container built under \"restricted\", it failed under \"baseline\", or echo-server failed under \"restricted\"";
}

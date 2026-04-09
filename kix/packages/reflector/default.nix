# Reflector — emberstack/kubernetes-reflector.
#
# Copies Secrets/ConfigMaps across namespaces based on annotations on the
# source. kix uses it as the cross-namespace propagation strategy for
# operator-managed secrets (e.g. StackGres' superuser credentials), so
# consumers in other namespaces can reference them via standard secretKeyRef.
#
# This is a Helm chart wrapper (defaultValues + chart metadata only). Cluster
# definitions instantiate it via `kix.fromHelmChart`, forwarding
# `extraMeta = { provides = [ "reflection" ]; defaultAliases = [ "reflector" ]; }`
# and `rootOut = reflectorOut` so that:
#
#   - DI discovery resolves `reflector ? null` args across the cluster.
#   - Consumers call `reflector.out.reflectSecret scope { secretName; ... }`
#     to obtain the annotator bundle (ServiceAccount, Role, RoleBinding, Job)
#     owned by the consumer namespace. The builder stamps
#     `kix.dev/capability: reflection` annotations on the emitted resources
#     so the architecture scorecard rule treats them as DI-provided, not
#     hand-rolled.
#
# Chart:   https://emberstack.github.io/helm-charts
# Name:    reflector
# Version: 10.0.28
#
# Usage in cluster definition (see ludo/reflector.nix for a real example):
#
#   reflector.reflector = {
#     package = kix.fromHelmChart ({
#       chart = kix.fetchHelmChart { ... };
#       releaseName = "reflector";
#     } // (import ./packages/reflector).helmWiring);
#   };
#
# Producers that want their secret reflected either:
#   1. Call `scope.mkSecretRef { reflect = true; }` to opt the consumer
#      side into cross-namespace refs, AND
#   2. Declare a `reflector ? null` dep arg and call
#      `reflector.out.reflectSecret scope { secretName = ...; }` so the
#      annotator Job is emitted from the reflector capability owner
#      rather than hand-rolled inside the producer package.

let
  # Builder factory: returns the `root.out` attrset for a reflector
  # instance. Forwarded to `fromHelmChart` via `rootOut`. The function
  # returned from this builder takes the *consumer's* scope so the
  # annotator resources land in the consumer's namespace with the
  # consumer's managed-by labels.
  reflectorOut =
    { lib, ... }:
    {
      # `reflectSecret` — returns an attrset of four resources the
      # consumer should place into its `self`: { serviceAccount, role,
      # binding, job }. All are stamped with
      # `kix.dev/capability: reflection` so the scorecard treats the
      # bundle as capability-owned.
      reflectSecret =
        consumerScope:
        {
          secretName,
          secretNamespace ? consumerScope.namespaceName,
          reflectionAllowedNamespaces ? ".*",
          reflectionAutoNamespaces ? ".*",
          requires ? [ ],
        }:
        let
          jobName = "${secretName}-reflect";
          labels = consumerScope.selectorLabels or { };
          capAnnotations = {
            "kix.dev/capability" = "reflection";
          };
          mkResource = consumerScope.mkResource;
          saRes = mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = jobName;
            inherit labels;
            annotations = capAnnotations;
          };
          roleRes = mkResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "Role";
            name = jobName;
            inherit labels;
            annotations = capAnnotations;
            extra.rules = [
              {
                apiGroups = [ "" ];
                resources = [ "secrets" ];
                resourceNames = [ secretName ];
                verbs = [
                  "get"
                  "patch"
                  "update"
                ];
              }
            ];
          };
          bindingRes = mkResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            name = jobName;
            inherit labels;
            annotations = capAnnotations;
            extra = {
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "Role";
                name = roleRes.out.name;
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = saRes.out.name;
                  namespace = secretNamespace;
                }
              ];
            };
          };
          jobRes = mkResource {
            apiVersion = "batch/v1";
            kind = "Job";
            name = jobName;
            inherit labels;
            annotations = capAnnotations // {
              # Re-run on every apply so the annotation is reapplied if
              # the operator ever recreates the secret.
              "kix.dev/hook" = "post-deploy";
              "kix.dev/hook-delete-policy" = "before-hook-creation,hook-succeeded";
            };
            inherit requires;
            spec = {
              backoffLimit = 20;
              ttlSecondsAfterFinished = 600;
              template = {
                metadata.labels = labels;
                spec = {
                  restartPolicy = "OnFailure";
                  serviceAccountName = saRes.out.name;
                  containers = [
                    {
                      name = "annotate";
                      # Bitnami sunset their free Docker Hub repos in Aug 2025
                      # (`bitnami/kubectl` is gone). `bitnamilegacy/*` is the
                      # frozen snapshot they pushed for migration; fine for a
                      # one-shot annotator that just needs `kubectl annotate`.
                      image = "bitnamilegacy/kubectl:1.30";
                      command = [
                        "/bin/sh"
                        "-c"
                      ];
                      args = [
                        ''
                          set -e
                          echo "waiting for secret ${secretName} in namespace ${secretNamespace}..."
                          for i in $(seq 1 120); do
                            if kubectl get secret ${secretName} -n ${secretNamespace} >/dev/null 2>&1; then
                              break
                            fi
                            sleep 5
                          done
                          kubectl get secret ${secretName} -n ${secretNamespace} >/dev/null
                          kubectl annotate secret ${secretName} -n ${secretNamespace} --overwrite \
                            reflector.v1.k8s.emberstack.com/reflection-allowed=true \
                            reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces='${reflectionAllowedNamespaces}' \
                            reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
                            reflector.v1.k8s.emberstack.com/reflection-auto-namespaces='${reflectionAutoNamespaces}'
                          echo "annotated."
                        ''
                      ];
                    }
                  ];
                };
              };
            };
          };
        in
        {
          serviceAccount = saRes;
          role = roleRes;
          binding = bindingRes;
          job = jobRes;
        };
    };

in
{
  meta = {
    version = "10.0.28";
  };

  chart = {
    repo = "https://emberstack.github.io/helm-charts";
    name = "reflector";
    version = "10.0.28";
  };

  defaultValues = {
    # No special tuning — chart defaults are reasonable for a cluster-wide
    # reflection controller.
  };

  # Bundle of arguments to forward to `kix.fromHelmChart`. Keeps the
  # capability declaration + builder wiring co-located with the package.
  helmWiring = {
    extraMeta = {
      provides = [ "reflection" ];
      defaultAliases = [ "reflector" ];
    };
    rootOut = reflectorOut;
  };
}

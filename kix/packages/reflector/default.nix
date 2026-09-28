# Reflector: emberstack/kubernetes-reflector.
#
# Copies Secrets/ConfigMaps across namespaces based on annotations on the
# source. kix uses it as the cross-namespace propagation strategy for
# operator-managed secrets (e.g. StackGres' superuser credentials).
#
# Consumers call `reflector.out.reflectSecret scope { secretName; ... }`
# to obtain the annotator bundle (ServiceAccount, Role, RoleBinding, Job)
# owned by the consumer namespace.
#
# Chart:   https://emberstack.github.io/helm-charts
# Name:    reflector
# Version: 10.0.60

{
  scope,
  lib,
  kix,
}:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://emberstack.github.io/helm-charts";
    name = "reflector";
    version = "10.0.60";
    hash = "sha256-UdCVcUqJogyUYmGo1HnQ1fMxY7ZEV56+9wQSJfWOhVM=";
  };

  # Builder factory: returns a function the consumer calls with their own
  # scope so the annotator resources land in the consumer's namespace.
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
      mkResource = consumerScope.mkResource;
      saRes = mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = jobName;
        inherit labels;
      };
      roleRes = mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = jobName;
        inherit labels;
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
      jobRes = consumerScope.mkJob {
        name = jobName;
        inherit labels;
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
                  image = "bitnamilegacy/kubectl:1.33";
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 1001;
                  };
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
in
{
  meta = {
    version = "10.0.60";
    description = "Emberstack Reflector, which copies Secrets and ConfigMaps across namespaces based on annotations";
    owner = "platform";
    defaultAliases = [ "reflector" ];
    # This package owns the reflector annotation domain: resources carrying
    # annotations under it without a DI dep on this instance trip the
    # architecture.annotationDomainOwnership lint (v2_discussions/128).
    annotationDomains = [ "reflector.v1.k8s.emberstack.com" ];
  };

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = config.values or { };
        releaseName = "reflector";
      };
    in
    resources.mkParts {
      root = resources.get "Deployment" "reflector";
      out = { inherit reflectSecret; };
    };
}

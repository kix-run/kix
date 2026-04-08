# Reflector — emberstack/kubernetes-reflector.
#
# Copies Secrets/ConfigMaps across namespaces based on annotations on the
# source. kix uses it as the cross-namespace propagation strategy for
# operator-managed secrets (e.g. StackGres' superuser credentials), so
# consumers in other namespaces can reference them via standard secretKeyRef.
#
# This is a Helm chart wrapper (defaultValues + chart metadata only). Cluster
# definitions instantiate it via `kix.fromHelmChart`.
#
# Chart:   https://emberstack.github.io/helm-charts
# Name:    reflector
# Version: 10.0.28
#
# Usage in cluster definition (see ludo/base.nix for a real example):
#
#   reflector.reflector = {
#     package = kix.fromHelmChart {
#       chart = kix.fetchHelmChart {
#         repo = "https://emberstack.github.io/helm-charts";
#         name = "reflector";
#         version = "10.0.28";
#         hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
#       };
#       values = (import ./packages/reflector).defaultValues;
#       releaseName = "reflector";
#     };
#   };
#
# Producers that want their secret reflected call `scope.mkSecretRef` with
# `reflect = true`, which (a) marks the secret-helper outputs so the
# cross-namespace check is relaxed and (b) signals to the producer package
# that it should emit a one-shot annotator Job adding the
# `reflector.v1.k8s.emberstack.com/reflection-allowed` annotations to the
# operator-managed source Secret.

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
}

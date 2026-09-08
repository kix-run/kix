# kix checks: the kubeconform schema check, plus a re-export of the
# cross-resource checks for `nix flake check` callers.
#
# Imported by kix/lib/mkFlake.nix (and the lithus monorepo) as:
#   kixChecks = import ./checks.nix { inherit pkgs lib; };
#
# The 14 cross-resource checks themselves live in kix/lib/eval/validate.nix
# and run inside every cluster evaluation since 2026-09. `validateManifestSet`
# here is the throwing form over an already-evaluated `rawManifests`; it
# cannot fail on its own any more, because that eval asserts the same
# checks first. It stays so existing `checks."validate-cluster-<n>"`
# attributes keep evaluating.

{ pkgs, lib }:

rec {

  # Offline K8s JSON schemas for kubeconform — the Nix sandbox has no
  # network access, so we can't let kubeconform download schemas at
  # build time. Sparse checkout to avoid fetching the entire (~2GB) repo.
  kubernetesSchemas = pkgs.fetchgit {
    url = "https://github.com/yannh/kubernetes-json-schema.git";
    rev = "5040e4b99f6b2b6fd3801c7798cce29a077acf56";
    sparseCheckout = [ "master-standalone-strict" ];
    hash = "sha256-izt9E+RqmGuxLLwggPsRjaSx/QXHz8ZlcluiyHawikw=";
  };

  # Validate a manifest directory against K8s API schemas.
  schemaCheck =
    name: drv:
    pkgs.runCommand "schema-${name}"
      {
        nativeBuildInputs = [ pkgs.kubeconform ];
      }
      ''
        echo "Validating ${name}..."
        find ${drv} -name '*.yaml' | xargs kubeconform -strict -summary \
          -ignore-missing-schemas \
          -schema-location '${kubernetesSchemas}/master-standalone-strict/{{ .ResourceKind }}{{ .KindSuffix }}.json'
        touch $out
      '';

  # --- Cross-resource validation ---
  #
  # Pure eval-time Nix checks. No IFD, no runtime.
  #
  # Validates:
  #   1. ServiceAccount references from workloads
  #   2. RoleBinding/ClusterRoleBinding roleRef targets
  #   3. ConfigMap volume references
  #   4. Service selectors match workload pod template labels
  #   5. HPA scaleTargetRef points to existing workloads
  #   6. StatefulSet serviceName → headless Service
  #   7. No duplicate (kind, namespace, name) tuples
  #   8. managed-by label present on all resources
  #   9. Deployment/StatefulSet selector ⊆ pod template labels
  #  10. Ingress backend Service references
  #  11. Namespace existence for namespaced resources
  #  12. NetworkPolicy podSelector matches workloads
  #  13. Service named targetPort → container port name
  #  14. PodDisruptionBudget selector matches workloads
  #
  # Only validates INTERNAL references (resources created by kix).
  # External references are exempted via documented allowlists.

  # Cross-resource checks live in kix/lib/eval/validate.nix so buildCluster
  # runs them on every eval. Re-exported here for `nix flake check` callers.
  inherit (import ./lib/eval/validate.nix { inherit lib; }) validateManifestSet crossResourceFailures;

}

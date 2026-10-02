# kix checks: the kubeconform schema check.
#
# Imported by kix/lib/mkFlake.nix as:
#   kixChecks = import ./checks.nix { inherit pkgs lib; };
#
# The cross-resource checks live in kix/lib/eval/validate.nix and run inside
# every cluster evaluation, so a cluster that builds has passed them.

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

}

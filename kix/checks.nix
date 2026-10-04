# kix checks: the kubeconform schema check and the alert rule check.
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

  # Run promtool over the alert rules in a manifest directory. A
  # PrometheusRule's `spec` is a Prometheus rule file, so each one is written
  # to rules/<namespace>/<file> and checked with `promtool check rules`.
  # `ruleTests`, when not null, is a `promtool test rules` file; it runs from
  # rules/, so its `rule_files` entries are `<namespace>/<file>` as in the
  # manifest directory.
  rulesCheck =
    name: drv: ruleTests:
    pkgs.runCommand "rules-${name}"
      {
        nativeBuildInputs = [
          pkgs.yq-go
          pkgs.prometheus.cli
        ];
      }
      (
        ''
          mkdir rules
          count=0
          # A top-level `kind:` line; the PrometheusRule CRD names the kind
          # only indented under `names`.
          for f in $(grep -rlx --include='*.yaml' 'kind: PrometheusRule' ${drv} || true); do
            rel=''${f#${drv}/}
            mkdir -p "rules/$(dirname "$rel")"
            yq '.spec' "$f" > "rules/$rel"
            count=$((count + 1))
          done
          if [ "$count" -gt 0 ]; then
            find rules -name '*.yaml' -print0 | xargs -0 promtool check rules
          fi
          echo "${name}: $count PrometheusRule(s) checked."
        ''
        + lib.optionalString (ruleTests != null) ''
          cp ${ruleTests} rules/rules-test.yaml
          # promtool reads `rule_files` as globs and loads nothing from one
          # that matches no file, so a test expecting no alerts would pass.
          # stdenv sets nullglob, which would drop such an entry here too.
          shopt -u nullglob
          if [ "$(yq '.rule_files | length' rules/rules-test.yaml)" = 0 ]; then
            echo "${name}: ${baseNameOf (toString ruleTests)} lists no rule_files." >&2
            exit 1
          fi
          yq '.rule_files[]' rules/rules-test.yaml | while IFS= read -r g; do
            set -- rules/$g
            if [ ! -e "$1" ]; then
              echo "${name}: rule_files entry '$g' in ${baseNameOf (toString ruleTests)} matches no rendered PrometheusRule. Rendered: $(cd rules && find . -name '*.yaml' ! -name rules-test.yaml | sed 's|^\./||' | tr '\n' ' ')" >&2
              exit 1
            fi
          done
          (cd rules && promtool test rules rules-test.yaml) 2>&1 | tee test.log
          if grep -q 'no file match pattern' test.log; then
            echo "${name}: promtool loaded no rules for an entry of rule_files." >&2
            exit 1
          fi
        ''
        + ''
          touch $out
        ''
      );

}

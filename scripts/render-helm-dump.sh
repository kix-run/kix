#!/usr/bin/env bash
# Render the nw1 dump's helm releases (one per `helm/<n>-<ns>-<chart>.yaml`
# + `.values.yaml` pair) into native K8s manifests, so the dump-vs-kix
# diff can include the helm-rendered side as well as `k8s/`.
#
# Output: one yaml file per release at $OUT/<n>-<ns>-<chart>.rendered.yaml.
# Re-run when chart versions or values change.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM_DIR="${REPO_ROOT}/nw1/migration/helm"
OUT="${REPO_ROOT}/nw1/migration/helm-rendered"
REPOS="${REPO_ROOT}/nw1/migration/helm_repos.yaml"

# Re-exec under `nix shell` if helm/yq aren't on PATH. Avoids forcing a
# devshell on every consumer.
if ! command -v helm >/dev/null || ! command -v yq >/dev/null; then
  if [[ "${KIX_HELM_NIX_SHELL:-0}" == "1" ]]; then
    echo "render-helm-dump: helm/yq still missing inside nix shell — aborting" >&2
    exit 1
  fi
  exec env KIX_HELM_NIX_SHELL=1 nix shell \
    nixpkgs#kubernetes-helm nixpkgs#yq-go \
    --command bash "${BASH_SOURCE[0]}" "$@"
fi

mkdir -p "$OUT"

# Add unique helm repos. yq dedupes by `name` (first wins).
mapfile -t repo_lines < <(yq -o=tsv '.[] | [.name, .repo_url] | @tsv' "$REPOS" | sort -u)
for line in "${repo_lines[@]}"; do
  name="${line%%	*}"
  url="${line#*	}"
  if helm repo list -o json 2>/dev/null | yq ".[] | select(.name == \"$name\") | .name" -p=json -o=tsv | grep -q .; then
    continue
  fi
  helm repo add "$name" "$url" >/dev/null
done
helm repo update >/dev/null

shopt -s nullglob
fail=0
for meta in "$HELM_DIR"/*.yaml; do
  case "$meta" in *.values.yaml) continue ;; esac
  values="${meta%.yaml}.values.yaml"
  base="$(basename "${meta%.yaml}")"
  out_file="$OUT/${base}.rendered.yaml"

  release_name="$(yq '.release_name' "$meta")"
  release_ns="$(yq '.release_namespace' "$meta")"
  chart_ref="$(yq '.chart_ref' "$meta")"
  chart_version="$(yq '.chart_version' "$meta")"

  args=(
    template "$release_name" "$chart_ref"
    --namespace "$release_ns"
    --include-crds
    # Pin kubeVersion so charts with stricter version bounds (e.g.
    # external-dns 8.7.11) render — match what the cluster actually runs.
    --kube-version "1.32.0"
  )
  if [[ "$chart_version" != "null" ]]; then
    args+=(--version "$chart_version")
  fi
  if [[ -e "$values" ]]; then
    args+=(--values "$values")
  fi
  # Bitnami's "secure images" check rejects rendering when the running
  # cluster pinned a non-Bitnami image tag. We're rendering for diff
  # purposes, not deployment, so opt out.
  if [[ "$chart_ref" == oci://registry-1.docker.io/bitnamicharts/* ]]; then
    args+=(--set global.security.allowInsecureImages=true)
  fi

  echo "render: $base ($chart_ref @ $chart_version)" >&2
  if ! helm "${args[@]}" > "$out_file" 2> "$out_file.err"; then
    echo "  FAILED — see $out_file.err" >&2
    fail=$((fail + 1))
  else
    rm -f "$out_file.err"
  fi
done

if (( fail > 0 )); then
  echo "render-helm-dump: $fail release(s) failed" >&2
  exit 1
fi
echo "render-helm-dump: wrote $OUT" >&2

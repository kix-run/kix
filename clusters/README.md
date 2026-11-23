# Clusters

This directory holds the repository's example and test cluster definitions.
Each definition configures a cluster's namespaces, package instances, and
platform settings. Each file `test-<key>.nix` is the cluster `<key>`.
[`flake.nix`](../flake.nix) maps the other keys under `clusters` to their
`.nix` files. Pass that key to `kix check`, `kix build`, and
`kix deploy`.

## Read these first

| File | Key | What it shows |
|---|---|---|
| [`example-hello.nix`](example-hello.nix) | `example-hello` | Minimal cluster: an echo web server, Valkey, and a password secret wired to Valkey by alias. Uses only stable packages. |
| [`example.nix`](example.nix) | `example` | Multi-namespace application: Immich backed by StackGres PostgreSQL and Valkey, with CoreDNS and cert-manager. |
| [`example-import.nix`](example-import.nix) | `example-import` | Immich connected to externally managed PostgreSQL, Valkey, and storage declared with `kix.mkImport`. |
| [`example-multi-env/`](example-multi-env/) | `example-multi-env-dev`, `example-multi-env-prod` | Shared `base.nix` module imported by separate development and production clusters. |
| [`homelab/`](homelab/) | `homelab-kind` | Full homelab stack on kind (Cilium, StackGres, monitoring, Loki, Valkey, Immich, and ingress-nginx). Exercises most packages and serves as the repository's smoke test. |

## Build and deploy a cluster

Run these commands from the repository root. `nix run .#kix --` builds and runs
Kix from this checkout (cluster file headers shorten this to `kix`):

```bash
nix run .#kix -- check example-hello
nix run .#kix -- build example-hello
kind create cluster
nix run .#kix -- deploy example-hello --context kind-kind
```

Two scripts inspect or validate built manifests:

- `scripts/kix-manifests.sh . <key> ./result` writes a cluster's rendered YAML
  manifests to `./result`.
- `scripts/cluster-checks.sh . <key> [<rules-test.yaml>]` validates a cluster's
  manifests against Kubernetes API schemas and runs alert-rule tests.

## Test clusters

Files and directories starting with `test-` define test clusters (except
`test-secrets/`, which holds encrypted test data). Each cluster file opens with
a comment explaining what it tests and how to build or deploy it.
They fall into five categories:

- **Library features**: dependency resolution, fragments, image pins, secrets,
  bundles, and multi-environment composition.
- **kind integration tests**: `kind`, `kind-v2`, `kind-port`, and `kind-probe`.
  Integration tests deploy `kind` and upgrade it in place to `kind-v2` or
  `kind-port` (all three set `name = "kind"`).
- **CLI fixture**: `cli-fixture` is the one cluster the tests under `cli/`
  build. It defines its two packages in the file and takes nothing from
  `kix/packages/`, so the CLI tests workflow skips a pull request that
  changes only a package or another cluster.
- **Swap fixtures**: each `test-*-swap/` directory pairs one consumer with two
  interchangeable provider packages (such as StackGres and CloudNativePG). The
  `*-swap` checks in `flake.nix` compare the consumer's manifests across both
  builds.
- **Package tests**: one package or a small group on kind, typically with all
  options enabled and Cilium enforcing default-deny network policies.

Supporting files in this directory:

- `<cluster>.rules-test.yaml`: alert-rule unit tests for the cluster file
  beside it.
- `dev-secrets/` and `test-secrets/`: SOPS-encrypted secrets for the example
  and test clusters. `dev-secrets/age-key.txt` is a public test key. Never
  reuse it outside tests.
- `pins.json`: committed image pins for the `pins` cluster (`test-pins.nix`).
- `s3-test-store.nix` and the `consumer.nix` files: shared helper packages and
  modules imported by test clusters.

## Add a cluster

1. Create the `.nix` file under `clusters/`. Start it with a header comment
   stating what the cluster tests or demonstrates, followed by its `kix build`
   and `kix deploy` commands.
2. Name the file `test-<key>.nix` and it registers itself under `<key>`. A
   file anywhere else, such as in a directory with fixtures, needs a line
   under `clusters` in [`flake.nix`](../flake.nix).
3. Stage the file with `git add`. Nix ignores untracked files in a git
   checkout.
4. Run `nix run .#kix -- check <key>`.

On pull requests that change `clusters/` or `flake.nix`, the `Bundle checks`
workflow runs `every_test_cluster_bundles`
(`cli/kix-cli/tests/commands_test.rs`) to build and bundle every cluster.

# Clusters

The cluster definitions in this repository. Each `.nix` file here describes
one Kix cluster: its namespaces, the package instances in them, and the
settings of the environment it runs on. The `clusters` list in the
repository's [`flake.nix`](../flake.nix) names every cluster the repository
builds, under the key that commands take.

## Read these first

| File | Key | What it shows |
|---|---|---|
| [`example-hello.nix`](example-hello.nix) | `example-hello` | The smallest useful cluster: a web server and a Valkey store whose password Kix finds by alias. Stable packages only. |
| [`example.nix`](example.nix) | `example` | A fuller application: Immich on a StackGres database, with Valkey, CoreDNS, and cert-manager. |
| [`example-import.nix`](example-import.nix) | `example-import` | Immich using a database and a store that already exist in the cluster, declared with `kix.mkImport`. |
| [`example-multi-env/`](example-multi-env/) | `example-multi-env-dev`, `example-multi-env-prod` | One shared base with a development and a production cluster on top. |
| [`homelab/`](homelab/) | `homelab-kind` | The full homelab service set on kind. It uses most packages, so it is the smoke test for changes to Kix. |

## Build and deploy a cluster

Run these from the repository root. `nix run .#kix --` runs the Kix built
from this checkout. The headers of the cluster files write it as `kix`.

```bash
nix run .#kix -- check example-hello
nix run .#kix -- build example-hello
kind create cluster
nix run .#kix -- deploy example-hello --context kind-kind
```

`scripts/kix-manifests.sh . <key> ./result` writes a cluster's manifests to a
directory. `scripts/cluster-checks.sh . <key> [<rules-test.yaml>]` runs the
schema check and the alert rule tests on them.

## The test clusters

Every `test-*.nix` file, and every `test-*` folder, is a test cluster. Its
header says what it checks and how to build or deploy it. The list in
`flake.nix` groups them:

- **Library features**, such as dependency resolution, fragments, pins, and
  bundles.
- **kind integration tests.** The CLI's tests deploy `kind`, then `kind-v2`
  or `kind-port` over it. All three use the cluster name `kind`.
- **Swap fixtures.** Each `test-*-swap/` folder holds two builds of one
  cluster that move a consumer from one provider package to another. The
  swap checks in the repository's `flake.nix` compare the consumer's
  manifests across the two.
- **Package tests.** One package, or a small group, with every option turned
  on, usually on kind under Cilium's default deny.

Other files:

- `<cluster>.rules-test.yaml`: tests for the alert rules of the cluster file
  beside it.
- `dev-secrets/` and `test-secrets/`: SOPS-encrypted secrets for the test
  clusters, with a test-only age key. Never reuse that key.
- `pins.json`: the image pin file of the `pins` cluster.
- `s3-test-store.nix` and the `consumer.nix` files: modules that other
  clusters import. They are not clusters on their own.

## Add a cluster

1. Write the file. Start the header with what the cluster is for, then the
   build and deploy commands.
2. Add it to the `clusters` list in `flake.nix` under a key.
3. `git add` the file, because Nix reads only files that git tracks.
4. Run `nix run .#kix -- check <key>`.

The Bundle checks workflow bundles every cluster in that list
(`every_test_cluster_bundles` in `cli/kix-cli/tests/commands_test.rs`) on
pull requests that change this folder.

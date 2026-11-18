# 2026-11-15 · `kix/lib/env.nix`, `kix/lib/vocab/compose.nix`, `kix/lib/core/resource.nix` · Three different functions are named `mkEnv`.

The name `mkEnv` means three unrelated things, and a reader cannot tell which one a line uses without knowing where `kix` came from:

- In a cluster definition, `kix.mkEnv envName envConfig instanceSets` (`kix/lib/env.nix`) builds a set of namespaces for one environment, such as `staging-web`. The docs page `how-to/author-packages-and-clusters/stamp-multi-environment-clusters-with-mkenv.mdx` and `clusters/test-multi-env.nix` use it.
- In a package, `kix.mkEnv attrs raw` (`kix/lib/vocab/compose.nix`) builds a container's `env` list: `kix.mkEnvVars attrs` followed by the raw entries. Packages such as `cnpg-database` and `stackgres-database` use it.
- On a Secret, `out.mkEnv { ENV_NAME = "key"; }` (`kix/lib/core/resource.nix`, and the `mkEnv` field of the `secret` contract) builds env entries that read the Secret's keys.

The first two are both spelled `kix.mkEnv`, so a search for the name finds both, and the docs explain them on different pages. Options:

1. Rename the namespace builder to `kix.mkEnvironment` (or `kix.mkStage`), and refuse `kix.mkEnv` in cluster definitions with an error that names it. This is a breaking change with an error, and touches one docs page and one test cluster.
2. Rename the package helper to `kix.envList` or fold it into `kix.mkEnvVars` with an optional raw list. More packages use it, so more call sites change.
3. Keep the names, and say in both reference pages that the other exists. This costs nothing and fixes only the docs.

Option 1 is the smallest change that removes the collision. The owner decides.

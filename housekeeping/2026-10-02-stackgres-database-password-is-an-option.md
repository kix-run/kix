# 2026-10-02 · `kix/packages/stackgres-database` · The role's password is three options, not a secret dependency.

`password` (a literal, which lands in the Nix store), `passwordSource`, and `passwordHash` set the role's password, and the package writes it into two Secrets, one in the consumer's namespace and one in the cluster's namespace for the bootstrap Job. A secret dependency with a declared `password` key would match every other package, but it resolves to one Secret in one namespace, and the Job needs the value next to the cluster. Kix has no way for a package to copy a dependency's Secret into a second namespace.

- 2026-11-10: `password` now warns in all three packages; 0.10 removes it.

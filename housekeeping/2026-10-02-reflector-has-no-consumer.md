# 2026-10-02 · `kix/packages/reflector` · Nothing in kixpkgs uses the reflector package any more.

stackgres-cluster was its only consumer, and it no longer copies the superuser Secret to other namespaces (apps use stackgres-database). What is left with no user: the `reflector` package, `reflector.out.reflectSecret`, `scope.mkSecretRef { reflect = true; }` and its `reflected` marker (kix/lib/scope/builders.nix, kix/lib/eval/import.nix), and the hint in kix/lib/scope/validators.nix:418 that tells users to opt in. Either delete them or give them a documented use.

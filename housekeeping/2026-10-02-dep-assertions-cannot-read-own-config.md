# 2026-10-02 · `kix/lib/meta.nix` · `deps.<x>.assertions` receives only the dependency, so it cannot compare the consumer's config with the dependency's `out`.

evaluatePackageDiagnostics calls `enrichment.assertions dep`. stackgres-database has to check its own `extensions` against `postgres.out.extensions`, so the check is a build-time throw instead of an assertion, and it fires only when the build is forced.

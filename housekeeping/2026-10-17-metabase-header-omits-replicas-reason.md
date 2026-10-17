# 2026-10-17 · `kix/packages/metabase/default.nix` · Metabase takes its replica count from `pick` inline, with no `replicas` option, and the header gives no reason.

Lines 242-247 do this. package-review O19 allows leaving out the option only when the header says the instance's `availability` override sets the count, as keycloak's header does (lines 74-76).

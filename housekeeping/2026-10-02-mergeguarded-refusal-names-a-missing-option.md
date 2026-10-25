# 2026-10-02 · `kix/lib/vocab/compose.nix` · The `kix.mergeGuarded` refusal tells the user to "Use the option that owns it." when no option owns the locked path.

`mergeGuarded` ends every refusal with that sentence (`compose.nix`, the
`throw` at the end of `mergeGuarded`). The loki package locks `auth_enabled`,
`server.http_listen_port`, and five `common.*` paths in `settings`, and no
loki option sets any of them, so `settings.auth_enabled = true` prints
`loki loki/loki: settings overrides auth_enabled, which the package sets for correctness. Use the option that owns it.`
The user looks for an option that does not exist. ORDER D3 of the package
rework rules out a per-call `hint`, so a package cannot correct the text.
A neutral remedy ("remove it from settings") or a reason per locked path
would fit every caller.
- Hit again 2026-10-02 by `kix/packages/kubevirt`: `extraSpec.infra.replicas` is locked at every availability level and no option sets it; the instance's `availability` decides it. cdi's `priorityClass` lock is owned by a dependency, not an option.
- Hit again 2026-10-02 by `kix/packages/harbor`: `registry.settings.auth` and `jobservice.settings.job_loggers` are locked because the package builds the htpasswd and the database job logger, and no option owns either path.
- Hit again 2026-10-03 by `kix/packages/falco`: a local check gives a reason for each locked path set directly, but `settings.webserver = null` replaces six locked paths and still gets the generic sentence.

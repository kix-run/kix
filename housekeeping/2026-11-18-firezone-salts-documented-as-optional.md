# 2026-11-18 · `kix/packages/experimental/firezone` · The header says LIVE_VIEW_SIGNING_SALT is optional, but Firezone 0.7 refuses to start without it.

The header's dependency list says `LIVE_VIEW_SIGNING_SALT`,
`COOKIE_SIGNING_SALT`, and `COOKIE_ENCRYPTION_SALT` are optional, and that a
salt the secret does not declare stays unset. Firezone 0.7.26 and 0.7.36 both
stop at boot with "Missing required configuration value for
'live_view_signing_salt'" when the variable is unset. A user who follows the
header omits the salt and sees a CrashLoopBackOff. Check which salts the
image requires (`runtime.exs` and `definitions.ex`), then fix the header and
the `salts` filter in `default.nix`.

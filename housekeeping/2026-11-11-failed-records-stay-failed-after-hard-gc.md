# 2026-11-11 · `kix plan` · A failed deployment whose build is missing warns on every plan, and only `kubectl patch` silences it.

`PlanEvent::FailedUnresolved` fires for each Failed record whose build is not
on this machine. `kix gc --hard` removes the objects but leaves the records
Failed, so the warning returns. The only way out is a `kubectl patch` of the
record's status that the warning prints. Kix has no command that marks such a
record Superseded.

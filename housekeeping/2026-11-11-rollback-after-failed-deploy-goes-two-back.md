# 2026-11-11 · `kix rollback` · After a failed deploy, `kix rollback` skips the build that is still Active and goes one further back.

A failed deploy leaves the previous record Active and marks its own Failed.
`kix rollback` only targets Superseded records, so its default target is older
than the build the cluster was running before the failure. Kix has no command
that applies the Active build again, other than deploying the same commit. The
deploy failure message cannot offer an undo.

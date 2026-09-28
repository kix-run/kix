# 2026-09-28 · `kix/packages/python-app` · Component images sit inside `types.anything` component options instead of `kix.options.image`.

`backend`, `frontend`, `caddy`, `redis` and the worker entries keep their
`image` records inside untyped component attrsets. A pin still renders
through `kix.image.ref`, but a misspelt field such as `digets` passes
silently, and setting one field of a component replaces the whole
component default.

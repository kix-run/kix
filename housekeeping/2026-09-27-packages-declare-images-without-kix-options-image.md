# 2026-09-27 · `kix/packages` · Most packages declare their image option by hand instead of with `kix.options.image`.

32 packages declare `image = lib.mkOption` themselves and 9 use
`kix.options.image`. The hand-written options take different shapes, and
`python-app` keeps its images inside `types.anything` component options. A pin
from `pins.get` fits only some of them, a digest is dropped wherever the
package renders `repository:tag` itself, and each package needs its own check
that a tag is set. `security.noLatestTag` catches `:latest` but not a missing
digest.

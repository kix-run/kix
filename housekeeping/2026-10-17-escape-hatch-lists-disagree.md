# 2026-10-17 · `docs-legacy/BEST-PRACTICES.md` · The escape-hatch list at lines 184-188 differs from package-review E1, and neither says why.

BEST-PRACTICES lists lib-level hatches (`extra`, `kix.untrackedRef`, `scope.mkResource`, `partsOverlays`). E1 (package-review line 279) lists package option hatches (`values`, `extraSpec`, `settings`, `extraArgs`, `env`). They describe different layers, but a reader sees two lists under one name.

# 2026-11-13 · `kix.image.version` · A tag with a suffix reports only its numbers, so a plan can show a version nobody asked for.

With `image.tag = "v0.0.0-nope"` on node-exporter, `kix plan` shows "node-exporter 1.12.1 -> 0.0.0". The suffix may name a different build (`-rc.1`, `-debian`), and the plan drops it without saying so. A prerelease tag such as `v1.2.0-rc.1` would report as the release 1.2.0.

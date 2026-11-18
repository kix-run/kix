# 2026-11-14 · `cli/kix-bundle` · A build read from a bundle has no library warnings, so `kix plan --bundle` and `kix deploy --bundle` show none.

A bundle carries the activation closure, and the build's `kix-warnings.json` is outside it, so `Build::carried` sets no warnings. `kix bundle` prints the warnings when it builds, but a person who plans or deploys the bundle in CI later sees none, and the plan file's `warnings` is empty. The bundle could carry the warnings file next to the build.

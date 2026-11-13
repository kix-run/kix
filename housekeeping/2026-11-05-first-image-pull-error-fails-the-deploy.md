# 2026-11-05 · `cli/kix/src/cluster/readiness/terminal.rs` · The deploy decides whether an image pull failure is final by matching phrases in the kubelet's message.

`classify_pull_error` (lines 161-206) checks `PERMANENT_PULL_ERRORS`, then `TRANSIENT_PULL_ERRORS`, and counts any message it does not know as permanent. "not found" matches far more than a missing image, and a DNS failure such as "no such host" counts as permanent, so a registry outage can still stop the whole deploy. On a kind deploy of `test-cnpg`, the first pull of `ghcr.io/cloudnative-pg/plugin-barman-cloud` failed, the deploy stopped and cancelled every dependant, and the kubelet pulled the image 15 seconds later. The phrase lists are the kind of heuristic CLAUDE.md asks us not to build, and every kubelet or registry wording change can break them.

Decision required from Adam:
- (a) Recommended. Treat `ErrImagePull` and `ImagePullBackOff` as not final, and show the last pull message when the readiness wait times out. A bad image name then costs the full timeout.
- (b) Count only `InvalidImageName` as final at once, and also an error that persists through N back-off cycles.
- (c) Keep the phrase lists.

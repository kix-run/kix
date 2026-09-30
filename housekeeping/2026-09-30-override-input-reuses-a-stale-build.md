# 2026-09-30 · `kix build`, `kix deploy` with `--override-input` · A new commit on the overridden input does not reach the build; kix serves its cached one.

On the monorepo's stage2, `--override-input kixpkgs git+file:///…/kixpkgs?ref=<branch>&rev=<new commit>` still rendered the previous commit's manifests (coredns without its new `runAsUser`, SGObjectStorage at the old API version), and a deploy failed on the fix it was meant to carry. `--no-cache` built the right thing. The cache key seems not to include the override.

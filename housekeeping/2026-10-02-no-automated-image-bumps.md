# 2026-10-02 · repository · Nothing proposes image or chart bumps, so pinned defaults go stale.

There is no Renovate configuration and no workflow that checks the pinned
image tags and digests in `kix/packages/*` against their registries. Most
packages only drift, but some stop working: GitHub stops sending jobs to a
runner more than 30 days behind the latest runner release, and the arc
controller turns off the runner's self-update, so `arc-runner-set`'s default
`ghcr.io/actions/actions-runner` tag fails within a month of a runner release.

# 2026-11-14 · repository · A package version bump leaves stale files that nothing connects to the package.

Changing a package's pinned version also changes files outside its folder, and no check or skill lists them. Seen on 2026-11-13 across eight packages:

- the four CLI snapshots in `cli/kix-cli/tests/snapshots/` when the package is in the example cluster, with hashes that change as well as the version, so search and replace gives wrong files;
- docs excerpts under `docs/src/command-output/`;
- unit tests in `kix/lib/tests/units/` that name the next version as one the package must refuse (`external-dns.nix`, `monitoring-stack.nix`, `kubevirt-cdi.nix`), which fail after the bump;
- `ROADMAP.md`, which cites some versions.

Of the agents that were not told, two of five found all the snapshots, and all three runs on `metrics-server` missed the roadmap line.

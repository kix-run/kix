# 169b: Ship the Kix library inside the Kix release

**Status:** Exploration
**Related:** `../archive/169_version_from_flake_lock.md` (the decision this was the alternative to), `164b_per_cluster_kix_versions.md`

Doc 169 made `flake.lock` the one place a project names its Kix. The larger alternative, recorded here so it is not lost, removes the library pin altogether.

**Ship the library inside the Kix release.** Kix carries the library in its signed archive and points the `kix` input at its own copy with `--override-input`. The version then lives only in `kix.toml`, and a program and its library match by construction. Measured on 2026-11-13: `kix/` is 20 MB (the library itself is 2.4 MB; 14 MB of the 17 MB of packages are vendored CRDs). It compresses to about 1.1 MB with zstd, xz, or brotli alike, and zstd unpacks it in 0.01 s. At ten times the packages, about 11 MB to download and 170 MB unpacked. That would need packages fetched one at a time, by content hash, lazily, as Helm does with charts. We did not choose it now, because it changes too much at once. Plain `nix` and editor tooling would read a lock that disagrees with the library Kix uses, and Kix would override an input the user declared, which surprises Nix users. It stays open as a later step. Nothing in this proposal rules it out.

## What would have to be true first

- Plain `nix`, `nix flake check`, and editor tooling read `flake.lock`, so Kix would have to keep that lock in step with the library it carries, or those tools would see a different library.
- A project that develops the library, or follows a fork, must still be able to point the `kix` input at its own copy, as development mode does today.
- At many more packages, the library (2.4 MB) ships in the release, and packages are fetched one at a time by content hash from the release's signed index. `kix list packages` would then need each package's description in that index.
- The Nix that the Kix runtime bundles matters here: Nix 2.20+ keeps downloaded archives in a Git-format cache, which stores files unchanged between versions once.

# 2026-11-19 · `kix list packages` · An experimental package is listed as `experimental.<name>`, and change records call it `experimental/<name>`.

Without a cluster, `kix list packages` reads `kixPackages` in `kix/lib/mkFlake.nix`, which names an experimental package `experimental.coredns`. Change records, `removed.toml`, and `spec.package` on a PackageInstance all write `experimental/coredns`. A script that joins the list with release notes has to translate one into the other.

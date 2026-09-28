# 2026-09-28 · `kix/lib/rules/security.nix` · No scorecard rule reports a container image that has no digest.

`security.noLatestTag` catches `:latest` only. Every hand-written package now
accepts a digest through `kix.options.image`, but a cluster that never pins
one gets no warning, so tag-only references go unnoticed.

# 2026-10-01 · `kix/lib/plugins/netpol/` · Docs still cite `lib/netpol.nix` or `kix/lib/netpol.nix`, which no longer exists.

Network policy derivation lives in `kix/lib/plugins/netpol/`, but a reader who follows the old path finds nothing.
The stale path appears in `ROADMAP.md` (twice) and `guide/03-advanced.md`.
Several open `discussions/` docs cite it too.
Find them with `git grep -n "lib/netpol\.nix"`.

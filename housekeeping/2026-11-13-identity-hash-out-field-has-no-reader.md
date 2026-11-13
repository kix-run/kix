# 2026-11-13 · `kix/lib/core/resource.nix` · `out.identityHash` is public, but no package reads it, and using it is a mistake.

`resource.nix:597` sets it. `docs/src/content/docs/reference/resources-and-out.mdx:299` lists it as a public field, and line 323 warns that it restarts pods when nothing they read has changed. The kix-migration skill (line 316) and tutorial 07 (line 81) still advertise it. No package uses it. Remove it with an `error` change record that points to `out.contentHash`, or mark it internal and drop it from the docs.

+++
kind = "changed"
+++
`kix upgrade` now marks a release note with `*` when one of your clusters uses a built-in package named in the note. Previously, it matched notes against instance names, so it missed instances with custom names (such as `postgres` for `cnpg-cluster`) and falsely marked notes when an unrelated instance shared a package's name. When upgrading from an older Kix version that does not report package IDs, `kix upgrade` lists all release notes without `*` marks.

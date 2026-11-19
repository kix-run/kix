+++
kind = "changed"
+++
`kix upgrade` now marks a release note with `*` when the note names a package that one of your clusters runs. Before, it compared the note's package names with your instance names, so it missed an instance with another name, such as `postgres` for `cnpg-cluster`, and marked an unrelated instance that shared a package's name. When the Kix version you upgrade from cannot report package ids, `kix upgrade` lists every note and marks none.

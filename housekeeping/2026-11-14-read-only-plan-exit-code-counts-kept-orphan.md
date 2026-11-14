# 2026-11-14 · `kix plan --read-only` · Exits 2 where `kix plan` exits 0, because it counts a kept orphan Job as a change.

Found testing 0.10.0-rc.4 on kind. After the bootstrap Job got a stable name,
the old Job stays on the cluster as an orphan. `kix plan example` exits 0, but
`kix plan example --read-only -o json` exits 2 and lists the old Job under
`packages.changed[immich/immich-db].removed_resources`. The two modes decide
"has changes" in different places. One owner for that decision would keep the
exit codes in step.

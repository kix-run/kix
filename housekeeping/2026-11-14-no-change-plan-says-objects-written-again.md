# 2026-11-14 · `cli/kix-cli/src/plan/render.rs` · A plan with no changes still says "3 to write" and "written again unchanged", and does not name the objects.

Found testing 0.10.0-rc.4 on kind. After a clean deploy, `kix plan example`
exits 0 with "Plan: 13 unchanged", but also prints "Objects: 3 to write, 0 to
delete" and a yellow "↻ 3 written again unchanged: an earlier deployment on
this cluster already ran the exact same manifest" (render.rs:68). "Ran" reads
as if Jobs run again, and the reader cannot tell which 3 objects. With
`--reconcile` the line says 125, which misleads there too. The line should
name the objects, or be left out when it describes no change to the cluster.

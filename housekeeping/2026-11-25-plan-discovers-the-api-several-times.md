# 2026-11-25 · `cli/kix/src/plan/` · One connected plan runs API discovery three or four times.

`Baseline::of_cluster`, `read_live` in `planner.rs`, `keep_shared`, and
`Target::connect` each call `discovery::discover_resources` on their own. One
discovery is one request per API group version, often 30 to 60 on a cluster
with operators, so discovery costs more requests than the lists and reads the
plan makes. Discovering once per command and passing the result along would
remove most of them.

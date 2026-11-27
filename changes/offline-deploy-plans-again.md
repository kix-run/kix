+++
kind = "error"
cli = ["kix deploy --offline"]
id = "K3811"
+++
`kix deploy --offline` now plans the deploy again from the live cluster once you confirm the offline plan and it connects, and runs the new plan only when it writes and deletes the same objects as the plan you confirmed. When the two plans differ, for example because a resource changed on the cluster or an earlier deploy stopped part way, the deploy stops with `[K3811]` before it takes the deploy lock and applies nothing. The error lists the objects that only one of the two plans writes or deletes. Run `kix deploy` without `--offline` to see and confirm the full plan.

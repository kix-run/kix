+++
kind = "error"
cli = ["kix deploy --offline"]
id = "K3811"
+++
After you confirm an offline plan in `kix deploy --offline`, Kix connects to the cluster, plans again against live cluster state, and stops with `[K3811]` before taking the deploy lock if the live plan would write or delete different objects than the plan you confirmed (for example, because an object drifted on the cluster or an earlier deploy stopped midway). Nothing is applied, and the error lists the objects that only one of the two plans writes or deletes; run `kix deploy` without `--offline` to review and confirm the full live plan.

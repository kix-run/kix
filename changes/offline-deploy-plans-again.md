+++
kind = "error"
cli = ["kix deploy --offline"]
id = "K3811"
+++
If `kix deploy --offline` stops with `[K3811]`, run `kix deploy` without `--offline` to review and confirm the full live plan. After you confirm an offline plan, `kix deploy --offline` now connects to the cluster and plans again against live cluster state before taking the deploy lock. If the live plan would write or delete different objects than the plan you confirmed (for example, because an object drifted on the cluster or an earlier deploy stopped midway), or would overwrite a change made on the cluster even when that plan already writes the object, Kix stops with `[K3811]`, lists the differing objects, and applies nothing.

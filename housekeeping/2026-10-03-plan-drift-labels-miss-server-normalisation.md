# 2026-10-03 · `cli/kix-cli/src/plan/origin.rs` · Drift labels compare the raw deployed manifest with the server-normalised live object.

`ThreeWay::label` reads the deployed side from the build and the live side
from the apiserver. A value the server rewrites, such as `cpu: 0.5` stored as
`500m` or a port given as a string, reads as drift. A commit that changes that
field gets a false `reverts_drift` label and a spurious drift entry.

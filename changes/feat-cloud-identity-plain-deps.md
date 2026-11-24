+++
kind = "changed"
library = ["deps"]
+++
Cluster definitions need no changes. If you maintain custom packages whose `assertions` inspect `deps.<name>`, check that they handle direct values (any value other than `ref` or a list of `ref`s). Package `assertions` now receive direct values passed in `deps.<name>`, matching `build`, instead of omitting them from `deps`.

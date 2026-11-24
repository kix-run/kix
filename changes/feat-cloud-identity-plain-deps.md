+++
kind = "changed"
library = ["deps"]
+++
If you write custom packages whose `assertions` read `deps.<name>`, verify that they handle direct values (any value other than `ref` or a list of `ref`s); cluster definitions need no changes. Package `assertions` now receive direct values set in `deps.<name>`, matching `build`, instead of seeing those dependencies as unset.

+++
kind = "fixed"
library = ["deps"]
+++
No changes are required. Passing a direct value (such as a cloud identity from `kix.cloudIdentity.*`) to a required dependency in `deps.<name>` now succeeds when the package's `build` reads `config`. Previously, evaluation failed with "dependency '<name>' has no matching instance".

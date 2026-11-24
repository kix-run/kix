+++
kind = "fixed"
library = ["deps"]
+++
A plain value in `deps.<name>`, such as a cloud identity, now works for a required dependency even when the package's build reads `config`. Before, evaluation failed with "dependency '<name>' has no matching instance".

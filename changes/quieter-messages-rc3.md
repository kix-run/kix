+++
kind = "changed"
+++
More of Kix's messages are short and plain. An error thrown by a Kix package or contract, such as a missing `password` dependency, now shows only the message, not the Kix source lines around it. When a dependency that must be a secret is something else, the error names what it is. `kix check` puts any long detail under its table, so the table fits a terminal. Warnings printed without `-v` no longer carry a timestamp and a module path, and Kix no longer prints the Kubernetes client's own log line for each failed request it retries. When no kubeconfig context is set and you pass no `--context`, Kix says so and how to choose one.

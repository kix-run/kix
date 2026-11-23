+++
kind = "fixed"
packages = ["experimental/rabbitmq-operator"]
+++
`rabbitmq-operator` now lets the operator use up to one CPU core by default. Its CPU limit was its 200m request, which throttled the operator whenever it reconciled many objects at once. The request stays at 200m. The first deploy after you upgrade restarts the operator pod once. Instances that set `resources` keep their own values.

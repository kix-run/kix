# 2026-09-19 · `kix/packages/kubevirt` · A package cannot ask for the Pod Security level its own pods need, so the kubevirt namespace ships without the `privileged` label upstream sets.

Upstream's `kubevirt-operator.yaml` labels its namespace
`pod-security.kubernetes.io/enforce: privileged`, because virt-handler
runs a privileged pod. A kix cluster creates that namespace from
`namespaces.kubevirt = { }`, and the package has no way to say what
level it needs. Nothing fails today: a namespace with no enforce label
is privileged by default, and kind sets no cluster-wide default. It
fails the day a cluster turns on a restricted default, and the error
will name virt-handler rather than the missing label.

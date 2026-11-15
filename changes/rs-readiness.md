+++
kind = "fixed"
+++
A deploy now waits for the Kubernetes API server to serve a CRD's resource kind before applying resources that depend on it. Before, Kix waited at most five seconds after `Established=True` and then continued anyway, so custom resources could fail to apply if the API server did not serve the kind yet. For an imported resource whose kind the API server does not serve yet, Kix now waits until the kind is served before looking up the resource. Before, Kix assumed the kind was namespaced and guessed its API path from the kind name, so cluster-scoped imports or kinds with irregular plural names could time out even after the resource existed.

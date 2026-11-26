+++
kind = "fixed"
packages = ["experimental/cert-manager"]
+++
Under generated network policy, cert-manager admits calls from the API server only on its webhook pods and only on `webhook.securePort`. Before, the controller, cainjector, and startupapicheck pods also accepted calls from the API server, on every port.

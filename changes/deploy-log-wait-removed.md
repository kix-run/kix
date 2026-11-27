+++
kind = "silent"
cli = ["kix deploy --log-format json"]
+++
If a script or tool reads `kix deploy --log-format json`, remove any handling for `"kind": "wait"` on node events. Kix previously emitted `"kind": "wait"` while a consumer cluster waited for another Kix cluster to install Kix's CustomResourceDefinitions. Kix now installs those CRDs itself when a deploy starts.

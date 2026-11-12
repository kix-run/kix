+++
kind = "fixed"
packages = ["echo-server"]
+++
Changing `message` on an `echo-server` instance now restarts its pods, so they serve the new text. Before, the deploy updated the ConfigMap, but nginx kept the old text until the pods restarted for some other reason. The first deploy after upgrading restarts every `echo-server` pod once.

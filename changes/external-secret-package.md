+++
kind = "added"
packages = ["experimental/external-secret"]
+++
New experimental package `external-secret`. One instance renders one
ExternalSecret for the External Secrets Operator, reading each key of a Secret
from one SecretStore or ClusterSecretStore. A package that takes a secret
dependency can take the instance in place of `secret` or `secret-ref`: it
reads the declared keys through `keyRef`, `mkEnv`, `envFrom`, and `volume`,
and the deploy waits for the first sync before it starts the package.

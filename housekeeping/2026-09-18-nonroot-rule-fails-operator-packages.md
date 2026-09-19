# 2026-09-18 · `kix/packages/{cert-manager,prometheus-operator,stackgres-operator}` · `security.nonRoot` fails the build as soon as a cluster enables the full rule set.

None of the three operator packages sets `runAsNonRoot`, and the rule's
default severity is error. `clusters/test-harbor.nix` downgrades it to a
warning to build at all. Either the packages or the default severity is
wrong.

# 2026-09-28 · `kix/packages/cdi` · The CDI operand images ignore `image.repository`.

`kix/packages/cdi/default.nix` builds `APISERVER_IMAGE`, `CONTROLLER_IMAGE`, `IMPORTER_IMAGE` and the other operand env vars as `quay.io/kubevirt/cdi-*:${config.image.tag}`. An instance that points `image.repository` at a mirror moves only cdi-operator, and the operands still pull from quay.io.

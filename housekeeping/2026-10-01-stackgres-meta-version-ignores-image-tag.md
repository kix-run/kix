# 2026-10-01 · `kix/packages/stackgres-operator` · `meta.version` stays "1.19.0" when an instance overrides the operator image tag.

`operator.image.tag` is an option, and `meta.version` is a literal. An instance that pins another tag runs a different operator from the one the meta, the diff's version delta, and any `compatibleWith` check describe. The restapi and adminui tags are separate options with the same default, so they can drift from the operator too.

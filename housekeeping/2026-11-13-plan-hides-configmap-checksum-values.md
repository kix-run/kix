# 2026-11-13 · `kix plan` · The plan hides every `checksum/*` pod annotation as a secret, including ConfigMap checksums.

A ConfigMap change shows `~ $.spec.template.metadata.annotations.checksum/configMap: old: "(secret, not shown)" new: "(secret, changed, not shown)"` on the valkey StatefulSet. The value is `out.contentHash` of a ConfigMap whose diff the same plan prints in full. Reading "secret" next to a ConfigMap makes a reviewer wonder whether a Secret changed.

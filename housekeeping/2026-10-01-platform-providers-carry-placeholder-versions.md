# 2026-10-01 · `kix/packages/cilium-*`, `kix/lib/flavors` · Platform providers report words, not versions, as their version.

`cilium-rke2` has `meta.version = "rke2-bundled"`, `cilium-external` has `"external"`, and the lithus flavor's storage package has `"lithus-flavor"`. Imports such as `platform-dns` carry no version at all. `meta.compatibleWith` reads these through `dep._meta.version or dep.out.version`, so a version range on one of them is compared against a word. See doc 155 §5.3.

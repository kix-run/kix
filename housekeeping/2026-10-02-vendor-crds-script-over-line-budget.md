# 2026-10-02 · `scripts/vendor-crds.py` · The vendoring driver and module are 334 lines, over the "roughly 300" budget in doc 146 §5.3.

Vendoring operator roles under `<pkg>/rbac/` (kubevirt, cdi) added about 60 lines to `scripts/vendor-crds.py` and `scripts/vendor_crds/__init__.py`. Doc 146 says that past roughly 300 lines "the special case belongs in a package or the design is wrong", and the crd-vendoring skill's review step checks the same number, so every review of the script now reports it.

Decision required from Adam: raise the budget to about 340 lines in doc 146 §5.3 and the crd-vendoring skill, or move role vendoring out of the shared script (v2_discussions/146_crd_vendoring_and_upgrades.md).

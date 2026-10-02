# 2026-10-02 · `kix/packages/cdi` · CDI's cloner and upload server pods have no `out.operandSelectors` entry.

`cdi.out.operandSelectors` names the importer pods and cdi-deployment and
cdi-uploadproxy, but not the cloner source pods or the upload server pods CDI
starts in a DataVolume's namespace (`cdi.kubevirt.io: cdi-upload-server`).
Under default deny a clone between namespaces or an upload through
cdi-uploadproxy needs a policy for those pods, and no builder gives the
labels. Add them, and a builder like `out.mkImporterPolicy`, once a consumer
clones or uploads.

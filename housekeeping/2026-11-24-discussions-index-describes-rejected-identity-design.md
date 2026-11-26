# 2026-11-24 · `discussions/README.md` · The index entry for doc 177 describes a rejected design and still says "Decision required".

In `discussions/README.md`, the row for `177_workload_cloud_identity.md` says "Decision required" and calls "an instance attribute `cloudIdentity`" the recommended design. Doc 177 rejected that design (C) after building it; Kix shipped design D, where the cluster sets a cloud identity on a package's credentials dependency (`deps.<name> = kix.cloudIdentity.<cloud> { ... }`). Readers who rely on the index will plan package changes around the rejected API.

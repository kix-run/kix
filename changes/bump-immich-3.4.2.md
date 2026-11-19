+++
kind = "silent"
packages = ["experimental/immich", "experimental/immich-machine-learning"]
touches-data = true
+++
`immich` and `immich-machine-learning` now run Immich 3.4.2 (was 3.4.1), a bug fix release. The server's Prometheus exporter now listens on `IMMICH_HOST`, or on all IPv4 and IPv6 addresses when that is unset, instead of IPv4 only, so the metrics ports answer in an IPv6 cluster. Hardware transcoding with VAAPI no longer forces the full colour range on the transcoded video, and integrity report downloads work again. The server's FUTO Backups module adds three migrations to its own tables in the database when it starts. If you go back to 3.4.1 on that database, photos, albums, and search still work, but FUTO Backups fails to start with "corrupted migrations: previously executed migration 1794492929949-InstallationId is missing". Immich's upgrade guide says "Downgrading to an earlier version, even within the same minor version, is not supported." Back up the database before you deploy if you may need to go back. To go back fully, restore that backup and deploy the older release.

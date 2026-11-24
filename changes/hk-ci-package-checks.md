+++
kind = "note"
packages = ["experimental/plausible"]
+++
You do not need to change your configuration. If `plausible` uses a
ClickHouse server with more than one replica, the first deploy after you
upgrade updates the ConfigMap for its table-replication script and restarts
each Plausible pod once. The script was only reformatted, and its behavior has
not changed.

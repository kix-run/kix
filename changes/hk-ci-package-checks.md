+++
kind = "note"
packages = ["experimental/plausible"]
+++
`plausible` reformats the script that converts its tables to replicated
ones, with no change to what the script does. On a ClickHouse server with
more than one replica, the first deploy after the upgrade restarts the
Plausible pods once, because the ConfigMap that holds the script changes.

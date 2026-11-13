+++
kind = "note"
state = true
+++
The first deploy after you upgrade runs each Job with `kix.run/rerun: on-change` one more time. Kix now records the content of such a Job in a new annotation, `kix.run/rerun-hash`, and Jobs that an earlier version deployed do not have it. Each Job that Kix's packages write is safe to run again.

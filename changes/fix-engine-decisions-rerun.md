+++
kind = "fixed"
+++
When a Job with `kix.run/rerun: on-change` runs again because its last run failed, `kix plan`, `kix deploy`, and `kix rollback` now list it with the Jobs they run again and give the failed run as the reason. Before, `kix plan` did not list it, or said that the Job had changed its own content.

+++
kind = "fixed"
cli = ["kix upgrade"]
+++
`kix upgrade` no longer moves a project to an older version when it resumes a stopped upgrade that Kix 0.10.0-rc.4 or older started. Those versions did not record which version the upgrade asked for. Without `--to`, the resume aimed at the latest stable release, which can be older than the project. Kix now stops and asks you to run `kix upgrade --to <version>`.

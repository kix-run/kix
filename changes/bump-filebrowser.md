+++
kind = "silent"
packages = ["experimental/filebrowser"]
+++
`filebrowser` now installs File Browser 2.63.23 instead of 2.63.18. The database and the files written by 2.63.18 work unchanged, and deploying 2.63.18 again reads what 2.63.23 wrote. Two behaviors differ. A resumable upload (TUS) that sends more bytes than its `Upload-Length` declares is now refused, and File Browser treats two scopes that differ only in letter case as the same scope. Before you upgrade, check that your clients declare the upload length they send. Upstream archived the project on 2026-09-01. It publishes no further releases or security fixes, so plan a replacement for an instance that faces the internet.

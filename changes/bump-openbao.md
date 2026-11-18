+++
kind = "security"
packages = ["experimental/openbao"]
workaround = "Do not enable the `cert` or `approle` auth methods, the OIDC provider, or the `ssh` or `transit` secrets engines until you upgrade. The advisories name these parts."
+++
`openbao` moves to OpenBao 2.7.2 from 2.7.1. The release fixes four advisories: GHSA-736f-82w7-hj22 (path handling in the `cert` and `approle` auth methods), GHSA-q824-44ff-f5j5 (client credentials in the OIDC provider), GHSA-h76r-48x5-36hg (wildcards in SSH identity templates), and GHSA-5pmx-2p74-x478 (key backup in the `transit` engine). The first deploy after you upgrade restarts each OpenBao pod once, one at a time. Your data carries over, and you do not need to change anything.

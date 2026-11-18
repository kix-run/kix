+++
kind = "security"
packages = ["experimental/vaultwarden"]
workaround = "Set the vaultwarden options image.tag to 1.37.5-alpine and image.digest to sha256:bbe684a02d6b0db54256ff88eac9754f4519284a7b26314afc241fd7d0918191."
+++
`vaultwarden` now runs Vaultwarden 1.37.5 instead of 1.36.0. Releases 1.37.0, 1.37.4, and 1.37.5 fix 19 security issues, published as GitHub advisories that have no CVE ids yet. One of them, on revoking organization members, is rated high. Bitwarden clients from 2026.7.0 need this release. The first deploy after you upgrade restarts the Vaultwarden pod once and adds three columns to its database. Your vault and your data folder carry over, and you do not need to change your definition. Vaultwarden now stops at startup when a setting in `env` has an invalid value, such as a negative number or a bad cron expression, so check the settings you pass before you upgrade. It now trusts the client IP header only from private addresses. If a proxy with a public address sits in front of Vaultwarden, add that proxy to `IP_HEADER_TRUSTED_PROXIES` in `env`. Going back to 1.36.0 works with a deploy of the older package, which reads the database that 1.37.5 wrote.

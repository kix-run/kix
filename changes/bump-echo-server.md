+++
kind = "security"
packages = ["echo-server"]
cve = ["CVE-2026-15176", "CVE-2026-93479", "CVE-2026-95101", "CVE-2026-97629", "CVE-2026-97205"]
workaround = "There is no workaround. The fixes are in the nginx binary, so the image must move to nginx 1.30.6 or later."
+++
`echo-server` now runs nginx 1.30.6 instead of 1.30.5. Version 1.30.6 fixes five nginx security issues, CVE-2026-15176, CVE-2026-93479, CVE-2026-95101, CVE-2026-97629, and CVE-2026-97205. The first deploy after you upgrade changes the Deployment's image, so the echo-server pods restart once.

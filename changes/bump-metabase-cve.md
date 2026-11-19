+++
kind = "security"
packages = ["experimental/metabase"]
cve = ["CVE-2026-114938"]
workaround = "Add `-XX:-UseBASE64Intrinsics` to `env.JAVA_OPTS`. Setting `env.JAVA_OPTS` replaces the package's heap setting, so set `env.JAVA_OPTS = \"-XX:MaxRAMPercentage=50 -XX:-UseBASE64Intrinsics\"` to keep it."
+++
`metabase` now runs Metabase 0.65.6. Its container starts Java with `-XX:-UseBASE64Intrinsics`, which mitigates CVE-2026-114938, a flaw in the Java compiler that lets an attacker on the network take over the Java process. Metabase adds the flag after any `JAVA_OPTS` you set through `env`, so it applies to every instance.

# 2026-09-27 · `kix/packages/stackgres-object-storage` · The `bucket` option says it defaults to the instance name, but it has no default.

A cluster that leaves `bucket` unset fails with "The option `bucket' was
accessed but has no value defined" instead of getting the documented
default. Either the description or the option is wrong.

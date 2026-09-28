# 2026-09-27 · `kix/packages/firezone` · Setting `database.passwordSecretRef` fails the cluster build, so firezone has no supported way to receive its database password.

The option turns `{ name, key }` into a raw `secretKeyRef`, and the build
rejects it: "Untracked secret reference in env 'DATABASE_PASSWORD'". Left
null, the pod gets no `DATABASE_PASSWORD` at all. The lane g2 kind test
worked around it with `env.DATABASE_PASSWORD` in plain text. immich takes a
`database` dep (stackgres-database) and reads its credentials Secret;
firezone depends on the raw `postgres` cluster instead.

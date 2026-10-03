# 2026-10-03 · `kix/lib/eval/auto.nix` · The ambiguous-provider error suggests an instance name that differs from the one auto-instantiation used.

When two packages answer a dependency, the error tells the author to declare
`instances.<namespace>.<depName>`, for example `postgres`. Auto-instantiation
had named that instance after its package, `stackgres-cluster`. An author who
follows the message on a deployed cluster renames the instance: Kix renders a
new, empty StackGres cluster called `postgres` and orphans the old one with
its data. The message should name the instance that already exists when
auto-instantiation created one, or warn that the name must match it.

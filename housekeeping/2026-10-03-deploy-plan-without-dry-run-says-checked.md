# 2026-10-03 · `cli/kix-cli/src/commands/deploy.rs` · A deploy that skips the dry run still marks conflicts and admission as checked.

`kix deploy` skips the plan's dry run when nothing is to be applied or
pruned, but failed rerun Jobs still make it run the engine. `plan::document`
then sets `conflicts` and `admission` to checked with no items, which reads as
"nothing refused" for checks that did not run. Only the text plan is printed
today, so no JSON shows it yet.

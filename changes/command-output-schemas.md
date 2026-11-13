+++
kind = "added"
+++
The JSON and YAML output of `kix build`, `check`, `graph`, `history`, `list clusters`, `list images`, `list packages`, `list resources`, `pin set`, `pin rm`, `pin check`, `pin list`, and `deploy --plan FILE --dry-run` now has a JSON Schema in `cli/kix-cli/schema/` in the Kix repository. The fields and their meaning are the same as before. Keys now come in the order the schema lists them instead of alphabetical order.

+++
kind = "fixed"
cli = ["kix rollback --output"]
+++
`kix status` adds `--force-conflicts` to its `Next:` line only when another field manager owns a field of a changed object that Kix does not also own. Before, it added the flag for any other manager, even one that shared all its fields with Kix and changed nothing, and the "changed since deploy" line named that manager too. The JSON output gives each entry of `foreign_owners` a new list, `unshared_paths`, with the fields Kix does not also own. `kix rollback --help` no longer lists `-o`, because rollback prints only text. `-o text` still works.

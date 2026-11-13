+++
kind = "error"
cli = ["KIX_OUTPUT"]
id = "K8738"
+++
Kix no longer reads the `KIX_OUTPUT` environment variable, and refuses to run while it is set. Before, it set the `-o` format for every command. Unset `KIX_OUTPUT`, and pass `-o json` or `-o yaml` to each command whose output a script reads.

+++
kind = "error"
cli = ["kix gc --hard", "kix gc --include-unstamped", "kix gc --include-unattributed", "kix gc --include-copies"]
id = "K9205"
+++
`kix gc --hard` is now `kix gc --full-scan`, and the three flags `--include-unstamped`, `--include-unattributed`, and `--include-copies` are now one flag that takes a list, such as `--include unstamped,copies`. Like the flags it replaces, `--include` needs `--full-scan`. The old flags fail with an error that names the new form.

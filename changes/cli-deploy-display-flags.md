+++
kind = "error"
cli = ["kix deploy --tui", "kix deploy --group-by-ns", "kix deploy --fold-height", "--log-format"]
id = "K5429"
+++
`kix deploy` picks how it shows progress with one flag. `--tui` is now `--log-format tui`, `--group-by-ns` is now `--group-by namespace` (the default is `package`), and `--fold-height N` is now the environment variable `KIX_TUI_HEIGHT=N`. As before, the `tui` view falls back to line output when stdout is not a terminal. The old flags fail with an error that names the new form.

+++
kind = "error"
id = "K3354"
+++
`kix rollback` now stops when it would remove an object that holds data and add another in its place, as `kix deploy` does. Before, it went ahead without a word. The message starts with `[K3354]` and lists each replacement. Move or back up the data, then run the rollback again with the new `--accept-migrations` flag. This applies to `kix rollback --operator` too.

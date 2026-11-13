+++
kind = "error"
cli = ["--save", "kix bundle", "kix snapshot save"]
id = "K2314"
+++
Every command that writes a file or a directory now names it with `--out`. `kix plan --save FILE` and `kix diff --save FILE` are now `--out FILE`, `kix bundle <cluster> FILE` is now `kix bundle <cluster> --out FILE` (the default is still `<cluster>.kixbundle`), and `kix snapshot save <cluster> DIR` is now `kix snapshot <cluster> --out DIR`. The old forms fail with an error that names the new one.

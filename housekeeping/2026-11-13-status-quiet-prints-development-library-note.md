# 2026-11-13 · `kix status` · `kix status -q` prints the development library note when run inside a project.

`kix status` reads only the cluster and needs no project. Run from the Kix repository, `kix status example -q` still prints "note: this project uses a development Kix library (kix.toml sets library = "self"), so Kix 0.10.0-rc.3 runs it without checking its version." on a run with no problems, where `-q` should print nothing. A script that treats any output from `-q` as a finding gets a false one.

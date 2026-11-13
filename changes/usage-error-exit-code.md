+++
kind = "silent"
cli = ["$?"]
+++
A command line that Kix cannot use now exits 1 instead of 2: an unknown command or flag, a missing argument, an invalid value, and a removed command or flag. `kix upgrade` now also exits 1 instead of 2 when a cluster does not build. Exit code 2 now always means that the command finished and found something to look at, such as changes from `kix plan` or `kix diff`. A script that read exit code 2 from `kix plan` or `kix diff` as "changes" can now trust it. A script that read 2 as "bad command line" or "the upgrade did not build" must check for 1.

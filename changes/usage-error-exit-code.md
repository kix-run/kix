+++
kind = "silent"
cli = ["$?"]
+++
A command line that Kix cannot use now exits 1 instead of 2: an unknown command or flag, a missing argument, an invalid value, and a removed command or flag. Exit code 2 now always means that the command finished and found something to look at, such as changes from `kix plan` or `kix diff`. The one exception is `kix upgrade`, which still exits 2 when a build fails. A script that read exit code 2 from `kix plan` or `kix diff` as "changes" can now trust it. A script that read 2 as "bad command line" must check for 1.

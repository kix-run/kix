# 2026-11-13 · `kix deploy` · A failed Job's line shows only the exit code, not the pod's last log line.

Seen on kind. The stackgres-database bootstrap Job failed with a wrong superuser password. The deploy printed "CrashLoopBackOff: pod …/bootstrap: terminated with Error (exit=2) after 3 restarts". The pod's log ended with "password authentication failed", which says what to fix. The user had to run `kubectl logs` to find it. Showing the last line or two of a failed Job pod's log would save that step.

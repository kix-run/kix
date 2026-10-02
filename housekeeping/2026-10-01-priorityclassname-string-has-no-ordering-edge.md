# 2026-10-01 · `kix/packages/{alertmanager,prometheus,prometheus-operator,victoria-metrics-operator}` · A `priorityClassName` string option gives the workload no dependency on its PriorityClass.

These four packages take `priorityClassName` as a string option, and
`partsOverlays` set it as a string too. A string gives the workload no
`kix.run/depends-on` entry for its class, so a deploy that adds both can
have pods refused at admission until the class exists. Rule 17 checks that
the class exists, not the order. The `priorityClass` dependency documented
in the `kix/packages/priority-class` header gives the ordering.

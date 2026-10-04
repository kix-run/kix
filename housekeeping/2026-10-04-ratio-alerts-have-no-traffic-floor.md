# coredns and harbor error-ratio alerts fire on one failure at low traffic

`CoreDNSErrorsHigh` (SERVFAIL over all responses above 3%) and harbor's core
5xx ratio alert (above 10%) divide by the request rate with no minimum. On a
quiet cluster one failed request in five minutes can push the ratio over
the threshold, and coredns's alert is `critical`.

Fix: add a floor, `and sum by (namespace, service) (rate(<requests>[5m])) > <n>`,
as HANDBOOK §9.4 "Writing alerts" describes. Part of step 3 of issue #192.

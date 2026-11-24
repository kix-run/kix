+++
kind = "changed"
+++
The Kix operator now groups repeated Kubernetes Events on the same Activation record (such as a cleanup failure on retry) into a single Event with a count, where previously each retry created a new Event. Each Event's `reportingInstance` field now holds the operator pod's name (previously the Activation's name).

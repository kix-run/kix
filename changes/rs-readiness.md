+++
kind = "fixed"
+++
A deploy now waits until the Kubernetes API lists the kind a new CRD defines before it applies the custom resources that use it. Before, Kix stopped waiting after five seconds and applied them anyway, so they could fail with "no matches for kind". An import of a kind the API does not list yet now waits for the API to list it. Before, Kix guessed the kind's resource name and scope, and could wait on the wrong path until the timeout.

+++
kind = "changed"
+++
When a deploy stalls or waits, its messages now name objects the same way the rest of Kix does. A step that is not a Kubernetes object appears in brackets, such as `⟦api-discovery⟧`. Kix also replaces control characters in object names with printable escapes.

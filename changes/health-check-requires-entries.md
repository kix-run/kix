+++
kind = "fixed"
+++
`kix.healthCheck` now skips a `requires` entry that is not a resource, as every other builder does. Before, such an entry stopped the build with an error that did not say where it came from.

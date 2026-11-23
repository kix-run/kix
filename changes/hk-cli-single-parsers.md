+++
kind = "fixed"
+++
`kix deploy` and `kix plan` now leave fields listed in `ownership.cede` (`kix.run/cede-fields`) with the controller that owns them when a conflict is inside a list item keyed by multiple fields, such as a Service port matched by `port` and `protocol`. Previously, they stopped with a field ownership conflict.

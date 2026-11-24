+++
kind = "fixed"
+++
`ownership.cede` (`kix.run/cede-fields`) now works on list items keyed by numbers or by multiple fields, such as a Service port matched by `[port=53,protocol="UDP"]`. Previously, `kix deploy` and `kix plan` stopped with a field ownership conflict on those paths instead of leaving the ceded fields with the controller.

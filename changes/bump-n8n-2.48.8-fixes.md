+++
kind = "fixed"
packages = ["experimental/n8n"]
+++
n8n 2.48.8 fixes four bugs. Users with a custom instance role can open the migration report, and n8n adds that permission to existing custom roles when it migrates the database. An expression that reaches the memory limit of the QuickJS engine fails with an error. A failed activation of an MCP workflow trigger is reported. The error output of a Code node keeps the plain input data.

# 2026-10-03 · `kix/lib/vocab` · The contract assertions name a fixed dependency in their message, whatever the consumer calls it.

`kix.contracts.postgresDatabase.assertions` always says `deps.database resolved to ...` and `kix.contracts.otlpEndpoint.assertions` always says `deps.otlp`. A consumer that takes the contract under another name (two databases, or an `otlpTraces` dependency beside a metrics one) gets an error that points the user at a dependency the package does not have.

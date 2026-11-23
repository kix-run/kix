+++
kind = "security"
+++
Kix updates its `url` Rust dependency from 2.5.8 to 2.5.9. Version 2.5.9
fixes a stack overflow in `Url::origin()` on nested `blob:` URLs
(RUSTSEC-2026-0592). Kix does not call `Url::origin()` directly.

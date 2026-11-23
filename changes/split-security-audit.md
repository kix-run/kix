+++
kind = "security"
+++
Kix now builds with `url` 2.5.9, which fixes a stack overflow in
`Url::origin()` on nested `blob:` URLs (RUSTSEC-2026-0592). Kix does not
call that function itself.

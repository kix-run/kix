# 2026-11-24 · `cli/kix/src/release/download.rs` · The release downloader fetches its text files without compression.

`Fetcher` builds one reqwest client with `no_gzip()`, because a server that labels a `.tar.gz` with `Content-Encoding: gzip` would make a decoding client hash the unpacked tar and fail the SHA-256 check. That client also fetches the release index, `SHA256SUMS`, signatures, and `kix-<version>-changes.json` (`cli/kix/src/release/mod.rs` near line 435), which `kix upgrade` reads. The change records file was about 129,000 characters for 0.10.0-rc.6 and grows each release.

Options:
- Keep one raw client. Cost: the change records file downloads uncompressed on each `kix upgrade`.
- Use a decoding client for text and a raw client for the archive. Cost: a second connection and TLS handshake to the same host, which `cli/README.md` records Kix avoided for the API server probe.
- Publish the change records file already compressed, as the archive is. Cost: a change to the release layout that older versions of Kix must still read.

Decision required from Adam: which of the three the release downloader should use.

# 2026-11-24 · `cli/kix` reqwest clients · A new reqwest client decodes gzip unless its author knows to call `no_gzip()`.

The workspace turns on reqwest's `gzip` feature (`cli/Cargo.toml`), which makes decoding the default for every client. Each client is built on its own, with its own user agent and timeouts: `cli/kix/src/registry/client.rs` (`RegistryClient::new`) and `cli/kix/src/release/download.rs` (`Fetcher::client`, which opts out). A future client that hashes or counts what it downloads would see decoded bytes, and only the comment in `cli/Cargo.toml` warns its author.

Options:
- Leave it. There are two clients, and a test pins each one's behaviour.
- Add one function that builds every reqwest client and makes the caller choose decoded content or raw bytes. Cost: a small new module. Gain: each caller must make the choice, and the user agent is set once.

Decision required from Adam: whether Kix should have one constructor for its reqwest clients.

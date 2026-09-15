# Contributing

Short guide; the details for working on the code are in [`CLAUDE.md`](CLAUDE.md) (it works the same for people and for AI agents). Be decent to each other: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

1. `swift build && swift test` before proposing changes; `scripts/lint.sh --fix` for formatting.
2. UI text in English with `Text("…")`/`String(localized:)`; then `scripts/sync_strings.sh` and the Spanish in `Resources/Localizable.xcstrings`.
3. New tests with Swift Testing. The protocol is tested against `FakeCamera`/`FakeHTTPServer`, without hardware.
4. Small commits, in English, in the imperative ("Fix …", "Add …"). Note user-visible changes in `CHANGELOG.md`.
5. Code adapted from other projects: respect its license and keep the credit (see `LICENSE`, `README.md`).

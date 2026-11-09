# Toolchain smoke test

`Containerfile` is the image behind `make hello`: Debian trixie with the Qt 6
development packages and rustup. `make hello` builds `ui/hello/` (the cxx-qt
"hello" app) in it, with the Rust toolchain pinned by `rust-toolchain.toml`.
Build output goes to `out/hello-target/` so the checkout stays clean.

The `hello` job in `.github/workflows/ci.yml` installs the same packages in a
`debian:trixie` container; keep the two package lists in sync.

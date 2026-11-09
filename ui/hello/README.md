# lugh-hello

Phase 0 toolchain smoke app: one QML window backed by one Rust QObject, built
with [cxx-qt](https://github.com/KDAB/cxx-qt) 0.10 on Qt 6. It proves that Qt 6
and cxx-qt build on Debian trixie and in CI. **It is not shipped in the ISO.**

- `src/greeter.rs`: the `Greeter` QObject (`greeting: QString` and `count: int`
  properties, plus a `greet()` invokable), registered as a QML element in the
  module `os.lugh.hello`.
- `qml/main.qml`: the window, using the light Lugh tokens from
  [DESIGN-SYSTEM](../../docs/DESIGN-SYSTEM.md): `bg` `#F7F6F3`, `text` `#1C1B19`,
  an Amber `#E8962E` button with `#1C1B19` text, Inter, and a 2 px focus ring
  with a 2 px offset that shows for keyboard users.
- `build.rs`: `cxx-qt-build` generates the C++ glue, runs `qmlcachegen` on the
  QML and bundles it into the binary as `qrc:/qt/qml/os/lugh/hello/qml/main.qml`.
  You only need cargo; there is no CMake project.

This is a standalone cargo project with its own `[workspace]` table and its own
`Cargo.lock`. The root workspace excludes it, so `cargo build` at the repo root
does not need Qt. The toolchain comes from the root `rust-toolchain.toml`.

## Dependencies (Debian trixie)

```sh
sudo apt install build-essential pkg-config cmake \
  qt6-base-dev qt6-declarative-dev qt6-declarative-dev-tools \
  qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-window \
  qml6-module-qtqml-workerscript qml6-module-qtquick-templates
# optional, for running it on a desktop:
sudo apt install qt6-qpa-plugins qt6-wayland fonts-inter
```

`cmake` is not needed by this crate's build. It stays in the list because the
phase plan and CI install it. Without Inter installed, Qt falls back to the
system sans-serif font.

## Build, lint, run

From the repo root:

```sh
QMAKE=/usr/lib/qt6/bin/qmake cargo build --manifest-path ui/hello/Cargo.toml
/usr/lib/qt6/bin/qmllint ui/hello/qml/*.qml
./ui/hello/target/debug/lugh-hello
```

Run `cargo build` **before** `qmllint`. The build writes the `os.lugh.hello`
type info to `ui/hello/target/cxxqt/qml_modules/`, and `qml/.qmllint.ini`
points qmllint there. If you lint before building, qmllint warns that it cannot
find `Greeter`. If you set `CARGO_TARGET_DIR`, pass the import path yourself:
`qmllint -I "$CARGO_TARGET_DIR/cxxqt/qml_modules" ui/hello/qml/*.qml`.

Headless smoke run (the app should keep running with no QML errors on stderr):

```sh
QT_QPA_PLATFORM=offscreen timeout 4 ./ui/hello/target/debug/lugh-hello; test $? -eq 124
```

### Without Qt on the host (Docker)

```sh
docker run --rm -v "$PWD":/src -w /src debian:trixie bash -c '
  apt-get update && apt-get install -y build-essential pkg-config cmake \
    qt6-base-dev qt6-declarative-dev qt6-declarative-dev-tools \
    qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-window \
    qml6-module-qtqml-workerscript qml6-module-qtquick-templates curl ca-certificates &&
  curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none --profile minimal &&
  . "$HOME/.cargo/env" &&
  QMAKE=/usr/lib/qt6/bin/qmake cargo build --manifest-path ui/hello/Cargo.toml &&
  /usr/lib/qt6/bin/qmllint ui/hello/qml/*.qml &&
  chown -R '"$(id -u):$(id -g)"' ui/hello/target'
```

## Notes

- The build prints `Neither mold, lld, nor gold linkers were found. Linking with
  GNU ld.bfd will likely fail.` This warning comes from cxx-qt-build and is
  harmless here: the binary links with GNU ld on trixie.

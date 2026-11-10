use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    // `qml/backend/GreetdBackend.qml` (the adapter that presents the
    // `greetdBackend` contract) is compiled into the binary as the QML module
    // `os.lugh.greeter`, next to the Rust QObject of `src/bridge.rs`. The UI
    // itself (`qml/main.qml`, `Greeter.qml`, ...) is loaded from disk.
    let builder = CxxQtBuilder::new_qml_module(
        QmlModule::new("os.lugh.greeter").qml_file("qml/backend/GreetdBackend.qml"),
    )
    .files(["src/bridge.rs"]);
    // SAFETY: only adds our own shim source and its include directory.
    let builder = unsafe {
        builder.cc_builder(|cc| {
            cc.include("cpp");
            cc.file("cpp/shim.cpp");
        })
    };
    println!("cargo::rerun-if-changed=cpp/shim.cpp");
    println!("cargo::rerun-if-changed=cpp/shim.h");
    builder.build();
}

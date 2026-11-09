use cxx_qt_build::{CxxQtBuilder, QmlModule};

fn main() {
    // Registers `qml/main.qml` under the QML module `os.lugh.hello` (compiled ahead
    // of time with qmlcachegen) and generates the C++ side of `src/greeter.rs`.
    CxxQtBuilder::new_qml_module(QmlModule::new("os.lugh.hello").qml_file("qml/main.qml"))
        .files(["src/greeter.rs"])
        .build();
}

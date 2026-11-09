//! `lugh-hello`: proves that Qt 6 + cxx-qt build and run on Debian trixie.
//! Not shipped in the ISO.

mod greeter;

use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QString, QUrl};

/// Where cxx-qt-build places `qml/main.qml` inside the `os.lugh.hello` module.
const MAIN_QML: &str = "qrc:/qt/qml/os/lugh/hello/qml/main.qml";

fn main() {
    let mut app = QGuiApplication::new();
    let mut engine = QQmlApplicationEngine::new();

    if let Some(mut app) = app.as_mut() {
        app.as_mut()
            .set_application_name(&QString::from("lugh-hello"));
        app.as_mut().set_organization_name(&QString::from("Lugh"));
    }

    if let Some(engine) = engine.as_mut() {
        engine.load(&QUrl::from(MAIN_QML));
    }

    let code = app.as_mut().map_or(1, |app| app.exec());
    std::process::exit(code);
}

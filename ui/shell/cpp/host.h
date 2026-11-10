// The Qt side of lugh-shell: application, QML engine, context objects.
// Called from Rust (src/bridge.rs); see host.cpp.
#pragma once

#include <QtCore/QString>

// Runs the application and returns the process exit code. `args` (argv for Qt)
// and `importPaths` are newline-separated; `mainQml` is a file path or a
// `qrc:` URL. `mock`: no backend is attached. `check`: load on the offscreen
// platform, print one result line, return 0 (ok) or 1.
int lugh_host_run(const QString &args, const QString &mainQml, const QString &importPaths,
                  const QString &iconTheme, bool mock, bool check);

// QCoreApplication::exit(code). Qt thread only.
void lugh_host_quit(int code);

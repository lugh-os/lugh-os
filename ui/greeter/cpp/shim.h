// C++ side of lugh-greeter that cxx-qt-lib has no binding for: the
// application object, the QML engine, the `greetdBackend` context property,
// the icon theme and the Caps Lock watcher.
#pragma once

#include <cstdint>

#include "rust/cxx.h"

namespace lugh {

// Runs the greeter until it quits and returns the exit code.
//   qml_dir      directory holding main.qml
//   import_path  QML import path of Lugh.UI
//   offscreen    force the offscreen platform (no display needed)
//   check        load, report QML warnings, then exit: 0 clean, 1 otherwise
std::int32_t greeter_run(rust::Str qml_dir, rust::Str import_path, bool offscreen, bool check);

// Ends the event loop with `code`. Call on the Qt thread.
void greeter_quit(std::int32_t code);

} // namespace lugh

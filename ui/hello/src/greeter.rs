//! The one Rust-backed QObject of the hello app.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "RustQt" {
        /// Exposed to QML as `Greeter` in `import os.lugh.hello`.
        #[qobject]
        #[qml_element]
        #[qproperty(QString, greeting)]
        #[qproperty(i32, count)]
        type Greeter = super::GreeterRust;

        /// Advances the greeting; called from the button in `main.qml`.
        #[qinvokable]
        fn greet(self: Pin<&mut Greeter>);
    }
}

use core::pin::Pin;
use cxx_qt_lib::QString;

const GREETINGS: [&str; 4] = [
    "Hello from Rust.",
    "Qt 6 and cxx-qt are talking.",
    "The toolchain works.",
    "Dia duit — hello again.",
];

/// Rust-side state behind `Greeter`.
#[derive(Debug)]
pub struct GreeterRust {
    greeting: QString,
    count: i32,
}

impl Default for GreeterRust {
    fn default() -> Self {
        Self {
            greeting: QString::from("Press the button to say hello."),
            count: 0,
        }
    }
}

impl qobject::Greeter {
    /// Bumps the counter and picks the next greeting.
    pub fn greet(mut self: Pin<&mut Self>) {
        let count = self.count().saturating_add(1);
        let index = usize::try_from(count - 1).unwrap_or(0) % GREETINGS.len();
        self.as_mut().set_count(count);
        self.as_mut().set_greeting(QString::from(GREETINGS[index]));
    }
}

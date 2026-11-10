//! `lugh-greeter`: the Lugh sign-in screen, run by greetd inside cage.
//!
//! ```text
//! lugh-greeter [--demo] [--check] [--qml-dir DIR] [--import-path DIR]
//! ```
//!
//! See `ui/greeter/README.md` for the QML contract and the greetd wiring.

mod bridge;

use std::path::PathBuf;
use std::process::ExitCode;

use lugh_greetd::backend::Options;

const DEFAULT_QML_DIR: &str = "/usr/share/lugh/greeter/qml";
const DEFAULT_IMPORT_PATH: &str = "/usr/share/lugh/qml";

const USAGE: &str = "\
Usage: lugh-greeter [OPTIONS]

The Lugh sign-in screen. greetd starts it (inside cage) with $GREETD_SOCK set.

Options:
  --demo              run without greetd: fake users, password \"lugh\"
  --check             load the QML offscreen and exit (0 = clean, 1 = problems)
  --qml-dir DIR       directory with main.qml
                      [$LUGH_GREETER_QML_DIR, /usr/share/lugh/greeter/qml]
  --import-path DIR   QML import path of Lugh.UI
                      [$LUGH_QML_IMPORT_PATH, /usr/share/lugh/qml]
  -h, --help          show this help
  -V, --version       show the version
";

#[derive(Debug, Default)]
struct Args {
    demo: bool,
    check: bool,
    qml_dir: Option<String>,
    import_path: Option<String>,
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Result<Option<Args>, String> {
    let mut parsed = Args::default();
    while let Some(arg) = args.next() {
        let mut value = |name: &str| {
            args.next()
                .ok_or_else(|| format!("{name} needs a directory"))
        };
        match arg.as_str() {
            "--demo" => parsed.demo = true,
            "--check" => parsed.check = true,
            "--qml-dir" => parsed.qml_dir = Some(value("--qml-dir")?),
            "--import-path" => parsed.import_path = Some(value("--import-path")?),
            "-h" | "--help" => {
                print!("{USAGE}");
                return Ok(None);
            }
            "-V" | "--version" => {
                println!("lugh-greeter {}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            other => return Err(format!("unknown option {other}")),
        }
    }
    Ok(Some(parsed))
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

fn main() -> ExitCode {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(Some(args)) => args,
        Ok(None) => return ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("lugh-greeter: {message}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };

    // Logs go to stderr, which greetd sends to the journal. LUGH_LOG=debug for more.
    let filter = tracing_subscriber::EnvFilter::try_from_env("LUGH_LOG")
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();

    let socket = env("GREETD_SOCK").map(PathBuf::from);
    // `--check` only loads the UI: it never needs greetd.
    let demo = args.demo || args.check;
    if !demo && socket.is_none() {
        eprintln!(
            "lugh-greeter: $GREETD_SOCK is not set, so there is no greetd to sign in through.\n\
             This program is started by greetd (see /etc/greetd/config.toml).\n\
             To try it without greetd, run: lugh-greeter --demo   (password \"lugh\")"
        );
        return ExitCode::from(2);
    }

    let qml_dir = args
        .qml_dir
        .or_else(|| env("LUGH_GREETER_QML_DIR"))
        .unwrap_or_else(|| DEFAULT_QML_DIR.to_owned());
    let import_path = args
        .import_path
        .or_else(|| env("LUGH_QML_IMPORT_PATH"))
        .unwrap_or_else(|| DEFAULT_IMPORT_PATH.to_owned());
    if !PathBuf::from(&qml_dir).join("main.qml").is_file() {
        eprintln!(
            "lugh-greeter: no main.qml in {qml_dir} (use --qml-dir or $LUGH_GREETER_QML_DIR)"
        );
        return ExitCode::FAILURE;
    }

    let options = Options {
        socket,
        demo,
        xkb_layout: env("XKB_DEFAULT_LAYOUT"),
        ..Options::default()
    };
    if bridge::OPTIONS.set(options).is_err() {
        return ExitCode::FAILURE;
    }

    let code = bridge::qobject::greeter_run(&qml_dir, &import_path, args.check, args.check);
    // Skip destructors of statics: after a login greetd is waiting for us.
    std::process::exit(code);
}

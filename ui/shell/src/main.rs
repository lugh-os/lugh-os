//! `lugh-shell`: the Lugh desktop shell. A Qt 6 / QML host (cxx-qt) around the
//! Qt-free `lugh-shell-core`.
//!
//! ```text
//! lugh-shell [--qml-dir <dir>]… [--import-path <dir>]… [--mock] [--check]
//!            [--version] [--help] [-- <args for main.qml>]
//! ```
//!
//! QML is loaded from disk: the first `--qml-dir` (or `$LUGH_QML_DIR`, else
//! `/usr/share/lugh/qml`) holding `main.qml`; every `--qml-dir` and
//! `--import-path` is a QML import path (`<dir>/Lugh/UI`, `<dir>/Lugh/Shell`).
//! Qt's QML disk cache (`~/.cache/lugh-shell/qmlcache`) keeps the compiled
//! units, so only the first start after an upgrade compiles. With the
//! `embed-qml` cargo feature the same tree is compiled into the binary
//! (`qrc:/lugh/qml`) and used when no directory is given.
//!
//! Everything Qt lives in `cpp/host.cpp` (application, engine, `LughNative`);
//! `backend.rs` is the bridge object `LughBackend`; `bridge.rs` holds the
//! cxx-qt declarations.

mod backend;
mod bridge;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use cxx_qt_lib::QString;

const DEFAULT_QML_DIR: &str = "/usr/share/lugh/qml";
const EMBEDDED_QML_ROOT: &str = "qrc:/lugh/qml";
const DEFAULT_ICON_THEME: &str = "Papirus";

const HELP: &str = "\
lugh-shell — the Lugh desktop shell

Usage: lugh-shell [options] [-- <args for main.qml>]

  --qml-dir <dir>      QML root (main.qml, Lugh/UI, Lugh/Shell). Repeatable:
                       each is an import path, the first with main.qml is run.
                       Default: $LUGH_QML_DIR, else /usr/share/lugh/qml
  --import-path <dir>  Extra QML import path. Repeatable.
  --mock               Do not attach the system backend (QML mock data)
  --check              Load everything on the offscreen platform, print a
                       one-line result, exit 0 (ok) or 1 (failed)
  --version            Print the version
  --help               This text

Environment: LUGH_LOG (log filter, e.g. debug), LUGH_QML_DIR";

#[derive(Debug, Default, PartialEq, Eq)]
struct Cli {
    qml_dirs: Vec<PathBuf>,
    import_paths: Vec<PathBuf>,
    mock: bool,
    check: bool,
    /// Passed through to Qt / main.qml untouched.
    rest: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
enum Parsed {
    Run(Cli),
    Version,
    Help,
    Error(String),
}

fn parse(args: impl IntoIterator<Item = String>) -> Parsed {
    let mut cli = Cli::default();
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--version" | "-V" => return Parsed::Version,
            "--help" | "-h" => return Parsed::Help,
            "--mock" => cli.mock = true,
            "--check" => cli.check = true,
            "--qml-dir" | "--import-path" => {
                let Some(value) = args.next() else {
                    return Parsed::Error(format!("{arg} needs a directory"));
                };
                if arg == "--qml-dir" {
                    cli.qml_dirs.push(value.into());
                } else {
                    cli.import_paths.push(value.into());
                }
            }
            "--" => {
                cli.rest.extend(args);
                break;
            }
            // Unknown flags belong to Qt (-platform …) or main.qml (--dark …).
            _ => cli.rest.push(arg),
        }
    }
    Parsed::Run(cli)
}

/// Where main.qml comes from and which import paths go with it.
#[derive(Debug, PartialEq, Eq)]
struct QmlSource {
    main: String,
    import_paths: Vec<String>,
}

fn absolute(path: &Path) -> String {
    std::path::absolute(path)
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

fn resolve_qml(cli: &Cli, env_dir: Option<PathBuf>, embedded: bool) -> Result<QmlSource, String> {
    let explicit = !cli.qml_dirs.is_empty() || env_dir.is_some();
    let mut dirs: Vec<PathBuf> = cli.qml_dirs.clone();
    if dirs.is_empty() {
        dirs.extend(env_dir);
    }
    let mut import_paths: Vec<String> = Vec::new();
    let main = if embedded && !explicit {
        import_paths.push(EMBEDDED_QML_ROOT.to_owned());
        format!("{EMBEDDED_QML_ROOT}/main.qml")
    } else {
        if dirs.is_empty() {
            dirs.push(DEFAULT_QML_DIR.into());
        }
        let Some(root) = dirs.iter().find(|d| d.join("main.qml").is_file()) else {
            let tried: Vec<_> = dirs.iter().map(|d| d.display().to_string()).collect();
            return Err(format!("no main.qml in {}", tried.join(", ")));
        };
        absolute(&root.join("main.qml"))
    };
    import_paths.extend(dirs.iter().chain(&cli.import_paths).map(|d| absolute(d)));
    Ok(QmlSource { main, import_paths })
}

/// `appearance.icon_theme` from desktop.toml (not part of the typed schema
/// yet), else Papirus. The host falls back further when it is not installed.
fn icon_theme() -> String {
    lugh_shell_core::config::DesktopConfig::default_path()
        .ok()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| icon_theme_from(&text))
        .unwrap_or_else(|| DEFAULT_ICON_THEME.to_owned())
}

fn icon_theme_from(toml_text: &str) -> Option<String> {
    let doc: toml::Table = toml_text.parse().ok()?;
    let name = doc.get("appearance")?.get("icon_theme")?.as_str()?.trim();
    // A theme name is a directory name: nothing else is accepted.
    (!name.is_empty() && !name.contains(['/', '\n'])).then(|| name.to_owned())
}

fn main() -> ExitCode {
    backend::mark_start();
    let mut argv = std::env::args();
    let program = argv.next().unwrap_or_else(|| "lugh-shell".into());
    let cli = match parse(argv) {
        Parsed::Run(cli) => cli,
        Parsed::Version => {
            println!("lugh-shell {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Parsed::Help => {
            println!("{HELP}");
            return ExitCode::SUCCESS;
        }
        Parsed::Error(message) => {
            eprintln!("lugh-shell: {message}\n\n{HELP}");
            return ExitCode::from(2);
        }
    };

    if let Err(e) = lugh_common::logging::init_logging() {
        eprintln!("lugh-shell: logging unavailable: {e}");
    }

    let env_dir = std::env::var_os("LUGH_QML_DIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    let qml = match resolve_qml(&cli, env_dir, cfg!(feature = "embed-qml")) {
        Ok(qml) => qml,
        Err(message) => {
            tracing::error!("{message}");
            if cli.check {
                println!("lugh-shell check: FAILED ({message})");
            }
            return ExitCode::FAILURE;
        }
    };
    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        main = %qml.main,
        mock = cli.mock,
        "starting"
    );

    let mut qt_args = vec![program];
    qt_args.extend(cli.rest);
    let code = bridge::ffi::host_run(
        &QString::from(&qt_args.join("\n")),
        &QString::from(&qml.main),
        &QString::from(&qml.import_paths.join("\n")),
        &QString::from(&icon_theme()),
        cli.mock,
        cli.check,
    );
    tracing::info!(code, "exit");
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn parses_flags_and_passes_the_rest_on() {
        let parsed = parse(args(&[
            "--qml-dir", "a", "--import-path", "b", "--qml-dir", "c", "--check", "--dark", "--",
            "--mock",
        ]));
        let Parsed::Run(cli) = parsed else {
            unreachable!("expected a run")
        };
        assert_eq!(cli.qml_dirs, [PathBuf::from("a"), PathBuf::from("c")]);
        assert_eq!(cli.import_paths, [PathBuf::from("b")]);
        assert!(cli.check && !cli.mock);
        assert_eq!(cli.rest, ["--dark", "--mock"]);
        assert_eq!(parse(args(&["--version"])), Parsed::Version);
        assert!(matches!(parse(args(&["--qml-dir"])), Parsed::Error(_)));
    }

    #[test]
    fn embedded_qml_is_used_only_without_a_directory() {
        let cli = Cli::default();
        let qml = resolve_qml(&cli, None, true).unwrap_or_else(|e| unreachable!("{e}"));
        assert_eq!(qml.main, "qrc:/lugh/qml/main.qml");
        assert_eq!(qml.import_paths, ["qrc:/lugh/qml"]);
        let missing = resolve_qml(&cli, Some("/nonexistent/lugh".into()), true);
        assert!(missing.is_err());
    }

    #[test]
    fn icon_theme_is_read_leniently() {
        assert_eq!(
            icon_theme_from("[appearance]\nicon_theme = \"breeze\"\n").as_deref(),
            Some("breeze")
        );
        assert_eq!(icon_theme_from("[appearance]\ntheme = \"dark\"\n"), None);
        assert_eq!(icon_theme_from("[appearance]\nicon_theme = \"../x\"\n"), None);
        assert_eq!(icon_theme_from("not toml ["), None);
    }
}

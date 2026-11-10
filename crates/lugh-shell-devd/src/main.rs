//! `lugh-shell-devd [--listen 127.0.0.1:7777] [--print] [--i-know]`
//!
//! Serves this machine's shell services to the QML preview over a WebSocket.
//! See the library docs for the protocol.

use std::process::ExitCode;
use std::sync::Arc;

use lugh_shell_core::services::ShellCore;
use lugh_shell_devd::{DEFAULT_QUEUE, Hub, resolve_listen, serve};
use tokio::signal::unix::{SignalKind, signal};

const USAGE: &str = "\
Usage: lugh-shell-devd [--listen ADDR:PORT] [--print] [--i-know]

Runs the Lugh shell services of this machine behind a WebSocket, for the QML
preview (make preview ARGS=\"--backend ws://127.0.0.1:7777\").

  --listen ADDR:PORT  where to listen (default 127.0.0.1:7777; loopback only)
  --print             log every event sent to clients
  --i-know            allow a non-loopback --listen address (anyone who can
                      reach it controls this desktop)
  -h, --help          this text
";

#[derive(Debug)]
struct Options {
    listen: String,
    print: bool,
    allow_any: bool,
}

/// `Ok(None)` means `--help`.
fn parse(mut args: impl Iterator<Item = String>) -> Result<Option<Options>, String> {
    let mut o = Options {
        listen: "127.0.0.1:7777".to_owned(),
        print: false,
        allow_any: false,
    };
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--listen" => o.listen = args.next().ok_or("--listen needs an address")?,
            "--print" => o.print = true,
            "--i-know" => o.allow_any = true,
            "-h" | "--help" => return Ok(None),
            other => match other.strip_prefix("--listen=") {
                Some(addr) => addr.clone_into(&mut o.listen),
                None => return Err(format!("unknown argument `{other}`")),
            },
        }
    }
    Ok(Some(o))
}

async fn shutdown_signal() {
    let (Ok(mut int), Ok(mut term)) = (
        signal(SignalKind::interrupt()),
        signal(SignalKind::terminate()),
    ) else {
        tracing::warn!("cannot watch signals; stop the server with SIGKILL");
        return std::future::pending().await;
    };
    tokio::select! {
        _ = int.recv() => tracing::info!("SIGINT: shutting down"),
        _ = term.recv() => tracing::info!("SIGTERM: shutting down"),
    }
}

#[allow(clippy::print_stdout, clippy::print_stderr)] // usage text of a CLI
fn main() -> ExitCode {
    let options = match parse(std::env::args().skip(1)) {
        Ok(Some(o)) => o,
        Ok(None) => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprint!("lugh-shell-devd: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    if let Err(e) = lugh_common::logging::init_logging() {
        eprintln!("lugh-shell-devd: {e}");
    }
    let addr = match resolve_listen(&options.listen, options.allow_any) {
        Ok(a) => a,
        Err(e) => {
            tracing::error!("{e}");
            return ExitCode::from(2);
        }
    };

    let hub = Arc::new(Hub::new(DEFAULT_QUEUE));
    // The core owns a runtime of its own: it is created and dropped here,
    // outside the server's runtime.
    let core = match ShellCore::start(hub.sink(options.print)) {
        Ok(c) => Arc::new(c),
        Err(e) => {
            tracing::error!(%e, "cannot start the shell core");
            return ExitCode::FAILURE;
        }
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            tracing::error!(%e, "cannot start the server runtime");
            return ExitCode::FAILURE;
        }
    };
    let code = runtime.block_on(async {
        let listener = match tokio::net::TcpListener::bind(addr).await {
            Ok(l) => l,
            Err(e) => {
                tracing::error!(%addr, %e, "cannot listen");
                return ExitCode::FAILURE;
            }
        };
        tracing::info!("serving the shell core on ws://{addr}");
        serve(listener, Arc::clone(&core), hub, shutdown_signal()).await;
        ExitCode::SUCCESS
    });
    drop(runtime);
    drop(core);
    code
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> impl Iterator<Item = String> {
        list.iter()
            .map(|s| (*s).to_owned())
            .collect::<Vec<_>>()
            .into_iter()
    }

    #[test]
    fn parses_arguments() {
        let o = parse(args(&[])).ok().flatten();
        assert!(o.is_some_and(|o| o.listen == "127.0.0.1:7777" && !o.print && !o.allow_any));
        let o = parse(args(&["--listen", "[::1]:9", "--print", "--i-know"]))
            .ok()
            .flatten();
        assert!(o.is_some_and(|o| o.listen == "[::1]:9" && o.print && o.allow_any));
        let o = parse(args(&["--listen=127.0.0.1:1"])).ok().flatten();
        assert!(o.is_some_and(|o| o.listen == "127.0.0.1:1"));
        assert!(matches!(parse(args(&["--help"])), Ok(None)));
        assert!(parse(args(&["--listen"])).is_err());
        assert!(parse(args(&["--nope"])).is_err());
    }
}

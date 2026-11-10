//! A fake greetd for the greeter's end-to-end check.
//!
//! ```sh
//! fake_greetd <socket> <user> <password> [timeout-seconds]
//! ```
//!
//! Listens on `<socket>`, prints every request it gets (typed answers are
//! redacted) and exits 0 once a `start_session` was accepted and the client
//! went away, 1 on timeout.
#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::path::Path;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use lugh_greetd::fake::{FakeConfig, FakeGreetd, Seen};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [socket, user, password, rest @ ..] = args.as_slice() else {
        eprintln!("usage: fake_greetd <socket> <user> <password> [timeout-seconds]");
        return ExitCode::from(2);
    };
    let timeout = rest.first().and_then(|s| s.parse().ok()).unwrap_or(30);
    let greetd = match FakeGreetd::spawn(Path::new(socket), FakeConfig::with_user(user, password)) {
        Ok(greetd) => greetd,
        Err(err) => {
            eprintln!("fake_greetd: cannot listen on {socket}: {err}");
            return ExitCode::from(2);
        }
    };
    println!("fake_greetd: listening on {socket}");
    let deadline = Instant::now() + Duration::from_secs(timeout);
    let mut started = false;
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        match greetd.next(left) {
            Some(Seen::Request(request)) => println!("fake_greetd: request {request:?}"),
            Some(Seen::Started { user, cmd, env }) => {
                println!("fake_greetd: start_session accepted for {user}: cmd={cmd:?} env={env:?}");
                started = true;
            }
            Some(Seen::Disconnected) => {
                println!("fake_greetd: client disconnected");
                if started {
                    return ExitCode::SUCCESS;
                }
            }
            None => break,
        }
    }
    eprintln!("fake_greetd: timed out (start_session accepted: {started})");
    ExitCode::FAILURE
}

//! Runs the real services on this machine and prints what the UI would get.
//!
//!   cargo run -p lugh-shell-core --example svc_dump -- [service …] [--secs N]
//!
//! Prints the snapshot (all services, or only the named ones), then every
//! event as one JSON line, for N seconds (default 5; 0 = until stdin closes).
//! Lines typed on stdin are calls: `network.rescan` or
//! `audio.setVolume [0.4]` (method, then a JSON array of arguments).
//! Read-only by default: it only changes the system when you type a call.
#![allow(clippy::print_stdout, clippy::print_stderr)]

use std::io::BufRead;
use std::time::Duration;

use lugh_shell_core::services::{ShellCore, Sink};
use serde_json::Value;

fn main() -> std::io::Result<()> {
    let mut only: Vec<String> = Vec::new();
    let mut secs = 5u64;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        if a == "--secs" {
            secs = it.next().and_then(|s| s.parse().ok()).unwrap_or(5);
        } else {
            only.push(a);
        }
    }
    let filter = only.clone();
    let sink = Sink::new(move |e| {
        let json = e.to_json();
        let svc = json["s"].as_str().unwrap_or_default();
        if filter.is_empty() || filter.iter().any(|f| f == svc) {
            println!("{json}");
        }
    });
    let core = ShellCore::start(sink)?;
    std::thread::sleep(Duration::from_millis(1200)); // let services fetch their first state
    let snap = core.snapshot();
    if let Value::Object(map) = &snap {
        for (name, state) in map {
            if only.is_empty() || only.iter().any(|f| f == name) {
                println!(
                    "{}",
                    serde_json::json!({ "t": "snapshot", "s": name, "d": state })
                );
            }
        }
    }
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let deadline = (secs > 0).then(|| std::time::Instant::now() + Duration::from_secs(secs));
    loop {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(line) => {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let (method, args) = line.split_once(' ').unwrap_or((line, "[]"));
                let args: Vec<Value> = serde_json::from_str(args).unwrap_or_default();
                eprintln!("-> {method}: {:?}", core.call(method, &args));
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) if secs == 0 => break,
            Err(_) => {}
        }
        if deadline.is_some_and(|d| std::time::Instant::now() >= d) {
            break;
        }
    }
    Ok(())
}

//! The sound server behind a trait, and its `pactl` implementation
//! (PipeWire's PulseAudio layer). A native WirePlumber client can replace
//! [`Pactl`] without touching the service.

use std::fmt;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;

use super::model::{self, Class, ClassData, Dirty, Write};

pub(crate) type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// A sound server.
pub(crate) trait Audio: Send + Sync + fmt::Debug + 'static {
    /// Reads one class of objects.
    fn read(&self, class: Class) -> BoxFuture<'_, io::Result<ClassData>>;
    /// Applies one change.
    fn write(&self, write: Write) -> BoxFuture<'_, io::Result<()>>;
    /// Starts listening for changes (on the current tokio runtime). The
    /// receiver yields what each change invalidates and closes when the
    /// connection to the server ends; dropping it stops the listener.
    fn subscribe(&self) -> io::Result<mpsc::Receiver<Dirty>>;
}

/// No answer from `pactl` within this means the server hangs.
const TIMEOUT: Duration = Duration::from_secs(5);

/// PipeWire (or PulseAudio) through the `pactl` CLI.
#[derive(Debug, Clone)]
pub(crate) struct Pactl {
    program: String,
}

impl Default for Pactl {
    fn default() -> Self {
        Self {
            program: "pactl".to_owned(),
        }
    }
}

impl Pactl {
    fn command(&self) -> Command {
        let mut cmd = Command::new(&self.program);
        // pactl's JSON prints numbers with the locale's decimal comma.
        cmd.env("LC_ALL", "C")
            .stdin(Stdio::null())
            .kill_on_drop(true);
        cmd
    }

    async fn run(&self, args: &[&str]) -> io::Result<String> {
        let mut cmd = self.command();
        cmd.args(args).stdout(Stdio::piped()).stderr(Stdio::piped());
        // On timeout the future is dropped, which kills and reaps the child.
        let out = tokio::time::timeout(TIMEOUT, cmd.output())
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "pactl timed out"))??;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(io::Error::other(
                String::from_utf8_lossy(&out.stderr).trim().to_owned(),
            ))
        }
    }
}

fn bad_json(e: serde_json::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, e)
}

impl Audio for Pactl {
    fn read(&self, class: Class) -> BoxFuture<'_, io::Result<ClassData>> {
        Box::pin(async move {
            let list = |what: &'static str| async move {
                self.run(&["--format=json", "list", what]).await
            };
            match class {
                Class::Sinks => model::parse_sinks(&list("sinks").await?).map(ClassData::Sinks),
                Class::Sources => {
                    model::parse_sources(&list("sources").await?).map(ClassData::Sources)
                }
                Class::Streams => {
                    model::parse_streams(&list("sink-inputs").await?).map(ClassData::Streams)
                }
                Class::Server => model::parse_info(&self.run(&["--format=json", "info"]).await?)
                    .map(ClassData::Server),
            }
            .map_err(bad_json)
        })
    }

    fn write(&self, write: Write) -> BoxFuture<'_, io::Result<()>> {
        Box::pin(async move {
            let args = write.pactl_args();
            let args: Vec<&str> = args.iter().map(String::as_str).collect();
            self.run(&args).await.map(drop)
        })
    }

    fn subscribe(&self) -> io::Result<mpsc::Receiver<Dirty>> {
        let mut child = self
            .command()
            .arg("subscribe")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("pactl subscribe: no stdout"))?;
        let (tx, rx) = mpsc::channel(64);
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                tokio::select! {
                    () = tx.closed() => break,
                    line = lines.next_line() => {
                        let Ok(Some(line)) = line else { break };
                        let dirty = model::parse_event(&line);
                        if !dirty.is_empty() && tx.send(dirty).await.is_err() {
                            break;
                        }
                    }
                }
            }
            // Kills (when still running) and waits, so no zombie is left. If
            // this task is aborted instead, `kill_on_drop` does the same.
            let _ = child.kill().await;
        });
        Ok(rx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_missing_pactl_is_an_error_everywhere() {
        let pactl = Pactl {
            program: "/nonexistent/lugh-test-pactl".to_owned(),
        };
        assert!(pactl.read(Class::Sinks).await.is_err());
        assert!(pactl.write(Write::Muted(true)).await.is_err());
        assert!(pactl.subscribe().is_err());
    }

    #[tokio::test]
    async fn the_listener_ends_with_its_child_and_closes_the_channel() {
        // `true` stands in for a pactl whose server went away at once.
        let pactl = Pactl {
            program: "true".to_owned(),
        };
        let Ok(mut rx) = pactl.subscribe() else {
            return; // no coreutils here; nothing to test
        };
        let end = tokio::time::timeout(Duration::from_secs(5), rx.recv()).await;
        assert_eq!(end, Ok(None));
    }
}

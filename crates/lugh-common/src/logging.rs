//! Logging setup shared by all Lugh components.
//!
//! Output goes to stderr in `tracing`'s compact format without ANSI colours.
//! When the process runs under systemd (detected through `JOURNAL_STREAM`),
//! timestamps are dropped because journald records its own.

use tracing_subscriber::EnvFilter;
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::util::{SubscriberInitExt, TryInitError};

/// Environment variable holding the log filter, in `tracing` `EnvFilter`
/// syntax (e.g. `LUGH_LOG=debug` or `LUGH_LOG=info,zbus=warn`).
pub const LOG_ENV: &str = "LUGH_LOG";

/// Errors from [`init_logging`].
#[derive(Debug, thiserror::Error)]
pub enum LoggingError {
    /// A global `tracing` subscriber was already installed in this process.
    #[error("a global tracing subscriber is already installed")]
    AlreadyInitialized(#[from] TryInitError),
}

/// Installs the global `tracing` subscriber.
///
/// The filter comes from [`LOG_ENV`]; when it is unset, events at `INFO` and
/// above are shown. Invalid directives in the variable are ignored rather than
/// failing start-up. Call this once, early in `main`.
pub fn init_logging() -> Result<(), LoggingError> {
    let filter = EnvFilter::builder()
        .with_default_directive(LevelFilter::INFO.into())
        .with_env_var(LOG_ENV)
        .from_env_lossy();

    let builder = tracing_subscriber::fmt()
        .compact()
        .with_ansi(false)
        .with_target(true)
        .with_writer(std::io::stderr)
        .with_env_filter(filter);

    if under_journald() {
        builder.without_time().finish().try_init()?;
    } else {
        builder.finish().try_init()?;
    }
    Ok(())
}

/// systemd sets `JOURNAL_STREAM` when stderr is connected to the journal.
fn under_journald() -> bool {
    std::env::var_os("JOURNAL_STREAM").is_some_and(|v| !v.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn second_init_fails_cleanly() {
        // The first call may race with other tests in the same binary, so only
        // the second outcome is asserted.
        let _ = init_logging();
        assert!(matches!(
            init_logging(),
            Err(LoggingError::AlreadyInitialized(_))
        ));
        tracing::info!("logging initialised");
    }
}

//! Reboot and power off through logind (`org.freedesktop.login1.Manager`),
//! with `systemctl` as the fallback when the bus call fails.

use std::process::Command;

use zbus::blocking::Connection;

const DEST: &str = "org.freedesktop.login1";
const PATH: &str = "/org/freedesktop/login1";
const IFACE: &str = "org.freedesktop.login1.Manager";

/// A power action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Restart the machine.
    Reboot,
    /// Turn the machine off.
    PowerOff,
}

impl Action {
    fn method(self) -> &'static str {
        match self {
            Self::Reboot => "Reboot",
            Self::PowerOff => "PowerOff",
        }
    }

    fn can_method(self) -> &'static str {
        match self {
            Self::Reboot => "CanReboot",
            Self::PowerOff => "CanPowerOff",
        }
    }

    fn systemctl_verb(self) -> &'static str {
        match self {
            Self::Reboot => "reboot",
            Self::PowerOff => "poweroff",
        }
    }
}

/// True when logind's `Can*` answer allows the action without a prompt.
/// (`challenge` would need a polkit agent, which the greeter does not have.)
#[must_use]
pub fn allowed(answer: &str) -> bool {
    answer == "yes"
}

fn query(action: Action) -> zbus::Result<String> {
    let connection = Connection::system()?;
    let reply = connection.call_method(Some(DEST), PATH, Some(IFACE), action.can_method(), &())?;
    reply.body().deserialize()
}

/// Asks logind whether `action` is allowed. False when logind is unreachable.
#[must_use]
pub fn can(action: Action) -> bool {
    match query(action) {
        Ok(answer) => allowed(&answer),
        Err(err) => {
            tracing::debug!(%err, ?action, "logind query failed");
            false
        }
    }
}

fn request(action: Action) -> zbus::Result<()> {
    let connection = Connection::system()?;
    connection.call_method(Some(DEST), PATH, Some(IFACE), action.method(), &(false,))?;
    Ok(())
}

/// Runs `action`: logind first, then `systemctl`. The error is for the log.
pub fn run(action: Action) -> Result<(), String> {
    let bus_error = match request(action) {
        Ok(()) => return Ok(()),
        Err(err) => err.to_string(),
    };
    match Command::new("systemctl")
        .arg(action.systemctl_verb())
        .status()
    {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => Err(format!("logind: {bus_error}; systemctl: {status}")),
        Err(err) => Err(format!("logind: {bus_error}; systemctl: {err}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_yes_is_allowed() {
        assert!(allowed("yes"));
        for answer in ["no", "challenge", "na", "", "YES"] {
            assert!(!allowed(answer), "{answer}");
        }
    }

    #[test]
    fn names() {
        assert_eq!(Action::Reboot.method(), "Reboot");
        assert_eq!(Action::PowerOff.can_method(), "CanPowerOff");
        assert_eq!(Action::PowerOff.systemctl_verb(), "poweroff");
    }
}

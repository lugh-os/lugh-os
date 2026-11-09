//! D-Bus naming and connection helpers.
//!
//! Lugh services own well-known names under [`BUS_PREFIX`] with a version
//! suffix on the component (ARCHITECTURE §2), e.g. `space.lugh.Settings1`,
//! exported at the matching object path `/space/lugh/Settings1`.
//!
//! `zbus` is built on the tokio runtime (`default-features = false,
//! features = ["tokio"]`), so the helpers here must be awaited inside a tokio
//! runtime. The `zbus` crate is re-exported so callers use the same version.
//!
//! The `space.lugh` namespace is a placeholder until a domain is chosen; it
//! lives only in the constants below so the rename is a one-line change.

pub use zbus;

/// Prefix of every Lugh well-known bus name and interface name.
pub const BUS_PREFIX: &str = "space.lugh";

/// Prefix of every Lugh object path (the bus prefix with `.` → `/`).
pub const PATH_PREFIX: &str = "/space/lugh";

/// Well-known bus name for a component, e.g. `bus_name("Settings1")` →
/// `"space.lugh.Settings1"`.
///
/// `component` should be a versioned, CamelCase D-Bus name element
/// (`[A-Za-z_][A-Za-z0-9_]*`).
pub fn bus_name(component: &str) -> String {
    debug_assert!(
        is_valid_element(component),
        "invalid component {component:?}"
    );
    format!("{BUS_PREFIX}.{component}")
}

/// Object path for a component, e.g. `object_path("Settings1")` →
/// `"/space/lugh/Settings1"`.
pub fn object_path(component: &str) -> String {
    debug_assert!(
        is_valid_element(component),
        "invalid component {component:?}"
    );
    format!("{PATH_PREFIX}/{component}")
}

/// Connects to the user's session bus.
pub async fn connect_session() -> zbus::Result<zbus::Connection> {
    zbus::Connection::session().await
}

/// Connects to the system bus.
pub async fn connect_system() -> zbus::Result<zbus::Connection> {
    zbus::Connection::system().await
}

/// A name element valid in both bus names and object paths.
fn is_valid_element(s: &str) -> bool {
    let mut chars = s.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::names::{InterfaceName, WellKnownName};
    use zbus::zvariant::ObjectPath;

    #[test]
    fn names_follow_the_scheme() {
        assert_eq!(bus_name("Settings1"), "space.lugh.Settings1");
        assert_eq!(object_path("Settings1"), "/space/lugh/Settings1");
        assert_eq!(PATH_PREFIX, format!("/{}", BUS_PREFIX.replace('.', "/")));
    }

    #[test]
    fn names_are_valid_dbus() {
        for c in ["Settings1", "Tasks1", "Config1", "Update1", "Shield1"] {
            WellKnownName::try_from(bus_name(c)).unwrap();
            InterfaceName::try_from(bus_name(c)).unwrap();
            ObjectPath::try_from(object_path(c)).unwrap();
        }
    }

    #[test]
    fn element_validation() {
        assert!(is_valid_element("Store1"));
        assert!(is_valid_element("_x"));
        assert!(!is_valid_element(""));
        assert!(!is_valid_element("1Store"));
        assert!(!is_valid_element("a.b"));
        assert!(!is_valid_element("a-b"));
    }
}

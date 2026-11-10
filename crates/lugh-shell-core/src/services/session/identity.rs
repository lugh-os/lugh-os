//! Who is logged in and on what: user, host, OS, avatar.

use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

/// The static part of the session state.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Identity {
    pub(crate) uid: u32,
    pub(crate) user_name: String,
    pub(crate) real_name: String,
    pub(crate) home: Option<PathBuf>,
    pub(crate) host_name: String,
    pub(crate) os_version: String,
}

/// `(name, real name, home)` of `uid` from passwd(5) text. The real name is
/// the first GECOS field, or the login name when that is empty.
pub(crate) fn passwd_entry(passwd: &str, uid: u32) -> Option<(String, String, PathBuf)> {
    passwd.lines().find_map(|line| {
        let mut f = line.split(':');
        let name = f.next()?;
        let _password = f.next()?;
        if f.next()?.parse::<u32>().ok()? != uid {
            return None;
        }
        let _gid = f.next()?;
        let gecos = f.next()?;
        let home = f.next()?;
        let real = gecos.split(',').next().unwrap_or_default().trim();
        let real = if real.is_empty() { name } else { real };
        Some((name.to_owned(), real.to_owned(), PathBuf::from(home)))
    })
}

/// `PRETTY_NAME` from os-release(5) text.
pub(crate) fn pretty_name(os_release: &str) -> Option<String> {
    os_release.lines().find_map(|line| {
        let value = line.trim().strip_prefix("PRETTY_NAME=")?.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
            .unwrap_or(value);
        let value = value.replace("\\\"", "\"").replace("\\\\", "\\");
        (!value.is_empty()).then_some(value)
    })
}

/// `file://` URL of an absolute path (percent-encoded).
pub(crate) fn file_url(path: &Path) -> String {
    use std::fmt::Write as _;
    use std::os::unix::ffi::OsStrExt as _;
    let mut url = String::from("file://");
    for &b in path.as_os_str().as_bytes() {
        if b.is_ascii_alphanumeric() || b"/-._~".contains(&b) {
            url.push(char::from(b));
        } else {
            let _ = write!(url, "%{b:02X}");
        }
    }
    url
}

/// URL of the first candidate that is a readable regular file, else `""`.
pub(crate) fn avatar_url<'a>(candidates: impl IntoIterator<Item = &'a Path>) -> String {
    candidates
        .into_iter()
        .find(|p| p.is_absolute() && p.is_file() && std::fs::File::open(p).is_ok())
        .map(file_url)
        .unwrap_or_default()
}

/// The uid of this process (owner of `/proc/self`; no libc call needed).
pub(crate) fn current_uid() -> Option<u32> {
    std::fs::metadata("/proc/self").ok().map(|m| m.uid())
}

/// Reads the identity of the current user from the system. Local files
/// only; an account that lives in a directory service falls back to `$USER`
/// and `$HOME`.
pub(crate) fn read() -> Identity {
    let uid = current_uid().unwrap_or(u32::MAX);
    let entry = std::fs::read_to_string("/etc/passwd")
        .ok()
        .and_then(|text| passwd_entry(&text, uid));
    let (user_name, real_name, home) = match entry {
        Some((name, real, home)) => (name, real, Some(home)),
        None => {
            let name = std::env::var("USER")
                .or_else(|_| std::env::var("LOGNAME"))
                .unwrap_or_default();
            (name.clone(), name, None)
        }
    };
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|h| h.is_absolute())
        .or(home);
    let host_name = ["/proc/sys/kernel/hostname", "/etc/hostname"]
        .iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .map(|s| s.trim().to_owned())
        .find(|s| !s.is_empty())
        .unwrap_or_default();
    let os_version = ["/etc/os-release", "/usr/lib/os-release"]
        .iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .find_map(|text| pretty_name(&text))
        .unwrap_or_else(|| "Lugh".to_owned());
    Identity {
        uid,
        user_name,
        real_name,
        home,
        host_name,
        os_version,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PASSWD: &str = "root:x:0:0:root:/root:/bin/bash\n\
        amara:x:1000:1000:Amara Nkusi,,,:/home/amara:/bin/bash\n\
        bare:x:1001:1001::/home/bare:/bin/sh\n\
        broken line\n\
        kofi:x:1002:1002:Kofi:/home/kofi:/bin/zsh\n";

    #[test]
    fn passwd_lookup() {
        assert_eq!(
            passwd_entry(PASSWD, 1000),
            Some((
                "amara".into(),
                "Amara Nkusi".into(),
                PathBuf::from("/home/amara")
            ))
        );
        // Empty GECOS: the login name.
        assert_eq!(
            passwd_entry(PASSWD, 1001).map(|e| e.1),
            Some("bare".to_owned())
        );
        assert_eq!(
            passwd_entry(PASSWD, 1002).map(|e| e.1),
            Some("Kofi".to_owned())
        );
        assert_eq!(passwd_entry(PASSWD, 4242), None);
    }

    #[test]
    fn os_release_pretty_name() {
        assert_eq!(
            pretty_name("NAME=Lugh\nPRETTY_NAME=\"Lugh 0.1 (trixie)\"\nID=lugh\n"),
            Some("Lugh 0.1 (trixie)".to_owned())
        );
        assert_eq!(
            pretty_name("PRETTY_NAME=Debian\n"),
            Some("Debian".to_owned())
        );
        assert_eq!(pretty_name("PRETTY_NAME='A B'\n"), Some("A B".to_owned()));
        assert_eq!(pretty_name("NAME=x\nPRETTY_NAME=\"\"\n"), None);
    }

    #[test]
    fn urls_and_avatar() {
        assert_eq!(
            file_url(Path::new("/home/a b/é.png")),
            "file:///home/a%20b/%C3%A9.png"
        );
        let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
        let face = dir.path().join(".face");
        let missing = dir.path().join("nope.png");
        assert_eq!(avatar_url([missing.as_path(), face.as_path()]), "");
        std::fs::write(&face, b"png").unwrap_or_else(|e| panic!("write: {e}"));
        assert_eq!(
            avatar_url([missing.as_path(), face.as_path()]),
            file_url(&face)
        );
        // A directory or a relative path is never an avatar.
        assert_eq!(avatar_url([dir.path(), Path::new("relative.png")]), "");
    }

    #[test]
    fn reads_this_machine() {
        let me = read();
        assert!(!me.user_name.is_empty());
        assert!(!me.real_name.is_empty());
        assert!(!me.os_version.is_empty());
    }
}

//! Human accounts for the user list.
//!
//! A human account has a uid inside `UID_MIN..=UID_MAX` (`/etc/login.defs`,
//! 1000..=60000 by default) and a real login shell. The avatar is the
//! AccountsService icon (`/var/lib/AccountsService/icons/<user>`) or
//! `~/.face`, when the greeter user can read it.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

/// Inclusive uid range of human accounts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UidRange {
    /// `UID_MIN`.
    pub min: u32,
    /// `UID_MAX`.
    pub max: u32,
}

impl Default for UidRange {
    fn default() -> Self {
        Self {
            min: 1000,
            max: 60000,
        }
    }
}

/// Reads `UID_MIN` / `UID_MAX` from the text of `/etc/login.defs`.
#[must_use]
pub fn parse_login_defs(text: &str) -> UidRange {
    let mut range = UidRange::default();
    for line in text.lines() {
        let mut words = line.split('#').next().unwrap_or("").split_whitespace();
        let (Some(key), Some(value)) = (words.next(), words.next()) else {
            continue;
        };
        let Ok(value) = value.parse::<u32>() else {
            continue;
        };
        match key {
            "UID_MIN" => range.min = value,
            "UID_MAX" => range.max = value,
            _ => {}
        }
    }
    range
}

/// One `/etc/passwd` account that may log in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account {
    /// Login name.
    pub user_name: String,
    /// Full name from GECOS, or the login name.
    pub real_name: String,
    /// Numeric id.
    pub uid: u32,
    /// Home directory.
    pub home: PathBuf,
}

fn shell_allows_login(shell: &str) -> bool {
    // An empty field means /bin/sh.
    let name = shell.rsplit('/').next().unwrap_or(shell);
    !matches!(name, "nologin" | "false")
}

fn real_name(gecos: &str, user_name: &str) -> String {
    let full = gecos.split(',').next().unwrap_or("").trim();
    if full.is_empty() {
        return user_name.to_owned();
    }
    // GECOS convention: `&` stands for the capitalised login name.
    if full.contains('&') {
        let mut chars = user_name.chars();
        let capitalised: String = chars
            .next()
            .map(|c| c.to_uppercase().chain(chars).collect())
            .unwrap_or_default();
        return full.replace('&', &capitalised);
    }
    full.to_owned()
}

/// Human accounts in the text of `/etc/passwd`, sorted by real name.
#[must_use]
pub fn parse_passwd(text: &str, range: UidRange) -> Vec<Account> {
    let mut accounts: Vec<Account> = text
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let fields: Vec<&str> = line.split(':').collect();
            let [name, _password, uid, _gid, gecos, home, shell] = fields.as_slice() else {
                return None;
            };
            let uid = uid.parse::<u32>().ok()?;
            if name.is_empty() || uid < range.min || uid > range.max || !shell_allows_login(shell) {
                return None;
            }
            Some(Account {
                user_name: (*name).to_owned(),
                real_name: real_name(gecos, name),
                uid,
                home: PathBuf::from(home),
            })
        })
        .collect();
    accounts.sort_by(|a, b| {
        a.real_name
            .to_lowercase()
            .cmp(&b.real_name.to_lowercase())
            .then_with(|| a.user_name.cmp(&b.user_name))
    });
    accounts.dedup_by(|b, a| a.user_name == b.user_name);
    accounts
}

fn readable(path: &Path) -> bool {
    path.is_file() && fs::File::open(path).is_ok()
}

/// The avatar file of `account`, if one exists that this process can read.
#[must_use]
pub fn avatar_path(account: &Account, icons_dir: &Path) -> Option<PathBuf> {
    [
        icons_dir.join(&account.user_name),
        account.home.join(".face"),
        account.home.join(".face.icon"),
    ]
    .into_iter()
    .find(|p| readable(p))
}

/// `file://` URL of an absolute path, percent-encoded.
#[must_use]
pub fn file_url(path: &Path) -> String {
    use std::fmt::Write as _;
    use std::os::unix::ffi::OsStrExt as _;
    let mut url = String::from("file://");
    for &byte in path.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte) {
            url.push(char::from(byte));
        } else {
            let _ = write!(url, "%{byte:02X}");
        }
    }
    url
}

/// A user as the greeter UI wants it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserEntry {
    /// Login name.
    pub user_name: String,
    /// Display name.
    pub real_name: String,
    /// File URL of the picture, or `""`.
    pub avatar: String,
}

/// Loads the user list from the given files. Missing files give an empty list.
#[must_use]
pub fn load(passwd: &Path, login_defs: &Path, icons_dir: &Path) -> Vec<UserEntry> {
    let range = fs::read_to_string(login_defs)
        .map(|text| parse_login_defs(&text))
        .unwrap_or_default();
    let text = fs::read_to_string(passwd).unwrap_or_default();
    parse_passwd(&text, range)
        .into_iter()
        .map(|account| UserEntry {
            avatar: avatar_path(&account, icons_dir)
                .map(|p| file_url(&p))
                .unwrap_or_default(),
            user_name: account.user_name,
            real_name: account.real_name,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PASSWD: &str = "\
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
_greetd:x:997:997::/var/lib/greetd:/usr/sbin/nologin
keza:x:1001:1001:Keza Uwase,,,:/home/keza:/bin/bash
amara:x:1000:1000:Amara Nkusi:/home/amara:/usr/bin/zsh
svc:x:1002:1002:Service:/srv:/usr/sbin/nologin
locked:x:1003:1003::/home/locked:/bin/false
plain:x:1004:1004::/home/plain:
amp:x:1005:1005:& the Great:/home/amp:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
broken line
bad:x:notanumber:1:Bad:/home/bad:/bin/sh
";

    #[test]
    fn login_defs() {
        assert_eq!(parse_login_defs(""), UidRange::default());
        let range = parse_login_defs("# c\nUID_MIN\t\t 500 # x\nUID_MAX 9999\nUID_MIN junk\n");
        assert_eq!(
            range,
            UidRange {
                min: 500,
                max: 9999
            }
        );
    }

    #[test]
    fn passwd_filters_and_sorts() {
        let accounts = parse_passwd(PASSWD, UidRange::default());
        let names: Vec<&str> = accounts.iter().map(|a| a.user_name.as_str()).collect();
        assert_eq!(names, ["amara", "amp", "keza", "plain"]);
        assert_eq!(accounts[0].real_name, "Amara Nkusi");
        assert_eq!(accounts[1].real_name, "Amp the Great");
        assert_eq!(accounts[2].real_name, "Keza Uwase");
        assert_eq!(accounts[3].real_name, "plain");
        assert_eq!(accounts[0].home, PathBuf::from("/home/amara"));
    }

    #[test]
    fn passwd_garbage_is_ignored() {
        assert!(parse_passwd("::::::\n\0\0\n:::::::::\n", UidRange::default()).is_empty());
    }

    #[test]
    fn avatars_and_urls() {
        let dir = tempfile::tempdir().unwrap();
        let icons = dir.path().join("icons");
        let home = dir.path().join("home dir");
        fs::create_dir_all(&icons).unwrap();
        fs::create_dir_all(&home).unwrap();
        let account = Account {
            user_name: "amara".into(),
            real_name: "Amara".into(),
            uid: 1000,
            home: home.clone(),
        };
        assert_eq!(avatar_path(&account, &icons), None);
        fs::write(home.join(".face"), b"png").unwrap();
        assert_eq!(avatar_path(&account, &icons), Some(home.join(".face")));
        fs::write(icons.join("amara"), b"png").unwrap();
        assert_eq!(avatar_path(&account, &icons), Some(icons.join("amara")));
        assert_eq!(
            file_url(Path::new("/a b/é.png")),
            "file:///a%20b/%C3%A9.png"
        );
    }

    #[test]
    fn load_tolerates_missing_files() {
        let none = Path::new("/nonexistent/lugh-greetd-test");
        assert!(load(none, none, none).is_empty());
    }
}

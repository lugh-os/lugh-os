//! Qt-free core of `lugh-greeter` (the greetd login screen).
//!
//! - [`ipc`]: greetd IPC client (framing, messages, login conversation).
//! - [`users`]: human accounts from `/etc/passwd`, with avatars.
//! - [`sessions`]: Wayland sessions from `/usr/share/wayland-sessions`.
//! - [`state`]: last user and session, persisted between boots.
//! - [`power`]: reboot and power off through logind.
//! - [`backend`]: the worker that ties these together for the UI bridge.
//! - [`fake`]: a scripted greetd server for tests and the end-to-end check.

pub mod backend;
pub mod fake;
pub mod ipc;
pub mod power;
pub mod sessions;
pub mod state;
pub mod users;

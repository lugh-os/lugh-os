# lugh-greeter

The Lugh sign-in screen: a QML app that greetd runs inside the `cage` kiosk
compositor (shell spec §Greeter, phase-1 §5). It is drawn in the liquid
language of the lock screen (docs/design/lugh-mode.md §3): the blurred
wallpaper, the clock as the hero, the password in a floating glass capsule and
small glass capsules in the bottom corners, so signing in and unlocking feel
like one product.

```
ui/greeter/qml/
  main.qml         Window (full screen) hosting Greeter; picks the real backend or the mock
  Greeter.qml      the UI (an Item; loadable on its own with its own MockGreetd)
  MockGreetd.qml   the backend contract, mocked (password "lugh" works)
  AuthCapsule.qml  the glass password capsule (copy of the lock screen's; keep identical)
  Avatar.qml       round user picture / initials (copy of the lock screen's)
  backend/         GreetdBackend.qml, the adapter over the Rust host's object
  GreeterDemo.qml  demo with flags, for screenshots
```

The QML imports only `Lugh.UI` (`ui/components`). It deliberately does not
import `Lugh.Shell`: that module's `Services` belongs to the user session.

## Running it

```sh
qml6 -I ui/components ui/greeter/qml/main.qml          # mock backend, password "lugh"
QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/greeter/qml/GreeterDemo.qml \
    /tmp/lugh-shots/greeter/light.png 1440 900 900 -- --error --caps
```

Demo flags: `--dark`, `--error`, `--busy`, `--caps`, `--many` (14 users, so the
username capsule shows), `--hide` (`hide_users`), `--sessions` (two sessions, so
the session picker shows), `--prompt` (a second prompt: one-time code, answer
`123456`), `--info` (a PAM info line with the prompt), `--slow` (PAM takes 2 s),
`--typed`, `--reduce`, `--a11y` (accessibility menu open), `--confirm`
(shut-down dialog).

Motion capture: `--motion <error-shake|unlock|user-switch> --frames <dir>` saves
a scene grab every 33 ms to `<dir>/<kind>-NN.png` (give `qml-shot.sh` a delay of
4000); `montage <dir>/<kind>-*.png -tile 6x4 sheet.png` makes the contact sheet.

## States

| State | What shows |
|---|---|
| Idle | clock and date; user row (selected avatar large, centered, named); password capsule focused; logo + host name bottom left; keyboard layout, accessibility and power capsules bottom right (session capsule only with more than one session) |
| User switch | Left/Right, Home/End or a click: the row glides on the liquid spring; an open greetd session is cancelled, the field and messages clear |
| Username mode | more than 10 users, none, or `hideUsers`: a username capsule above the password one; Enter in it moves to the password |
| Waiting | from submit until greetd answers (PAM may take seconds): spinner in the submit button, field read-only, user switching off |
| Further prompt | a prompt that arrives when no typed password is waiting (one-time code…): its text becomes the placeholder and accessible label, masked only if `secret`; an empty answer is allowed |
| Info | `infoMessage` text in a small capsule under the field |
| Error | `authFailed`: capsule shakes (not under reduce motion), field clears and refocuses, the message shows verbatim under the field; Caps Lock warning shares that capsule |
| Signed in | `authSucceeded`: the capsule contracts into a dot, the scene fades, `startSession(exec)` is called and "Starting <session>…" stays until greetd ends the process; `errorOccurred` brings the form back |

Nothing animates while the screen rests; the clock repaints once a minute.
Under reduce motion every movement becomes a short fade or an instant change.

Keyboard: Left/Right switch users when the password field is empty, or at any
time when the user row has focus (it's a Tab stop; Home/End too). Enter submits
and Esc clears the field (and cancels a pending greetd session when it's
empty). Typing while a button has focus goes into the password field. Tab
order: users, (username), password, show password, sign in, session, keyboard
layout, accessibility, restart, shut down.

Assets: run from the source tree, the greeter loads the logo and wallpapers
from `branding/`. Installed, it loads them from the lugh-branding paths
(`/usr/share/lugh/branding/logo/`, `/usr/share/backgrounds/lugh/`).

## Production wiring

```
/etc/greetd/config.toml
  [terminal]  vt = 1
  [default_session]
  command = "cage -s -d -- lugh-greeter"
  user = "_greetd"
```

`lugh-greeter` is a small Rust binary (planned crate: `crates/lugh-greeter`,
cxx-qt like the shell). It:

1. creates a `QGuiApplication`, sets `QIcon::setThemeName` (with `hicolor` as
   the fallback), and loads fonts (Inter is a dependency of the package);
2. creates the backend object (below), sets it as the root context property
   **`greetdBackend`**, then loads `qml/main.qml` with the `Lugh.UI` import path.
   Without that property, `main.qml` falls back to `MockGreetd`;
3. talks to greetd over `$GREETD_SOCK` (native-endian u32 length + JSON), to
   AccountsService (`org.freedesktop.Accounts`) for users and avatars, to
   logind for reboot/power off, and reads `/usr/share/wayland-sessions/*.desktop`
   for sessions.

If `lugh-greeter` fails to start 3 times, greetd falls back to `tuigreet`
(phase-1 §5).

## Backend contract

The object must expose exactly these names (the mock in `MockGreetd.qml` is the
reference, with comments).

### Properties

| Name | Type | Meaning |
|---|---|---|
| `users` | list of `{userName, realName, avatar}` | non-system accounts from AccountsService, sorted by real name; `avatar` is a file URL or `""` |
| `hideUsers` | bool | admin setting (`/etc/lugh/greeter.toml` `hide_users`): shows a username field instead of the list |
| `lastUser` | string | user name to preselect (`""` = first) |
| `sessions` | list of `{id, name, comment, exec}` | installed Wayland sessions; the picker shows only when there are more than one |
| `lastSession` | string | session `id` to preselect |
| `authenticating` | bool | true from `createSession` until success, failure or cancel |
| `sessionUser` | string | user of the open greetd session, `""` when none |
| `hostName` | string | shown next to the logo |
| `canReboot`, `canPowerOff` | bool | logind `CanReboot` / `CanPowerOff` = "yes"; hides the button otherwise |
| `wallpaper` | string | copy of the user's wallpaper in `/var/lib/lugh-greeter/` (only with their consent), `""` = the default Lugh wallpaper |
| `layouts` | list of string | XKB layouts (from `/etc/default/keyboard`) |
| `layout` | string | current layout; the backend applies it (cage reads `XKB_DEFAULT_LAYOUT`, so switching needs a keymap update through the seat) |
| `capsLock` | bool | Caps Lock state, for the warning |
| `screenReader`, `onScreenKeyboard`, `largeText`, `highContrast` | bool, writable | the accessibility menu writes them; the backend starts or stops Orca and the on-screen keyboard, and sets the large-text / high-contrast flags (today these are mock-only in the UI, see below) |

### Functions

| Call | greetd request | Notes |
|---|---|---|
| `createSession(userName)` | `create_session` | cancels any open session first |
| `respond(text)` | `post_auth_message_response` | answer to the last prompt |
| `cancelSession()` | `cancel_session` | |
| `startSession(exec)` | `start_session { cmd: shell-split(exec), env: [] }` | greetd then ends the greeter |
| `nextLayout()` | — | cycles `layouts` |
| `reboot()`, `powerOff()` | — | logind `Reboot(false)` / `PowerOff(false)` |

### Signals

| Signal | When |
|---|---|
| `promptRequested(bool secret, string text)` | greetd `auth_message` of type `secret` (secret = true) or `visible` |
| `infoMessage(string text)` | `auth_message` of type `info` or `error` (PAM chatter, such as "Your password expires in 3 days") |
| `authSucceeded()` | greetd `success` after the last response |
| `authFailed(string message)` | greetd `error` (`auth_error`): a plain-language message. The backend has already sent `cancel_session`, so the next attempt starts with `createSession` again. For a listed user say "Wrong password. Try again."; for a typed username never reveal whether the account exists ("Wrong username or password. Try again.") |
| `sessionStarted()` | `start_session` succeeded |
| `errorOccurred(string message)` | IPC failure, or a power action refused |

### Flow the UI runs

```
submit ──► createSession(user) ──► promptRequested(secret) ──► respond(password)
                                           │                        │
                                           │              ┌─────────┴──────────┐
                                           ▼              ▼                    ▼
                                (another prompt:     authSucceeded()      authFailed(msg)
                                 the field asks       capsule → dot,       capsule shakes,
                                 for it, e.g. OTP)    startSession(exec)   clears, refocuses
```

## Known gaps

- The accessibility toggles only flip backend flags. Large text and high
  contrast need Theme support (a font scale and a high-contrast palette) that
  `Lugh.UI` doesn't have yet.
- Qt blanks `Accessible.name` on items with `Accessible.passwordEdit`, so the
  password field's label ("Password for Amara Nkusi") is also carried in
  `Accessible.description`.
- No fingerprint (fprintd) prompt yet; it would arrive as an extra `visible`
  prompt or `info` message through PAM.

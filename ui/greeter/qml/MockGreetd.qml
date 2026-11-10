// Mock greeter backend: the QML-facing contract of lugh-greeter's Rust object
// (greetd JSON IPC over $GREETD_SOCK, AccountsService users, logind power,
// keyboard layouts, accessibility switches). Production registers an object
// with exactly these names (see ../README.md); this mock is used by the demo,
// screenshots and QML tests.
//
// Dev conveniences: the password "lugh" works for every listed user; any other
// password fails after ~0.7 s. A typed username that isn't listed fails with
// the same generic message (no account probing).
import QtQuick

QtObject {
    id: greetd

    // ---- accounts (AccountsService, non-system users, sorted by real name) --
    // [{ userName, realName, avatar (file URL or "") }]
    property var users: [
        { userName: "amara", realName: "Amara Nkusi", avatar: "" },
        { userName: "keza", realName: "Keza Uwase", avatar: "" },
        { userName: "jeanpaul", realName: "Jean-Paul Habimana", avatar: "" }
    ]
    // The admin can hide the list (greeter.toml `hide_users = true`).
    property bool hideUsers: false
    // Last user who logged in (preselected), "" if none.
    property string lastUser: "amara"

    // ---- sessions (/usr/share/wayland-sessions/*.desktop) --------------------
    // [{ id, name, comment, exec }]; exec is the command handed to start_session.
    property var sessions: [
        { id: "lugh", name: "Lugh", comment: "The Lugh desktop", exec: "lugh-session" }
    ]
    property string lastSession: "lugh"

    // ---- auth state ---------------------------------------------------------
    // True from createSession() until success/failure/cancel.
    property bool authenticating: false
    // User of the open greetd session, "" when none.
    property string sessionUser: ""

    // ---- machine ------------------------------------------------------------
    property string hostName: "lugh-laptop"
    property bool canReboot: true
    property bool canPowerOff: true
    // Wallpaper copied for the greeter (/var/lib/lugh-greeter/), "" = default.
    property string wallpaper: ""

    // ---- keyboard -----------------------------------------------------------
    property var layouts: ["us", "fr"]
    property string layout: "us"
    property bool capsLock: false
    function nextLayout() {
        const i = layouts.indexOf(layout);
        layout = layouts[(i + 1) % layouts.length];
    }

    // ---- accessibility (applied by the backend: Orca, squeekboard, fonts) ---
    property bool screenReader: false
    property bool onScreenKeyboard: false
    property bool largeText: false
    property bool highContrast: false

    // ---- signals --------------------------------------------------------------
    // greetd auth_message: secret = auth_message_type "secret" (else "visible").
    signal promptRequested(bool secret, string text)
    // greetd auth_message of type "info" / "error" (PAM chatter), shown inline.
    signal infoMessage(string text)
    // Authentication finished; the session is ready for startSession().
    signal authSucceeded()
    // Plain-language reason. The backend has already cancelled the greetd
    // session, so the next attempt starts with createSession() again.
    signal authFailed(string message)
    // start_session accepted: greetd ends the greeter shortly after.
    signal sessionStarted()
    // Power action or IPC failure, plain language.
    signal errorOccurred(string message)

    // ---- greetd IPC -----------------------------------------------------------
    // create_session { username }. Answers with promptRequested (or
    // authSucceeded for password-less accounts).
    function createSession(userName) {
        if (authenticating) cancelSession();
        sessionUser = userName;
        authenticating = true;
        _prompt.restart();
    }
    // post_auth_message_response { response }.
    function respond(response) {
        if (sessionUser === "") { errorOccurred(qsTr("No login in progress.")); return; }
        _check.response = response;
        _check.restart();
    }
    // cancel_session.
    function cancelSession() {
        _prompt.stop();
        _check.stop();
        authenticating = false;
        sessionUser = "";
    }
    // start_session { cmd: [exec…], env: [] }.
    function startSession(exec) {
        console.info("[mock greetd] start_session", JSON.stringify(exec), "for", sessionUser);
        sessionStarted();
    }

    // ---- power (logind) -------------------------------------------------------
    function reboot() { console.info("[mock greetd] reboot"); }
    function powerOff() { console.info("[mock greetd] power off"); }

    // ---- mock internals -----------------------------------------------------
    function _known(userName) {
        for (const u of users) if (u.userName === userName) return true;
        return false;
    }
    property Timer _prompt: Timer {
        interval: 120
        onTriggered: greetd.promptRequested(true, "Password:")
    }
    property Timer _check: Timer {
        property string response
        interval: 700
        onTriggered: {
            const ok = response === "lugh" && greetd._known(greetd.sessionUser);
            greetd.authenticating = false;
            if (ok) {
                greetd.lastUser = greetd.sessionUser;
                greetd.authSucceeded();
            } else {
                // A listed user gets the specific message; a typed name never
                // reveals whether the account exists.
                const listed = greetd._known(greetd.sessionUser) && !greetd.hideUsers
                               && greetd.users.length <= 10;
                greetd.sessionUser = "";
                greetd.authFailed(listed ? qsTr("Wrong password. Try again.")
                                         : qsTr("Wrong username or password. Try again."));
            }
        }
    }
}

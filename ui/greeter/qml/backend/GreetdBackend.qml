// The real greeter backend, as QML sees it: this object is the root context
// property `greetdBackend` and implements the contract of ../../README.md
// (MockGreetd.qml is the reference). It is compiled into the lugh-greeter
// binary (module os.lugh.greeter) and only adapts: every call goes to the
// Rust bridge, every bridge event becomes a property change or a signal.
import QtQuick
import os.lugh.greeter

QtObject {
    id: backend

    // ---- accounts -----------------------------------------------------------
    property var users: []          // [{ userName, realName, avatar }]
    property bool hideUsers: false
    property string lastUser: ""

    // ---- sessions -------------------------------------------------------------
    property var sessions: []       // [{ id, name, comment, exec }]
    property string lastSession: ""

    // ---- auth state -----------------------------------------------------------
    property bool authenticating: false
    property string sessionUser: ""

    // ---- machine --------------------------------------------------------------
    property string hostName: ""
    property bool canReboot: false
    property bool canPowerOff: false
    property string wallpaper: ""

    // ---- keyboard -------------------------------------------------------------
    property var layouts: ["us"]
    property string layout: "us"
    // Set by the host's Caps Lock watcher (cpp/shim.cpp).
    property bool capsLock: false
    // cage takes its keymap from XKB_DEFAULT_* at start and has no protocol to
    // switch it at run time, so there is nothing to apply here yet.
    function nextLayout() {}

    // ---- accessibility (flags only for now, see README "Known gaps") ----------
    property bool screenReader: false
    property bool onScreenKeyboard: false
    property bool largeText: false
    property bool highContrast: false

    // ---- signals --------------------------------------------------------------
    signal promptRequested(bool secret, string text)
    signal infoMessage(string text)
    signal authSucceeded()
    signal authFailed(string message)
    signal sessionStarted()
    signal errorOccurred(string message)

    // ---- greetd ---------------------------------------------------------------
    function createSession(userName) {
        // The backend cancels an open session first. Reflect the new state at
        // once; the backend's state event confirms it.
        sessionUser = userName;
        authenticating = true;
        _bridge.call("createSession", userName);
    }
    function respond(response) { _bridge.call("respond", response); }
    function cancelSession() {
        authenticating = false;
        sessionUser = "";
        _bridge.call("cancelSession", "");
    }
    function startSession(exec) { _bridge.call("startSession", exec); }

    // ---- power ------------------------------------------------------------------
    function reboot() { _bridge.call("reboot", ""); }
    function powerOff() { _bridge.call("powerOff", ""); }

    // ---- internals --------------------------------------------------------------
    // { user, password }: only ever set by a binary built with `test-hooks`.
    property var _autotest: null

    property GreetdBridge _bridge: GreetdBridge {
        onNotified: json => backend._handle(JSON.parse(json))
    }

    function _handle(e) {
        switch (e.event) {
        case "state":
            authenticating = e.authenticating;
            sessionUser = e.sessionUser;
            if (e.lastUser !== undefined) lastUser = e.lastUser;
            break;
        case "power":
            canReboot = e.canReboot;
            canPowerOff = e.canPowerOff;
            break;
        case "promptRequested":
            promptRequested(e.secret, e.text);
            if (_autotest) respond(_autotest.password);
            break;
        case "infoMessage":
            infoMessage(e.text);
            break;
        case "authSucceeded":
            authSucceeded();
            if (_autotest) startSession(sessions[0].exec);
            break;
        case "authFailed":
            authFailed(e.message);
            if (_autotest) Qt.exit(1);
            break;
        case "sessionStarted":
            sessionStarted();
            break;
        case "errorOccurred":
            errorOccurred(e.message);
            if (_autotest) Qt.exit(1);
            break;
        }
    }

    Component.onCompleted: {
        const s = JSON.parse(_bridge.init());
        users = s.users;
        hideUsers = s.hideUsers;
        lastUser = s.lastUser;
        sessions = s.sessions;
        lastSession = s.lastSession;
        hostName = s.hostName;
        wallpaper = s.wallpaper;
        layouts = s.layouts;
        layout = s.layout;
        if (s.autotest) {
            _autotest = s.autotest;
            Qt.callLater(() => backend.createSession(s.autotest.user));
        }
    }
}

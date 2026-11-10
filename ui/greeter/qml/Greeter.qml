// lugh-greeter UI in the liquid language (docs/design/lugh-mode.md §3 "Lock /
// greeter"). One product with the lock screen: the blurred wallpaper, the
// clock as the hero, the password in a floating glass capsule, small glass
// capsules in the bottom corners.
//
//   Greeter { anchors.fill: parent; backend: greetdBackend }
//
// Works on its own too (its own MockGreetd), so it can be loaded directly:
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/greeter/qml/Greeter.qml out.png 1440 900
//
// Users: avatars in a row, the selected one larger, centered and named; a
// switch glides (Left/Right, Home/End, click). More than `maxListedUsers`
// accounts, none, or backend.hideUsers → a username capsule instead. The
// session picker shows only when more than one session is installed.
//
// Auth (greetd): submit → createSession(user) → promptRequested → respond(pw).
//   - Waiting (PAM may take 2 s): spinner in the submit button, field read-only.
//   - A further prompt (one-time code…): its text becomes the placeholder and
//     the field takes the answer (masked only if the prompt is secret).
//   - infoMessage: an info capsule under the field. authFailed: the capsule
//     shakes (not under reduce motion), clears, refocuses; the message shows
//     verbatim in a capsule under the field, which stays usable.
//   - authSucceeded: the capsule contracts into a dot, the scene fades,
//     startSession(exec) is called and a calm "Starting…" line stays until
//     greetd ends the process. errorOccurred brings the form back.
//
// Depends only on Lugh.UI (no Lugh.Shell, whose Services belong to the user
// session). Assets come from the repo when run from the source tree, else from
// the lugh-branding install paths.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

FocusScope {
    id: root

    property QtObject backend: _mock
    property int maxListedUsers: 10

    readonly property var users: backend.users || []
    readonly property var sessions: backend.sessions || []
    readonly property bool listMode: !backend.hideUsers && users.length > 0 && users.length <= maxListedUsers
    property int currentIndex: 0
    readonly property var currentUser: listMode && currentIndex < users.length ? users[currentIndex] : null
    property int sessionIndex: 0
    readonly property var currentSession: sessions.length > 0 ? sessions[Math.min(sessionIndex, sessions.length - 1)] : null

    property string errorText: ""
    property string infoText: ""
    // Waiting for greetd / PAM (not while a further prompt waits for the user).
    readonly property bool busy: backend.authenticating && !_awaitingAnswer && !_succeeded
    // Signed in; the session is being started.
    readonly property bool starting: _starting
    // True while the capsule or the user row moves (tests).
    readonly property bool animating: capsule.animating || picker.gliding

    property bool _succeeded: false
    property bool _starting: false
    property string _pending: ""          // password waiting for the first prompt
    property bool _awaitingAnswer: false  // a prompt arrived with nothing pending
    property string _promptText: ""
    property bool _promptSecret: true
    property bool _ready: false

    // ---- assets (repo when run from the source tree) ------------------------
    readonly property bool _devTree: Qt.resolvedUrl(".").toString().indexOf("/ui/greeter/qml/") >= 0
    readonly property string _logoDir: _devTree ? Qt.resolvedUrl("../../../branding/logo/")
                                                : "file:///usr/share/lugh/branding/logo/"
    readonly property string _wallDir: _devTree ? Qt.resolvedUrl("../../../branding/wallpapers/")
                                                : "file:///usr/share/backgrounds/lugh/"

    property MockGreetd _mock: MockGreetd {}

    focus: true
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Sign in to %1").arg(backend.hostName)

    // ---- behaviour ---------------------------------------------------------------
    function selectUser(i) {
        if (!listMode || i < 0 || i >= users.length || i === currentIndex || busy || _succeeded) return;
        if (backend.sessionUser !== "") backend.cancelSession();
        currentIndex = i;
        _pending = "";
        _awaitingAnswer = false;
        errorText = "";
        infoText = "";
        capsule.clear();
    }
    function submit() {
        if (busy || _succeeded) return;
        if (!listMode && userCapsule.text.trim() === "") { userCapsule.focusField(); return; }
        if (_awaitingAnswer && backend.sessionUser !== "") {
            errorText = "";
            infoText = "";
            _awaitingAnswer = false;
            backend.respond(capsule.text);
            return;
        }
        if (capsule.text === "") { focusPassword(); return; }
        errorText = "";
        infoText = "";
        _pending = capsule.text;
        backend.createSession(listMode ? currentUser.userName : userCapsule.text.trim());
    }
    function focusPassword() { capsule.focusField(); }
    // Text typed while the focus was elsewhere.
    function typeText(t) { capsule.typeText(t); }

    Connections {
        target: root.backend
        function onPromptRequested(secret, text) {
            if (root._pending !== "") {
                const p = root._pending;
                root._pending = "";
                root.backend.respond(p);
            } else {
                // A further prompt (e.g. a one-time code): ask for it in the field.
                root._promptText = String(text).replace(/[\s:]+$/, "");
                root._promptSecret = secret;
                root._awaitingAnswer = true;
                capsule.clear();
                root.focusPassword();
            }
        }
        function onInfoMessage(text) { root.infoText = text; }
        function onAuthFailed(message) {
            root._pending = "";
            root._awaitingAnswer = false;
            root.infoText = "";
            root.errorText = message;
            capsule.clear();
            root.focusPassword();
            capsule.shake();
        }
        function onAuthSucceeded() {
            root._pending = "";
            root._awaitingAnswer = false;
            root.errorText = "";
            root._succeeded = true;
            startTimer.restart();
        }
        function onErrorOccurred(message) {
            // Also the way back when the session could not be started.
            startTimer.stop();
            if (root.backend.authenticating || root._succeeded) root.backend.cancelSession();
            root._pending = "";
            root._awaitingAnswer = false;
            root._succeeded = false;
            root._starting = false;
            root.errorText = message;
            capsule.clear();
            root.focusPassword();
        }
    }

    // The capsule contracts first, then the scene fades and the session starts.
    Timer {
        id: startTimer
        interval: Theme.reduceMotion ? 1 : 280
        onTriggered: {
            root._starting = true;
            root.backend.startSession(root.currentSession ? root.currentSession.exec : "lugh-session");
        }
    }

    // Preselect the last user and session, and focus the first empty field.
    // Runs again when the backend's lists arrive or change.
    function _reset() {
        const last = backend.lastUser;
        currentIndex = 0;
        for (let i = 0; i < users.length; ++i) if (users[i].userName === last) currentIndex = i;
        sessionIndex = 0;
        for (let j = 0; j < sessions.length; ++j) if (sessions[j].id === backend.lastSession) sessionIndex = j;
        if (listMode) focusPassword();
        else userCapsule.focusField();
    }
    onUsersChanged: Qt.callLater(_reset)
    onSessionsChanged: Qt.callLater(_reset)
    onListModeChanged: Qt.callLater(_reset)
    Component.onCompleted: { _reset(); _ready = true; }

    // Printable keys typed while focus is on a button go to the password field.
    Keys.onPressed: event => {
        if (event.text.length > 0 && event.text.charCodeAt(0) > 32
                && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            capsule.typeText(event.text);
            event.accepted = true;
        }
    }

    // ---- backdrop ------------------------------------------------------------------
    Rectangle { anchors.fill: parent; color: Theme.bg }
    Image {
        id: backdrop
        anchors.fill: parent
        readonly property bool custom: root.backend.wallpaper !== "" && !_customFailed
        property bool _customFailed: false
        source: custom ? root.backend.wallpaper
                       : root._wallDir + "dawn-" + (Theme.dark ? "dark" : "light") + "-blur.jpg"
        // Custom art: decode tiny and let smooth upscaling blur it (no shader).
        sourceSize: custom ? Qt.size(Math.max(1, Math.round(width / 16)), Math.max(1, Math.round(height / 16)))
                           : Qt.size(-1, -1)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durLarge) } }
        onStatusChanged: if (status === Image.Error && custom) _customFailed = true
    }
    // Calms the wallpaper toward the theme background so text on it meets AA.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, Theme.dark ? 0.45 : 0.32)
    }

    // ---- "Starting…" (after sign-in, until greetd ends the greeter) -------------
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.5 - height / 2)
        width: Math.min(parent.width - Theme.space48, 480)
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: root.currentSession ? qsTr("Starting %1…").arg(root.currentSession.name) : qsTr("Starting…")
        font: Theme.typeTitle3
        color: Theme.text
        opacity: root._starting ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation { duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
        }
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    // ---- scene (fades out once signed in) --------------------------------------------
    Item {
        id: scene
        anchors.fill: parent
        opacity: root._starting ? 0 : 1
        visible: opacity > 0
        enabled: !root._starting
        Behavior on opacity {
            NumberAnimation { duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
        }

        // ---- clock + date (the hero, as on the lock screen) ---------------------
        Column {
            id: clockGroup
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.13)
            spacing: Theme.space4

            Text {
                id: clock
                anchors.horizontalCenter: parent.horizontalCenter
                property date now: new Date()
                readonly property int px: Math.round(Math.max(80, Math.min(160, scene.height * 0.135)))
                text: Qt.formatTime(now, "HH:mm")
                font.family: Theme.fontUi
                font.pixelSize: px
                font.weight: 250
                font.features: { "tnum": 1 }
                font.letterSpacing: -px * 0.03
                color: Theme.text
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Time %1").arg(text)
                // Wakes each second, repaints only when the minute changes.
                Timer {
                    interval: 1000
                    running: true
                    repeat: true
                    onTriggered: {
                        const d = new Date();
                        if (d.getMinutes() !== clock.now.getMinutes() || d.getHours() !== clock.now.getHours()) clock.now = d;
                    }
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDate(clock.now, "dddd, d MMMM")
                font.family: Theme.fontUi
                font.pixelSize: Math.round(clock.px * 0.16)
                font.weight: 500
                color: Theme.text
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        // ---- users, name, capsule(s) ----------------------------------------------
        // The password capsule sits where the lock screen's does.
        Column {
            id: authColumn
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.max(clockGroup.y + clockGroup.height + Theme.space16,
                        Math.round(parent.height * 0.62) + 40 + capsule.height - height)
            width: parent.width
            spacing: Theme.space12

            FocusScope {
                id: picker
                width: parent.width
                height: big
                visible: root.listMode
                activeFocusOnTab: root.listMode && root.users.length > 1
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Users")

                readonly property int big: 88
                readonly property int small: 48
                readonly property int gap: Theme.space16
                property int _moving: 0
                readonly property bool gliding: _moving > 0

                Keys.onLeftPressed: root.selectUser(root.currentIndex - 1)
                Keys.onRightPressed: root.selectUser(root.currentIndex + 1)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Home) { root.selectUser(0); event.accepted = true; }
                    else if (event.key === Qt.Key_End) { root.selectUser(root.users.length - 1); event.accepted = true; }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        root.focusPassword(); event.accepted = true;
                    }
                }

                // Zero-width anchor at the middle of the row: a resize moves
                // the avatars with it instead of making them glide.
                Item {
                id: rowCenter
                x: Math.round(picker.width / 2)
                Repeater {
                    model: root.listMode ? root.users : []
                    delegate: Item {
                        id: userItem
                        required property var modelData
                        required property int index
                        readonly property int rel: index - root.currentIndex
                        readonly property bool selected: rel === 0
                        // Center of this avatar, from the middle of the row.
                        readonly property real offset: rel === 0 ? 0
                            : Math.sign(rel) * ((picker.big + picker.small) / 2 + picker.gap
                                                + (Math.abs(rel) - 1) * (picker.small + picker.gap))

                        width: picker.big
                        height: picker.big
                        x: Math.round(offset - width / 2)
                        scale: selected ? 1 : picker.small / picker.big
                        opacity: selected || hover.hovered ? 1 : 0.7
                        visible: rowCenter.x + x + width > 0 && rowCenter.x + x < picker.width

                        Behavior on x {
                            enabled: root._ready && !Theme.reduceMotion
                            SpringAnimation {
                                spring: Theme.liquidSpring; damping: Theme.liquidDamping
                                mass: Theme.liquidMass; epsilon: Theme.springEpsilon
                                onRunningChanged: picker._moving += running ? 1 : -1
                            }
                        }
                        Behavior on scale {
                            enabled: root._ready && !Theme.reduceMotion
                            SpringAnimation {
                                spring: Theme.liquidSpring; damping: Theme.liquidDamping
                                mass: Theme.liquidMass; epsilon: 0.0005
                            }
                        }
                        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durMicro) } }

                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData.realName
                        Accessible.checkable: true
                        Accessible.checked: selected

                        Avatar {
                            id: av
                            anchors.fill: parent
                            size: picker.big
                            source: userItem.modelData.avatar
                            name: userItem.modelData.realName
                        }
                        // Keyboard focus ring on the selected user.
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width + 2 * (Theme.focusRingOffset + Theme.focusRingWidth) + 4
                            height: width
                            radius: width / 2
                            color: "transparent"
                            border.width: Theme.focusRingWidth
                            border.color: Theme.focusRing
                            visible: userItem.selected && picker.activeFocus
                        }
                        HoverHandler { id: hover; cursorShape: userItem.selected ? Qt.ArrowCursor : Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: { root.selectUser(userItem.index); root.focusPassword(); }
                        }
                        Tooltip {
                            text: userItem.modelData.realName
                            visible: hover.hovered && !userItem.selected
                        }
                    }
                }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width - Theme.space48, 480)
                horizontalAlignment: Text.AlignHCenter
                visible: root.listMode
                text: root.currentUser ? root.currentUser.realName : ""
                elide: Text.ElideRight
                font: Theme.typeTitle3
                color: Theme.text
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            // Username mode: a capsule for the name above the password one.
            AuthCapsule {
                id: userCapsule
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !root.listMode
                leadingIcon: "user"
                secret: false
                showSubmit: false
                placeholder: qsTr("Username")
                a11yLabel: qsTr("Username")
                busy: root.busy
                done: root._succeeded
                field.inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                onSubmitted: root.focusPassword()
                onEdited: {
                    root.errorText = "";
                    root._awaitingAnswer = false;
                    if (root.backend.sessionUser !== "") root.backend.cancelSession();
                }
            }

            AuthCapsule {
                id: capsule
                anchors.horizontalCenter: parent.horizontalCenter
                focus: true
                leadingIcon: root.listMode ? "" : "key-round"
                avatarSource: root.currentUser ? root.currentUser.avatar : ""
                avatarName: root.currentUser ? root.currentUser.realName : ""
                secret: root._awaitingAnswer ? root._promptSecret : true
                placeholder: root._awaitingAnswer && root._promptText !== "" ? root._promptText : qsTr("Password")
                a11yLabel: root._awaitingAnswer && root._promptText !== "" ? root._promptText
                         : root.currentUser ? qsTr("Password for %1").arg(root.currentUser.realName) : qsTr("Password")
                submitTooltip: qsTr("Sign in")
                // Some extra prompts take an empty answer ("press Enter").
                allowEmpty: root._awaitingAnswer
                arrowsWhenEmpty: root.listMode
                busy: root.busy
                done: root._succeeded
                errorText: root.errorText
                infoText: root.infoText
                capsLock: root.backend.capsLock
                maxMessageWidth: Math.min(scene.width - Theme.space48, 480)
                onSubmitted: root.submit()
                onHorizontalArrow: direction => root.selectUser(root.currentIndex + direction)
                onEscapePressed: wasEmpty => {
                    root.errorText = "";
                    if (wasEmpty && root.backend.sessionUser !== "" && !root.busy) {
                        root.backend.cancelSession();
                        root._awaitingAnswer = false;
                        root.infoText = "";
                    }
                }
            }
        }

        // ---- bottom left: this computer ---------------------------------------------
        Island {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Theme.space16
            interactive: false
            animateWidth: false
            text: root.backend.hostName

            Image {
                anchors.verticalCenter: parent.verticalCenter
                source: root._logoDir + (Theme.dark ? "lugh-lockup-dark.svg" : "lugh-lockup.svg")
                height: 16
                width: Math.round(height * 378.18 / 136)
                sourceSize: Qt.size(Math.ceil(width * Screen.devicePixelRatio), Math.ceil(height * Screen.devicePixelRatio))
                smooth: true
                Accessible.role: Accessible.Graphic
                Accessible.name: "Lugh"
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: hostText.visible
                width: 1; height: 14
                color: Theme.glassBorder
            }
            Text {
                id: hostText
                anchors.verticalCenter: parent.verticalCenter
                visible: text !== ""
                width: Math.min(implicitWidth, Math.max(80, Math.min(240, scene.width * 0.2)))
                elide: Text.ElideRight
                text: root.backend.hostName
                font: Theme.typeLabel
                color: Theme.textMuted
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Computer name: %1").arg(text)
            }
        }

        // ---- bottom right: session, keyboard + accessibility, power ----------------
        Row {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Theme.space16
            spacing: Theme.space8

            Island {
                id: sessionIsland
                visible: root.sessions.length > 1
                animateWidth: false
                focusPolicy: Qt.TabFocus
                active: sessionMenu.visible
                text: qsTr("Session: %1. Change session").arg(root.currentSession ? root.currentSession.name : "")
                onClicked: sessionMenu.open()

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "monitor"
                    size: 16
                    color: Theme.text
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, 160)
                    elide: Text.ElideRight
                    text: root.currentSession ? root.currentSession.name : ""
                    font: Theme.typeLabel
                    color: Theme.text
                    Accessible.ignored: true
                }
                Menu {
                    id: sessionMenu
                    x: -sessionIsland.leftPadding
                    y: -height - Theme.space8 - 2
                    transformOrigin: T.Popup.BottomLeft
                    onClosed: root.focusPassword()
                    Repeater {
                        model: root.sessions
                        delegate: MenuItem {
                            required property var modelData
                            required property int index
                            text: modelData.name
                            checkable: true
                            checked: index === root.sessionIndex
                            onTriggered: root.sessionIndex = index
                        }
                    }
                }
                Tooltip {
                    text: qsTr("Session")
                    visible: (sessionIsland.hovered || sessionIsland.visualFocus) && !sessionMenu.visible
                }
            }

            Island {
                interactive: false
                animateWidth: false
                padding: Theme.space2
                spacing: 0
                text: qsTr("Keyboard and accessibility")

                LabelButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: (root.backend.layouts || []).length > 1
                    text: String(root.backend.layout).toUpperCase()
                    tooltip: qsTr("Keyboard layout %1. Switch layout").arg(text)
                    onClicked: { root.backend.nextLayout(); root.focusPassword(); }
                }
                IconButton {
                    id: a11yButton
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "person-standing"
                    iconSize: 16
                    tooltip: qsTr("Accessibility")
                    focusPolicy: Qt.TabFocus
                    checked: a11yMenu.visible
                    onClicked: a11yMenu.open()

                    Menu {
                        id: a11yMenu
                        x: a11yButton.width - width
                        y: -height - Theme.space8 - 2
                        transformOrigin: T.Popup.BottomRight
                        MenuItem {
                            text: qsTr("Screen reader"); checkable: true
                            checked: root.backend.screenReader
                            onTriggered: root.backend.screenReader = !root.backend.screenReader
                        }
                        MenuItem {
                            text: qsTr("On-screen keyboard"); checkable: true
                            checked: root.backend.onScreenKeyboard
                            onTriggered: root.backend.onScreenKeyboard = !root.backend.onScreenKeyboard
                        }
                        MenuItem {
                            text: qsTr("Large text"); checkable: true
                            checked: root.backend.largeText
                            onTriggered: root.backend.largeText = !root.backend.largeText
                        }
                        MenuItem {
                            text: qsTr("High contrast"); checkable: true
                            checked: root.backend.highContrast
                            onTriggered: root.backend.highContrast = !root.backend.highContrast
                        }
                    }
                }
            }

            Island {
                interactive: false
                animateWidth: false
                padding: Theme.space2
                spacing: 0
                visible: root.backend.canReboot || root.backend.canPowerOff
                text: qsTr("Power")

                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.backend.canReboot
                    iconName: "rotate-ccw"
                    iconSize: 16
                    tooltip: qsTr("Restart")
                    focusPolicy: Qt.TabFocus
                    onClicked: confirm.ask("reboot")
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.backend.canPowerOff
                    iconName: "power"
                    iconSize: 16
                    tooltip: qsTr("Shut down")
                    focusPolicy: Qt.TabFocus
                    onClicked: confirm.ask("poweroff")
                }
            }
        }
    }

    Dialog {
        id: confirm
        property string action: ""
        function ask(a) { action = a; open(); }
        title: action === "reboot" ? qsTr("Restart this computer?") : qsTr("Shut down this computer?")
        text: qsTr("Anyone signed in on this computer will lose unsaved work.")
        primaryText: action === "reboot" ? qsTr("Restart") : qsTr("Shut down")
        onAccepted: action === "reboot" ? root.backend.reboot() : root.backend.powerOff()
        onClosed: root.focusPassword()
    }

    // Short text button inside an island (the keyboard layout).
    component LabelButton: T.Button {
        id: lb
        property string tooltip
        implicitWidth: Math.max(Theme.hitTarget, lbText.implicitWidth + Theme.space8 * 2)
        implicitHeight: Theme.hitTarget
        padding: 0
        focusPolicy: Qt.TabFocus
        hoverEnabled: true
        Accessible.role: Accessible.Button
        Accessible.name: tooltip

        background: Rectangle {
            radius: height / 2
            color: lb.down ? Theme.pressedOverlay : lb.hovered ? Theme.hoverOverlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.durMicro } }
            FocusRing { show: lb.visualFocus }
        }
        contentItem: Item {
            Text {
                id: lbText
                anchors.centerIn: parent
                text: lb.text
                font: Theme.typeLabel
                color: Theme.text
            }
        }
        Tooltip {
            text: lb.tooltip
            visible: lb.hovered || lb.visualFocus
        }
    }
}

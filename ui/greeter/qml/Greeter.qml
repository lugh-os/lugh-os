// lugh-greeter UI (shell spec §Greeter, phase-1 §5). Same visual language as
// the lock screen: blurred wallpaper, light clock, avatar + password field,
// a glass status pill at the bottom.
//
//   Greeter { anchors.fill: parent; backend: greetdBackend }
//
// Works on its own too (its own MockGreetd), so it can be loaded directly:
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/greeter/qml/Greeter.qml out.png 1440 900
//
// Users: a carousel of avatars, the selected one centered, larger and named
// (Left/Right, Home/End, click). More than `maxListedUsers` accounts, none, or
// backend.hideUsers → a username field instead. The session picker shows only
// when more than one session is installed.
//
// Auth (greetd): submit → createSession(user) → promptRequested → respond(pw)
// → authSucceeded → content fades out → startSession(exec). authFailed →
// the field shakes (none under reduce motion), clears, refocuses, and the
// message shows inline with an icon.
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
    readonly property bool busy: backend.authenticating && !_succeeded
    property bool _succeeded: false
    property string _pending: ""          // password waiting for the prompt
    property bool _awaitingAnswer: false  // a prompt arrived with nothing pending

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
        if (!listMode || i < 0 || i >= users.length || i === currentIndex || busy) return;
        if (backend.sessionUser !== "") backend.cancelSession();
        currentIndex = i;
        errorText = "";
        infoText = "";
        passwordField.clear();
    }
    function submit() {
        if (busy || _succeeded) return;
        if (!listMode && usernameField.text.trim() === "") { usernameField.forceActiveFocus(Qt.OtherFocusReason); return; }
        if (passwordField.text === "") { focusPassword(); return; }
        errorText = "";
        infoText = "";
        if (_awaitingAnswer && backend.sessionUser !== "") {
            _awaitingAnswer = false;
            backend.respond(passwordField.text);
            return;
        }
        _pending = passwordField.text;
        backend.createSession(listMode ? currentUser.userName : usernameField.text.trim());
    }
    function focusPassword() { passwordField.forceActiveFocus(Qt.OtherFocusReason); }

    Connections {
        target: root.backend
        function onPromptRequested(secret, text) {
            if (root._pending !== "") {
                const p = root._pending;
                root._pending = "";
                root.backend.respond(p);
            } else {
                // A further prompt (e.g. a one-time code): ask for it in the field.
                root._awaitingAnswer = true;
                root.infoText = text;
                passwordField.clear();
                root.focusPassword();
            }
        }
        function onInfoMessage(text) { root.infoText = text; }
        function onAuthFailed(message) {
            root._pending = "";
            root._awaitingAnswer = false;
            root.errorText = message;
            passwordField.clear();
            root.focusPassword();
            if (!Theme.reduceMotion) shake.restart();
        }
        function onAuthSucceeded() {
            root._succeeded = true;
            leave.restart();
        }
        function onErrorOccurred(message) { root.errorText = message; }
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
        else usernameField.forceActiveFocus(Qt.OtherFocusReason);
    }
    onUsersChanged: Qt.callLater(_reset)
    onSessionsChanged: Qt.callLater(_reset)
    onListModeChanged: Qt.callLater(_reset)
    Component.onCompleted: _reset()

    // Printable keys typed while focus is on a button go to the password field.
    Keys.onPressed: event => {
        if (event.text.length > 0 && event.text.charCodeAt(0) > 32
                && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            root.focusPassword();
            if (!passwordField.readOnly) passwordField.insert(passwordField.cursorPosition, event.text);
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
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, Theme.dark ? 0.45 : 0.32)
    }

    // ---- content (fades out on success) ----------------------------------------------
    Item {
        id: content
        anchors.fill: parent

        // Clock (smaller than the lock screen's).
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.08)
            spacing: Theme.space2

            Text {
                id: clock
                anchors.horizontalCenter: parent.horizontalCenter
                property date now: new Date()
                text: Qt.formatTime(now, "HH:mm")
                font.family: Theme.fontUi
                font.pixelSize: 64
                font.weight: 300
                font.features: { "tnum": 1 }
                font.letterSpacing: -1
                color: Theme.text
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Time %1").arg(text)
                Timer {
                    interval: 1000 - (new Date()).getMilliseconds()
                    running: true
                    repeat: true
                    onTriggered: { clock.now = new Date(); interval = 1000; }
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDate(clock.now, "dddd, d MMMM")
                font.family: Theme.fontUi
                font.pixelSize: 16
                font.weight: 500
                color: Theme.text
            }
        }

        // ---- users ----------------------------------------------------------------
        FocusScope {
            id: picker
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.5 - 124)
            width: parent.width
            height: 112
            visible: root.listMode
            activeFocusOnTab: root.listMode && root.users.length > 1
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Users")

            readonly property bool keyboardFocus: activeFocus
            readonly property int bigSize: 96
            readonly property int smallSize: 56
            readonly property int gap: Theme.space24

            Keys.onLeftPressed: root.selectUser(root.currentIndex - 1)
            Keys.onRightPressed: root.selectUser(root.currentIndex + 1)
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Home) { root.selectUser(0); event.accepted = true; }
                else if (event.key === Qt.Key_End) { root.selectUser(root.users.length - 1); event.accepted = true; }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    root.focusPassword(); event.accepted = true;
                }
            }

            // The row slides so the selected user sits in the middle.
            Row {
                id: userRow
                spacing: picker.gap
                height: parent.height
                x: Math.round(picker.width / 2 - root.currentIndex * (picker.smallSize + picker.gap) - picker.bigSize / 2)
                Behavior on x {
                    enabled: !Theme.reduceMotion
                    NumberAnimation { duration: Theme.durMedium; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                }

                Repeater {
                    model: root.listMode ? root.users : []
                    delegate: Item {
                        id: userItem
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === root.currentIndex
                        width: selected ? picker.bigSize : picker.smallSize
                        height: userRow.height
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData.realName
                        Accessible.checkable: true
                        Accessible.checked: selected

                        Avatar {
                            id: av
                            anchors.centerIn: parent
                            size: userItem.width
                            source: userItem.modelData.avatar
                            name: userItem.modelData.realName
                            opacity: userItem.selected || hover.hovered ? 1 : 0.72
                            Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
                        }
                        // Keyboard focus ring on the selected user.
                        Rectangle {
                            anchors.centerIn: av
                            width: av.width + 2 * (Theme.focusRingOffset + Theme.focusRingWidth) + 4
                            height: width
                            radius: width / 2
                            color: "transparent"
                            border.width: Theme.focusRingWidth
                            border.color: Theme.focusRing
                            visible: userItem.selected && picker.keyboardFocus
                        }
                        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
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

        // ---- form ---------------------------------------------------------------
        Column {
            id: form
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.listMode ? picker.y + picker.height + Theme.space12 : Math.round(parent.height * 0.5 - 124)
            width: 360
            spacing: Theme.space12

            // Username mode: a generic avatar instead of the carousel.
            Avatar {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !root.listMode
                size: 96
                name: ""
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: root.listMode
                text: root.currentUser ? root.currentUser.realName : ""
                elide: Text.ElideRight
                font: Theme.typeTitle2
                color: Theme.text
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            Item { width: 1; height: Theme.space4 }

            Item {
                id: fields
                anchors.horizontalCenter: parent.horizontalCenter
                width: fieldColumn.width
                height: fieldColumn.height
                transform: Translate { id: shakeShift }

                Column {
                    id: fieldColumn
                    spacing: Theme.space8

                    Row {
                        spacing: Theme.space8
                        visible: !root.listMode
                        Item { width: submitButton.width; height: 1 }
                        TextField {
                            id: usernameField
                            width: 264
                            placeholderText: qsTr("Username")
                            iconName: "user"
                            readOnly: root.busy
                            inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                            Accessible.name: qsTr("Username")
                            onAccepted: root.focusPassword()
                            onTextEdited: { root.errorText = ""; if (root.backend.sessionUser !== "") root.backend.cancelSession(); }
                        }
                    }

                    Row {
                        spacing: Theme.space8
                        Item { width: submitButton.width; height: 1 }
                        TextField {
                            id: passwordField
                            width: 264
                            password: true
                            placeholderText: root._awaitingAnswer && root.infoText !== "" ? root.infoText : qsTr("Password")
                            readOnly: root.busy || root._succeeded
                            readonly property string a11yLabel: root.listMode && root.currentUser
                                ? qsTr("Password for %1").arg(root.currentUser.realName) : qsTr("Password")
                            // Qt blanks Accessible.name while passwordEdit is set, so
                            // the label also goes in the description.
                            Accessible.name: a11yLabel
                            Accessible.description: [a11yLabel, root.errorText,
                                                     root.backend.capsLock ? qsTr("Caps Lock is on") : ""]
                                                    .filter(s => s !== "").join(". ")
                            onAccepted: root.submit()
                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Escape) {
                                    if (passwordField.text !== "") passwordField.clear();
                                    else if (root.backend.sessionUser !== "" && !root.busy) root.backend.cancelSession();
                                    root.errorText = "";
                                    event.accepted = true;
                                } else if (root.listMode && passwordField.text === ""
                                           && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
                                    root.selectUser(root.currentIndex + (event.key === Qt.Key_Left ? -1 : 1));
                                    event.accepted = true;
                                }
                            }

                            // Spinner over the trailing area while authenticating.
                            Rectangle {
                                x: passwordField.width - width - Theme.space4
                                y: (36 - height) / 2
                                width: 28
                                height: 28
                                radius: Theme.radiusSm
                                color: Theme.surface2
                                visible: root.busy || root._succeeded
                                Spinner { anchors.centerIn: parent; size: 16; running: parent.visible }
                                MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
                            }
                        }
                        IconButton {
                            id: submitButton
                            size: 36
                            iconSize: 18
                            variant: "accent"
                            iconName: "arrow-right"
                            tooltip: qsTr("Sign in")
                            focusPolicy: Qt.TabFocus
                            enabled: passwordField.length > 0 && !root.busy && !root._succeeded
                            disabledReason: root.busy ? qsTr("Checking your password") : qsTr("Type your password first")
                            onClicked: root.submit()
                        }
                    }
                }
            }

            // Messages: fixed-height slot so nothing below jumps.
            Item {
                width: parent.width
                height: 64
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.space8
                    Message {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: root.errorText !== "" && !root.busy
                        iconName: "circle-alert"
                        iconColor: Theme.danger
                        textColor: Theme.danger
                        text: root.errorText
                        Accessible.role: Accessible.AlertMessage
                    }
                    Message {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: root.infoText !== "" && root.errorText === "" && !root._awaitingAnswer
                        iconName: "info"
                        iconColor: Theme.info
                        textColor: Theme.text
                        text: root.infoText
                    }
                    Message {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: root.backend.capsLock
                        iconName: "arrow-big-up"
                        iconColor: Theme.warning
                        textColor: Theme.text
                        text: qsTr("Caps Lock is on")
                    }
                }
            }
        }

        // ---- bottom bar ---------------------------------------------------------
        Row {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Theme.space24
            height: 44
            spacing: Theme.space12

            Image {
                anchors.verticalCenter: parent.verticalCenter
                source: root._logoDir + (Theme.dark ? "lugh-lockup-dark.svg" : "lugh-lockup.svg")
                height: 24
                width: Math.round(height * 378.18 / 136)
                sourceSize: Qt.size(Math.ceil(width * Screen.devicePixelRatio), Math.ceil(height * Screen.devicePixelRatio))
                smooth: true
                Accessible.role: Accessible.Graphic
                Accessible.name: "Lugh"
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1; height: 16
                color: Theme.border
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.backend.hostName
                font: Theme.typeBodyStrong
                color: Theme.textMuted
            }
        }

        GlassPanel {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Theme.space24
            radius: height / 2
            elevation: "none"
            width: bottomRow.implicitWidth + Theme.space8 * 2
            height: 44

            Row {
                id: bottomRow
                anchors.verticalCenter: parent.verticalCenter
                x: Theme.space8
                spacing: Theme.space4

                Button {
                    id: sessionButton
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.sessions.length > 1
                    variant: "ghost"
                    size: "sm"
                    iconName: "monitor"
                    text: root.currentSession ? root.currentSession.name : ""
                    focusPolicy: Qt.TabFocus
                    Accessible.name: qsTr("Session: %1. Change session").arg(text)
                    onClicked: sessionMenu.open()

                    Menu {
                        id: sessionMenu
                        y: -height - Theme.space8
                        transformOrigin: T.Popup.Bottom
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
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: sessionButton.visible
                    width: 1; height: 16
                    color: Theme.glassBorder
                }
                Button {
                    anchors.verticalCenter: parent.verticalCenter
                    variant: "ghost"
                    size: "sm"
                    iconName: "keyboard"
                    text: root.backend.layout.toUpperCase()
                    focusPolicy: Qt.TabFocus
                    Accessible.name: qsTr("Keyboard layout %1. Switch layout").arg(text)
                    onClicked: root.backend.nextLayout()
                }
                IconButton {
                    id: a11yButton
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "person-standing"
                    tooltip: qsTr("Accessibility")
                    focusPolicy: Qt.TabFocus
                    checked: a11yMenu.visible
                    onClicked: a11yMenu.open()

                    Menu {
                        id: a11yMenu
                        x: a11yButton.width - width
                        y: -height - Theme.space8
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
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.backend.canReboot
                    iconName: "rotate-ccw"
                    tooltip: qsTr("Restart")
                    focusPolicy: Qt.TabFocus
                    onClicked: confirm.ask("reboot")
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.backend.canPowerOff
                    iconName: "power"
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

    // ---- animations ------------------------------------------------------------------
    SequentialAnimation {
        id: leave
        NumberAnimation {
            target: content; property: "opacity"; to: 0
            duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        ScriptAction { script: root.backend.startSession(root.currentSession ? root.currentSession.exec : "lugh-session") }
    }

    SequentialAnimation {
        id: shake
        NumberAnimation { target: shakeShift; property: "x"; to: -10; duration: 45; easing.type: Easing.OutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: 10; duration: 70; easing.type: Easing.InOutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: -7; duration: 65; easing.type: Easing.InOutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: 7; duration: 60; easing.type: Easing.InOutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: -3; duration: 55; easing.type: Easing.InOutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: 0; duration: 50; easing.type: Easing.OutQuad }
    }

    // Inline message on a small solid pill (AA on any wallpaper), with an icon.
    component Message: Rectangle {
        id: msg
        property string iconName
        property color iconColor
        property color textColor
        property string text
        width: msgRow.implicitWidth + Theme.space12 * 2
        height: 28
        radius: height / 2
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.88)
        border.width: 1
        border.color: Theme.glassBorder
        Accessible.name: text

        Row {
            id: msgRow
            anchors.centerIn: parent
            spacing: Theme.space8
            Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: msg.iconName
                size: 14
                color: msg.iconColor
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: msg.text
                font: Theme.typeBodyStrong
                color: msg.textColor
                Accessible.ignored: true
            }
        }
    }
}

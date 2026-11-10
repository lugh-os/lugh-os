// Lock screen (shell spec §Lock screen, phase-1 §4): blurred wallpaper, a
// large clock and date, the user and a password field, and a small status
// row. The frame anchors it to the whole screen and maps it while `shown`.
//
//   LockScreen { anchors.fill: parent }      // shown while Services.session.locked
//
// Behaviour
//   - The field is focused as soon as the screen locks; typing anywhere jumps
//     into it. Enter submits Services.session.unlock(text), Esc clears it.
//   - authenticating: spinner in the field's trailing area, input read-only.
//   - authError: the field shakes (3 short oscillations, none under reduce
//     motion), is cleared and refocused, and the error shows inline with an
//     icon. Caps Lock shows a warning with an icon.
//   - Idle: 10 s without input hides everything but the clock (fade); any key
//     or pointer movement brings it back. The half-typed password is cleared.
//   - Unlock: the whole surface fades and scales 1.0 → 1.04 (durLarge); under
//     reduce motion it only fades. `shown` stays true until that finishes.
//
// Privacy (spec §Security & privacy): only the notification COUNT is shown,
// never content; media controls show no artwork.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: root

    // Mapped by the frame while true (stays true during the unlock animation).
    readonly property bool shown: _shown
    // Exclusive keyboard while locked.
    readonly property bool wantsKeyboard: Services.session.locked
    // Idle: only the clock is visible. Writable so demos can force it.
    property bool idle: false
    // Seconds of no input before idling.
    property int idleTimeout: 10

    readonly property var session: Services.session
    // Accessible label of the password field.
    readonly property string a11yLabel: qsTr("Password for %1").arg(session.realName)
    readonly property bool _busy: session.authenticating
    property bool _shown: false
    property bool _leaving: false

    focus: true
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Lock screen")

    // ---- lifecycle -----------------------------------------------------------
    function _enter() {
        leaveAnim.stop();
        _leaving = false;
        surface.opacity = 1;
        surface.scale = 1;
        idle = false;
        field.clear();
        _shown = true;
        enterAnim.restart();
        _focusField();
        idleTimer.restart();
    }
    function _leave() {
        if (!_shown) return;
        _leaving = true;
        field.clear();
        leaveAnim.restart();
    }
    function _focusField() {
        field.forceActiveFocus(Qt.OtherFocusReason);
    }
    // Any user input: wake from idle and restart the idle countdown.
    function activity() {
        if (!_shown || _leaving) return;
        idle = false;
        idleTimer.restart();
    }
    function submit() {
        if (_busy || field.text.length === 0) return;
        activity();
        session.unlock(field.text);
    }

    Connections {
        target: root.session
        function onLockedChanged() {
            if (root.session.locked) root._enter();
            else root._leave();
        }
        function onAuthErrorChanged() {
            if (root.session.authError === "") return;
            field.clear();
            root.activity();
            root._focusField();
            if (!Theme.reduceMotion) shake.restart();
        }
    }
    Component.onCompleted: if (session.locked && !_shown) _enter()

    onIdleChanged: {
        if (idle) {
            field.clear();
            field._revealed = false;
        } else if (_shown) {
            _focusField();
        }
    }

    Timer {
        id: idleTimer
        interval: root.idleTimeout * 1000
        running: root._shown && !root._leaving && !root.idle && !root._busy
        onTriggered: root.idle = true
    }

    // Typing while focus is elsewhere (e.g. a media button) goes to the field.
    Keys.onPressed: event => {
        root.activity();
        if (event.key === Qt.Key_Escape) {
            field.clear();
            root._focusField();
            event.accepted = true;
        } else if (event.text.length > 0 && event.text.charCodeAt(0) >= 32
                   && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            root._focusField();
            if (!field.readOnly) field.insert(field.cursorPosition, event.text);
            event.accepted = true;
        }
    }

    // Real pointer movement or a click anywhere wakes it (handlers don't block
    // input). Qt also sends synthetic hover events when items move under a
    // still cursor, so only a move of a few pixels counts.
    HoverHandler {
        property point _last: Qt.point(-1, -1)
        onPointChanged: {
            const p = point.scenePosition;
            if (_last.x < 0) { _last = p; return; }
            if (Math.abs(p.x - _last.x) + Math.abs(p.y - _last.y) < 4) return;
            _last = p;
            root.activity();
        }
    }
    TapHandler {
        onTapped: { root.activity(); root._focusField(); }
    }

    // ---- surface ---------------------------------------------------------------
    Item {
        id: surface
        anchors.fill: parent
        transformOrigin: Item.Center

        // Opaque base, so nothing under the lock surface ever shows through.
        Rectangle { anchors.fill: parent; color: Theme.bg }

        Wallpaper {
            anchors.fill: parent
            blurred: true
        }
        // Calms the wallpaper toward the theme background so text on it meets
        // AA: a light wash in the light theme, a darkening one in the dark.
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, Theme.dark ? 0.45 : 0.32)
        }

        // ---- clock + date (upper center; drifts to the middle when idle) ----
        Column {
            id: clockGroup
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.14)
            spacing: Theme.space4

            transform: Translate {
                y: root.idle && !Theme.reduceMotion
                   ? Math.max(0, Math.round((surface.height - clockGroup.height) / 2 - clockGroup.y - surface.height * 0.04))
                   : 0
                Behavior on y {
                    NumberAnimation { duration: Theme.durLarge; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                }
            }

            Text {
                id: clockText
                anchors.horizontalCenter: parent.horizontalCenter
                text: Services.clock.time
                font.family: Theme.fontUi
                font.pixelSize: 104
                font.weight: 300
                font.features: { "tnum": 1 }
                font.letterSpacing: -2
                color: Theme.text
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Time %1").arg(text)
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Services.clock.longDate
                font.family: Theme.fontUi
                font.pixelSize: 20
                font.weight: 500
                color: Theme.text
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        // ---- the user and the password field (lower center) -------------
        Item {
            id: card
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.60 - avatar.height)
            width: 360
            height: cardColumn.height
            opacity: root.idle ? 0 : 1
            visible: opacity > 0
            enabled: !root.idle

            Behavior on opacity {
                NumberAnimation { duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
            }

            Column {
                id: cardColumn
                width: parent.width
                spacing: Theme.space12

                Avatar {
                    id: avatar
                    anchors.horizontalCenter: parent.horizontalCenter
                    size: 88
                    source: root.session.avatar
                    name: root.session.realName
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.session.realName
                    elide: Text.ElideRight
                    font: Theme.typeTitle2
                    color: Theme.text
                    Accessible.role: Accessible.Heading
                    Accessible.name: text
                }

                Item { width: 1; height: Theme.space4 }

                // Field row: a spacer as wide as the submit button keeps the
                // field itself centered under the avatar.
                Row {
                    id: fieldRow
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.space8

                    transform: Translate { id: shakeShift }

                    Item { width: submitButton.width; height: 1 }

                    TextField {
                        id: field
                        width: 264
                        password: true
                        placeholderText: qsTr("Password")
                        readOnly: root._busy
                        focus: true
                        // Qt blanks Accessible.name while passwordEdit is set, so
                        // the label also goes in the description (read by Orca).
                        Accessible.name: root.a11yLabel
                        Accessible.description: [root.a11yLabel,
                                                 root.session.authError,
                                                 capsRow.visible ? qsTr("Caps Lock is on") : ""]
                                                .filter(s => s !== "").join(". ")

                        onAccepted: root.submit()
                        onTextEdited: root.activity()
                        Keys.onPressed: event => {
                            root.activity();
                            if (event.key === Qt.Key_Escape) {
                                field.clear();
                                event.accepted = true;
                            }
                        }

                        // Spinner over the trailing area while authenticating;
                        // it also blocks the reveal button.
                        Rectangle {
                            x: field.width - width - Theme.space4
                            y: (36 - height) / 2
                            width: 28
                            height: 28
                            radius: Theme.radiusSm
                            color: Theme.surface2
                            visible: root._busy
                            Spinner {
                                anchors.centerIn: parent
                                size: 16
                                running: parent.visible
                            }
                            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
                        }
                    }

                    IconButton {
                        id: submitButton
                        size: 36
                        iconSize: 18
                        variant: "accent"
                        iconName: "arrow-right"
                        tooltip: qsTr("Unlock")
                        enabled: field.length > 0 && !root._busy
                        disabledReason: root._busy ? qsTr("Checking your password") : qsTr("Type your password first")
                        focusPolicy: Qt.TabFocus
                        onClicked: root.submit()
                    }
                }

                // Messages: fixed-height slot so the layout never jumps.
                Item {
                    width: parent.width
                    height: 64

                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.space8

                        Message {
                            id: errorRow
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: root.session.authError !== "" && !root._busy
                            iconName: "circle-alert"
                            iconColor: Theme.danger
                            textColor: Theme.danger
                            text: root.session.authError
                            Accessible.role: Accessible.AlertMessage
                        }
                        Message {
                            id: capsRow
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: Services.keyboard.capsLock
                            iconName: "arrow-big-up"
                            iconColor: Theme.warning
                            textColor: Theme.text
                            text: qsTr("Caps Lock is on")
                        }
                    }
                }
            }
        }

        // ---- bottom: media (left), status (right) ------------------------
        GlassPanel {
            id: mediaPill
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Theme.space24
            radius: height / 2
            elevation: "none"
            width: mediaRow.implicitWidth + Theme.space8 * 2 + Theme.space8
            height: 44
            visible: Services.media.hasPlayer && opacity > 0
            opacity: root.idle ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durLarge) } }

            Row {
                id: mediaRow
                anchors.verticalCenter: parent.verticalCenter
                x: Theme.space16
                spacing: Theme.space4

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "music-2"
                    size: 16
                    color: Theme.textMuted
                }
                Item { width: Theme.space4; height: 1 }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, 260)
                    elide: Text.ElideRight
                    text: Services.media.artist !== ""
                          ? qsTr("%1 · %2").arg(Services.media.title).arg(Services.media.artist)
                          : Services.media.title
                    font: Theme.typeBodyStrong
                    color: Theme.text
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Now playing: %1").arg(text)
                }
                Item { width: Theme.space8; height: 1 }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "skip-back"; iconSize: 16
                    tooltip: qsTr("Previous track")
                    focusPolicy: Qt.TabFocus
                    onClicked: Services.media.previous()
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: Services.media.playing ? "pause" : "play"; iconSize: 16
                    tooltip: Services.media.playing ? qsTr("Pause") : qsTr("Play")
                    focusPolicy: Qt.TabFocus
                    onClicked: Services.media.playPause()
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "skip-forward"; iconSize: 16
                    tooltip: qsTr("Next track")
                    focusPolicy: Qt.TabFocus
                    onClicked: Services.media.next()
                }
            }
        }

        GlassPanel {
            id: statusPill
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Theme.space24
            radius: height / 2
            elevation: "none"
            width: statusRow.implicitWidth + Theme.space16 * 2
            height: 44
            opacity: root.idle ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durLarge) } }

            Row {
                id: statusRow
                anchors.verticalCenter: parent.verticalCenter
                x: Theme.space16
                spacing: Theme.space16

                StatusItem {
                    visible: Services.notifications.count > 0
                    iconName: "bell"
                    text: Services.notifications.count === 1 ? qsTr("1 notification")
                          : qsTr("%1 notifications").arg(Services.notifications.count)
                }
                Button {
                    anchors.verticalCenter: parent.verticalCenter
                    variant: "ghost"
                    size: "sm"
                    iconName: "keyboard"
                    text: Services.keyboard.current.toUpperCase()
                    focusPolicy: Qt.TabFocus
                    Accessible.name: qsTr("Keyboard layout %1. Switch layout").arg(text)
                    onClicked: Services.keyboard.next()
                }
                StatusItem {
                    visible: Services.power.hasBattery
                    iconName: {
                        const p = Services.power;
                        if (p.charging) return "battery-charging";
                        if (p.batteryPercent >= 85) return "battery-full";
                        if (p.batteryPercent >= 40) return "battery-medium";
                        if (p.batteryPercent >= 15) return "battery-low";
                        return "battery-warning";
                    }
                    iconColor: !Services.power.charging && Services.power.batteryPercent < 15 ? Theme.danger : Theme.text
                    text: Services.power.batteryPercent + "%"
                    tnum: true
                    Accessible.name: Services.power.charging
                                     ? qsTr("Battery %1%, charging").arg(Services.power.batteryPercent)
                                     : qsTr("Battery %1%").arg(Services.power.batteryPercent)
                }
            }
        }
    }

    // ---- animations ------------------------------------------------------------
    // Foreground settles in when the screen locks; the opaque base is drawn
    // at once so nothing behind ever shows.
    ParallelAnimation {
        id: enterAnim
        NumberAnimation {
            target: clockGroup; property: "opacity"; from: 0; to: 1
            duration: Theme.dur(Theme.durMedium); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: cardColumn; property: "opacity"; from: 0; to: 1
            duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }

    ParallelAnimation {
        id: leaveAnim
        NumberAnimation {
            target: surface; property: "opacity"; to: 0
            duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: surface; property: "scale"; to: Theme.reduceMotion ? 1 : 1.04
            duration: Theme.durLarge; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        onFinished: {
            root._leaving = false;
            root._shown = false;
            root.idle = false;
            surface.opacity = 1;
            surface.scale = 1;
        }
    }

    // Three quick oscillations, decaying.
    SequentialAnimation {
        id: shake
        NumberAnimation { target: shakeShift; property: "x"; to: -10; duration: 45; easing.type: Easing.OutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: 10; duration: 70; easing.type: Easing.InOutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: -7; duration: 65; easing.type: Easing.InOutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: 7; duration: 60; easing.type: Easing.InOutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: -3; duration: 55; easing.type: Easing.InOutQuad }
        NumberAnimation { target: shakeShift; property: "x"; to: 0; duration: 50; easing.type: Easing.OutQuad }
    }

    // ---- local pieces ----------------------------------------------------------
    // Inline message on a small solid pill (keeps danger/warning text AA on
    // any wallpaper), always with an icon.
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

    component StatusItem: Row {
        id: si
        property string iconName
        property color iconColor: Theme.text
        property string text
        property bool tnum: false
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        spacing: Theme.space8
        Accessible.role: Accessible.StaticText
        Accessible.name: text

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: si.iconName
            size: 16
            color: si.iconColor
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: si.text
            font: si.tnum ? Theme.typeBodyTnum : Theme.typeBodyStrong
            color: Theme.text
            Accessible.ignored: true
        }
    }
}

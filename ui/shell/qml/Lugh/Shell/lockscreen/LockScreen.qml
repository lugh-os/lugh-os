// Lock screen in the liquid language (docs/design/lugh-mode.md, ADR-029): the
// blurred wallpaper, the clock as the hero, the password field in a floating
// glass capsule, and small glass capsules in the bottom corners. The frame
// anchors it to the whole screen (every screen) and maps it while `shown`.
//
//   LockScreen { anchors.fill: parent }      // shown while Services.session.locked
//
// Behaviour
//   - The field is focused as soon as the screen locks; typing anywhere jumps
//     into it. Enter submits Services.session.unlock(text), Esc clears it.
//   - Started already locked (the shell restarted while locked): complete on
//     the first frame, no entrance animation, field focused.
//   - authenticating (0.3–2 s with PAM): spinner in the submit button, field
//     read-only. The capsule squishes on submit.
//   - authError: the capsule shakes (not under reduce motion), the field is
//     cleared and refocused, and the error glides out in a small capsule under
//     it, verbatim ("Too many attempts. Try again in 8 s."). The field stays
//     usable. Caps Lock shows the same way.
//   - Idle: `idleTimeout` s without input hides everything but the clock; any
//     key or pointer movement brings it back. A half-typed password is cleared.
//   - Lock: the surface fades in over the desktop (durSmall), the clock
//     fades in and the capsule rises into place (durLarge, eased); under
//     reduce motion everything only fades.
//   - Unlock: the scene lifts and fades (durLarge); under reduce motion it
//     only fades. `shown` stays true until that finishes, and the surface
//     stays transparent after it (reset on the next lock), so no frame of
//     the lock screen shows again before the frame unmaps it.
//   - Resize-safe: the layout follows the screen live and no Behavior
//     animates while the size changes.
//   - While shown it swallows every pointer and key event (no click-through,
//     no shortcut leaks to items behind it).
//
// Privacy (spec §Security & privacy): only the notification COUNT is shown,
// never content; media shows the title and controls, no artwork.
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
    // True while the entrance, the unlock or the capsule moves.
    readonly property bool animating: enterAnim.running || leaveAnim.running || capsule.animating

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
    function _enter(animate) {
        leaveAnim.stop();
        enterAnim.stop();
        _leaving = false;
        // Start values first, so the first mapped frame is already the
        // first frame of the entrance (never the finished scene, then a jump).
        const wasShown = _shown;
        // Locked again mid-unlock: fade back from where the unlock got to.
        if (!animate) surface.opacity = 1;
        else if (!wasShown) surface.opacity = 0;
        lift.y = 0;
        clockGroup.opacity = animate ? 0 : 1;
        authGroup.opacity = animate ? 0 : 1;
        rise.y = animate && !Theme.reduceMotion ? 20 : 0;
        idle = false;
        capsule.clear();
        capsule.settle();
        _shown = true;
        if (animate) enterAnim.restart();
        _focusField();
        idleTimer.restart();
    }
    function _leave() {
        if (!_shown) return;
        _leaving = true;
        capsule.clear();
        enterAnim.complete();
        leaveAnim.restart();
    }
    function _focusField() { capsule.focusField(); }
    // Any user input: wake from idle and restart the idle countdown.
    function activity() {
        if (!_shown || _leaving) return;
        idle = false;
        idleTimer.restart();
    }
    function submit() {
        if (_busy || capsule.text.length === 0) return;
        activity();
        session.unlock(capsule.text);
    }
    function _failed() {
        capsule.clear();
        activity();
        _focusField();
        capsule.shake();
    }

    Connections {
        target: root.session
        function onLockedChanged() {
            if (root.session.locked) root._enter(true);
            else root._leave();
        }
        function onAuthErrorChanged() {
            if (root.session.authError !== "" && root._shown) root._failed();
        }
    }
    // Already locked when the shell starts: everything is in place at once.
    Component.onCompleted: if (session.locked && !_shown) _enter(false)

    // No Behavior runs while the screen changes size: the layout snaps.
    property bool _resizing: false
    onWidthChanged: { _resizing = true; resizeSettle.restart(); }
    onHeightChanged: { _resizing = true; resizeSettle.restart(); }
    Timer { id: resizeSettle; interval: 200; onTriggered: root._resizing = false }

    onIdleChanged: {
        if (idle) capsule.clear();
        else if (_shown) _focusField();
    }

    Timer {
        id: idleTimer
        interval: root.idleTimeout * 1000
        running: root._shown && !root._leaving && !root.idle && !root._busy
        onTriggered: root.idle = true
    }

    // Keys nobody handled: printable ones go to the field; every key is
    // accepted so nothing reaches items (or shortcuts) behind the lock.
    Keys.onPressed: event => {
        if (!root._shown) return;
        root.activity();
        if (event.key === Qt.Key_Escape) {
            capsule.clear();
            root._focusField();
        } else if (event.text.length > 0 && event.text.charCodeAt(0) >= 32
                   && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            capsule.typeText(event.text);
        }
        event.accepted = true;
    }
    Keys.onReleased: event => { if (root._shown) event.accepted = true; }
    Keys.onShortcutOverride: event => { if (root._shown) event.accepted = true; }

    // Real pointer movement wakes it. Qt also sends synthetic hover events
    // when items move under a still cursor, so only a move of a few pixels counts.
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
    // Swallows clicks, wheel and hover so nothing under the lock gets them.
    MouseArea {
        anchors.fill: parent
        enabled: root._shown
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onPressed: { root.activity(); root._focusField(); }
        onWheel: wheel => { root.activity(); wheel.accepted = true; }
    }

    // ---- surface ---------------------------------------------------------------
    Item {
        id: surface
        anchors.fill: parent

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

        // Everything in front of the wallpaper; lifts on unlock.
        Item {
            id: scene
            anchors.fill: parent
            transform: Translate { id: lift }

            // ---- clock + date (upper part; drifts to the middle when idle) ----
            Column {
                id: clockGroup
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.round(parent.height * 0.15)
                spacing: Theme.space4

                transform: Translate {
                    y: root.idle && !Theme.reduceMotion
                       ? Math.max(0, Math.round((scene.height - clockGroup.height) / 2 - clockGroup.y - scene.height * 0.04))
                       : 0
                    Behavior on y {
                        enabled: !root._resizing
                        SpringAnimation {
                            spring: Theme.liquidSpring; damping: Theme.liquidDamping
                            mass: Theme.liquidMass; epsilon: Theme.springEpsilon
                        }
                    }
                }

                Text {
                    id: clockText
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Services.clock.time
                    font.family: Theme.fontUi
                    readonly property int px: Math.round(Math.max(88, Math.min(160, scene.height * 0.135)))
                    font.pixelSize: px
                    font.weight: 250
                    font.features: { "tnum": 1 }
                    font.letterSpacing: -px * 0.03
                    color: Theme.text
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Time %1").arg(text)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Services.clock.longDate
                    font.family: Theme.fontUi
                    font.pixelSize: Math.round(clockText.px * 0.16)
                    font.weight: 500
                    color: Theme.text
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }
            }

            // ---- the user and the password capsule ---------------------------
            Item {
                id: authGroup
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.round(parent.height * 0.62)
                width: Math.min(parent.width - Theme.space48, 480)
                height: authColumn.height
                transform: Translate { id: rise }

                Item {
                    id: authFade
                    anchors.fill: parent
                    opacity: root.idle ? 0 : 1
                    visible: opacity > 0
                    enabled: !root.idle
                    Behavior on opacity {
                        NumberAnimation { duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                    }

                    Column {
                        id: authColumn
                        width: parent.width
                        spacing: Theme.space12

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: root.session.realName
                            elide: Text.ElideRight
                            font: Theme.typeTitle3
                            color: Theme.text
                            Accessible.role: Accessible.Heading
                            Accessible.name: text
                        }
                        AuthCapsule {
                            id: capsule
                            anchors.horizontalCenter: parent.horizontalCenter
                            focus: true
                            avatarSource: root.session.avatar
                            avatarName: root.session.realName
                            a11yLabel: root.a11yLabel
                            submitTooltip: qsTr("Unlock")
                            busy: root._busy
                            errorText: root.session.authError
                            capsLock: Services.keyboard.capsLock
                            maxMessageWidth: authGroup.width
                            onSubmitted: root.submit()
                            onEdited: root.activity()
                            onActivity: root.activity()
                        }
                    }
                }
            }

            // ---- bottom left: media, compact -------------------------------
            Island {
                id: mediaIsland
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: Theme.space16
                interactive: false
                animateWidth: false
                leftPadding: Theme.space12
                rightPadding: Theme.space2
                spacing: Theme.space2
                text: qsTr("Media")
                visible: Services.media.hasPlayer && opacity > 0
                opacity: root.idle ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durLarge) } }

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "music-2"
                    size: 14
                    color: Theme.textMuted
                }
                Item { width: Theme.space4; height: 1 }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, Math.max(80, Math.min(240, scene.width * 0.2)))
                    elide: Text.ElideRight
                    text: Services.media.artist !== ""
                          ? qsTr("%1 · %2").arg(Services.media.title).arg(Services.media.artist)
                          : Services.media.title
                    font: Theme.typeLabel
                    color: Theme.text
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Now playing: %1").arg(text)
                }
                Item { width: Theme.space4; height: 1 }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "skip-back"; iconSize: 14
                    tooltip: qsTr("Previous track")
                    focusPolicy: Qt.TabFocus
                    onClicked: { root.activity(); Services.media.previous(); }
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: Services.media.playing ? "pause" : "play"; iconSize: 14
                    tooltip: Services.media.playing ? qsTr("Pause") : qsTr("Play")
                    focusPolicy: Qt.TabFocus
                    onClicked: { root.activity(); Services.media.playPause(); }
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "skip-forward"; iconSize: 14
                    tooltip: qsTr("Next track")
                    focusPolicy: Qt.TabFocus
                    onClicked: { root.activity(); Services.media.next(); }
                }
            }

            // ---- bottom right: status, sleep ---------------------------------
            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Theme.space16
                spacing: Theme.space8
                opacity: root.idle ? 0 : 1
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durLarge) } }

                Island {
                    id: statusIsland
                    interactive: false
                    animateWidth: false
                    visible: notifItem.visible || layoutButton.visible || batteryItem.visible
                    leftPadding: notifItem.visible || !layoutButton.visible ? Theme.space12 : Theme.space2
                    rightPadding: batteryItem.visible || !layoutButton.visible ? Theme.space12 : Theme.space2
                    spacing: Theme.space8
                    text: qsTr("Status")

                    StatusItem {
                        id: notifItem
                        visible: Services.notifications.count > 0
                        iconName: "bell"
                        text: Services.notifications.count > 99 ? "99+" : String(Services.notifications.count)
                        label: Services.notifications.count === 1 ? qsTr("1 notification")
                               : qsTr("%1 notifications").arg(Services.notifications.count)
                    }
                    LabelButton {
                        id: layoutButton
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Services.keyboard.layouts.length > 1
                        text: Services.keyboard.current.toUpperCase()
                        tooltip: qsTr("Keyboard layout %1. Switch layout").arg(text)
                        onClicked: { root.activity(); Services.keyboard.next(); root._focusField(); }
                    }
                    StatusItem {
                        id: batteryItem
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
                        label: Services.power.charging
                               ? qsTr("Battery %1%, charging").arg(Services.power.batteryPercent)
                               : qsTr("Battery %1%").arg(Services.power.batteryPercent)
                    }
                }

                Island {
                    id: sleepIsland
                    visible: root.session.canSuspend
                    width: height
                    animateWidth: false
                    padding: 0
                    text: qsTr("Sleep")
                    onClicked: { root.activity(); root.session.suspend(); }

                    Item {
                        width: Theme.islandHeight
                        height: Theme.islandHeight
                        Icon {
                            anchors.centerIn: parent
                            name: "moon"
                            size: 16
                            color: Theme.text
                        }
                    }
                    Tooltip {
                        text: qsTr("Sleep")
                        visible: sleepIsland.hovered || sleepIsland.visualFocus
                    }
                }
            }
        }
    }

    // ---- animations ------------------------------------------------------------
    // Locking at run time: the surface (opaque base + wallpaper) fades in
    // over the desktop; the clock fades in and the capsule rises into place.
    ParallelAnimation {
        id: enterAnim
        NumberAnimation {
            target: surface; property: "opacity"; to: 1
            duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: clockGroup; property: "opacity"; from: 0; to: 1
            duration: Theme.dur(Theme.durMedium); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: authGroup; property: "opacity"; from: 0; to: 1
            duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: rise; property: "y"; to: 0
            duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }

    // Unlock: the scene lifts and the whole surface fades.
    ParallelAnimation {
        id: leaveAnim
        NumberAnimation {
            target: surface; property: "opacity"; to: 0
            duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        NumberAnimation {
            target: lift; property: "y"; to: Theme.reduceMotion ? 0 : -Math.round(root.height * 0.06)
            duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
        // The surface stays transparent until the next _enter(): resetting
        // it here would draw one more frame of the lock before the unmap.
        onFinished: {
            root._leaving = false;
            root._shown = false;
            root.idle = false;
        }
    }

    // ---- local pieces ----------------------------------------------------------
    // Icon + short value inside an island, with a tooltip and a full name.
    component StatusItem: Row {
        id: si
        property string iconName
        property color iconColor: Theme.text
        property string text
        property string label: text
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        spacing: Theme.space4 + Theme.space2
        Accessible.role: Accessible.StaticText
        Accessible.name: label

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            name: si.iconName
            size: 16
            color: si.iconColor
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: si.text
            font: Theme.typeLabelTnum
            color: Theme.text
            Accessible.ignored: true
        }
        HoverHandler { id: siHover }
        Tooltip {
            text: si.label
            visible: siHover.hovered
        }
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

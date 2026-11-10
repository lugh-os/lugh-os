// Top of the screen, Lugh mode (docs/design/lugh-mode.md §1): three floating
// glass islands, nothing spans the screen.
//
//   logo island (left)      Lugh mark (→ Lugh menu) · focused app · workspace dots
//   center island           date · time, notification dot, media indicator
//                           (→ notification center). It is also the OSD: on
//                           Services.osd.requested it widens to icon + level +
//                           value (or icon + label) for 1.2 s.
//   status island (right)   layout · network · Bluetooth · volume · battery
//                           (→ control center)
//
// Contract with the frame: it sets `width` (screen width) and maps a
// `implicitHeight` (Theme.barHeight) tall layer surface with `exclusiveZone`;
// `inputRects` are the island rects in Bar coordinates for the input mask.
// The Bar keeps ShellState.logoIsland / centerIsland / statusIsland up to date
// in scene coordinates so overlays can morph out of their island.
//
// Cheap to keep up all day: no layers or effects; the clock only re-renders
// its two Text items; status icons re-evaluate only when the Services property
// they read changes; the media indicator is the only looping animation.
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell
import "status.js" as Status

Item {
    id: bar

    // Show the battery percentage next to its icon (Settings, later). It is
    // always shown at 20% and below.
    property bool showBatteryPercent: false
    // Islands drop in from above the first time the bar is on screen.
    property bool dropIn: true

    readonly property int exclusiveZone: Theme.barExclusiveZone
    readonly property var inputRects: [
        Qt.rect(logo.x, logo.y, logo.width, logo.height),
        Qt.rect(center.x, center.y, center.width, center.height),
        Qt.rect(status.x, status.y, status.width, status.height)
    ]
    // OSD timeout after the last request.
    readonly property int osdTimeoutMs: 1200

    implicitWidth: 1440
    implicitHeight: Theme.barHeight

    Accessible.role: Accessible.ToolBar
    Accessible.name: qsTr("Top bar")

    property bool _ready: false
    property bool _dropped: false
    readonly property bool _onScreen: visible && Window.window !== null && Window.window.visible
    function _drop() {
        if (_dropped || !_onScreen)
            return;
        _dropped = true;
        if (!dropIn || Theme.reduceMotion)
            return;
        logoDrop.start(); centerDrop.start(); statusDrop.start();
    }
    on_OnScreenChanged: _drop()
    Component.onCompleted: { _ready = true; _drop(); }

    Binding { target: ShellState; property: "logoIsland"; value: logo.sceneRect }
    Binding { target: ShellState; property: "centerIsland"; value: center.sceneRect }
    Binding { target: ShellState; property: "statusIsland"; value: status.sceneRect }

    component Liquid: SpringAnimation {
        spring: Theme.liquidSpring; damping: Theme.liquidDamping
        mass: Theme.liquidMass; epsilon: Theme.springEpsilon
    }
    component Fade: NumberAnimation {
        duration: Theme.dur(Theme.durSmall)
        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
    }
    // Content swap in the center island: the old content leaves quickly, the
    // new one follows, so the two never sit on top of each other half-faded.
    component Swap: SequentialAnimation {
        id: swap
        property bool entering: false
        PauseAnimation { duration: swap.entering && !Theme.reduceMotion ? Theme.durMicro : 0 }
        NumberAnimation {
            duration: Theme.dur(swap.entering ? Theme.durSmall : Theme.durMicro)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }
    // First-show drop from above the screen edge. A transform, so the island's
    // own geometry (inputRects, sceneRect) is at rest from the start.
    component DropIn: Translate {
        id: drop
        property int order: 0
        function start() { y = -Theme.barHeight; dropAnim.start(); }
        property SequentialAnimation _anim: SequentialAnimation {
            id: dropAnim
            PauseAnimation { duration: 60 + drop.order * 70 }
            Liquid { target: drop; property: "y"; to: 0 }
        }
    }
    component Label: Text {
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        font: Theme.typeLabel
        color: Theme.text
        textFormat: Text.PlainText
        Accessible.ignored: true
    }
    component AppLabel: Label {
        id: appLabel
        property bool shownNow: false
        TextMetrics { id: appMetrics; font: appLabel.font; text: appLabel.text }
        x: appName.lead
        width: Math.min(Math.ceil(appMetrics.advanceWidth), appName.maxText)
        elide: Text.ElideRight
        opacity: shownNow ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { Swap { entering: appLabel.shownNow } }
    }

    // ---- logo island: mark · app · workspaces -----------------------------
    Island {
        id: logo
        objectName: "logoIsland"
        x: Theme.islandSideMargin
        y: Theme.islandMargin
        interactive: false
        animateWidth: false   // the parts inside spring; the island follows them
        padding: Theme.space4
        spacing: 0
        transform: DropIn { id: logoDrop; order: 0 }
        Accessible.ignored: true

        IslandItem {
            id: mark
            objectName: "logo"
            active: ShellState.lughMenuOpen
            leftPadding: Theme.space8 + 1
            rightPadding: Theme.space8 + 1
            Accessible.name: qsTr("Lugh menu")
            Accessible.description: qsTr("About Lugh, settings, lock, log out, restart and shut down")
            onClicked: ShellState.toggleLughMenu()

            contentItem: Item {
                implicitWidth: 16
                implicitHeight: 16
                Image {
                    x: Math.round((parent.width - width) / 2)
                    y: Math.round((parent.height - height) / 2)
                    width: 26  // the mark fills ~60% of the SVG box: ~16 px visible
                    height: 26
                    source: Theme.dark ? "assets/lugh-logo-dark.svg" : "assets/lugh-logo.svg"
                    sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                    smooth: true
                }
            }
        }

        // Focused app name: two labels cross-fade; the width glides.
        Item {
            id: appName
            objectName: "appName"

            readonly property int maxText: 180
            // Clear of the mark's focus ring (4 px outside its capsule).
            readonly property int lead: Theme.space4 + Theme.space2
            readonly property string current: Services.wm.focusedAppName
            property bool _flip: false
            readonly property Text _shown: _flip ? nameB : nameA
            readonly property real target: current === "" ? 0 : lead + _shown.width + Theme.space8
            property real w: target
            Behavior on w { enabled: bar._ready && !Theme.reduceMotion; Liquid {} }
            onCurrentChanged: {
                (_flip ? nameA : nameB).text = current;
                _flip = !_flip;
            }
            Component.onCompleted: nameA.text = current

            width: Math.max(0, w)
            height: Theme.islandHeight
            visible: width > 0.5
            clip: w !== target

            Accessible.role: Accessible.StaticText
            Accessible.name: qsTr("Active app: %1").arg(current)

            AppLabel { id: nameA; shownNow: !appName._flip && appName.current !== "" }
            AppLabel { id: nameB; shownNow: appName._flip && appName.current !== "" }
        }

        Item {
            width: 5
            height: Theme.islandHeight
            visible: dots.visible
            Rectangle {
                x: 2
                y: Math.round((parent.height - height) / 2)
                width: 1
                height: 14
                color: Theme.glassBorder
                // The glass hairline is very faint on glass itself: double it.
                Rectangle { anchors.fill: parent; color: Theme.glassBorder }
            }
        }

        IslandDots {
            id: dots
            objectName: "workspaces"
        }
    }

    // ---- center island: clock, and the OSD ---------------------------------
    QtObject {
        id: osd

        property string kind: ""
        property real value: 0
        property bool showing: false
        property bool animate: false   // level glides only between requests

        readonly property bool isLevel: kind === "volume" || kind === "brightness" || kind === "mic"
        readonly property bool isOn: value >= 0.5
        readonly property bool muted: (kind === "volume" && (Services.audio.muted || value <= 0))
                                      || (kind === "mic" && (Services.audio.micMuted || value <= 0))
        readonly property string iconName: {
            switch (kind) {
            case "volume":
                return muted ? "volume-x" : value < 0.34 ? "volume" : value < 0.67 ? "volume-1" : "volume-2";
            case "brightness": return value < 0.5 ? "sun-dim" : "sun";
            case "mic": return muted ? "mic-off" : "mic";
            case "caps": return isOn ? "arrow-big-up-dash" : "arrow-big-up";
            case "layout": return "keyboard";
            case "airplane": return "plane";
            case "mode": return "layout-dashboard";
            }
            return "";
        }
        readonly property string label: {
            switch (kind) {
            case "volume": return qsTr("Volume");
            case "brightness": return qsTr("Brightness");
            case "mic": return qsTr("Microphone");
            case "caps": return isOn ? qsTr("Caps Lock on") : qsTr("Caps Lock off");
            case "layout": return Services.keyboard.current.toUpperCase();
            case "airplane": return isOn ? qsTr("Airplane mode on") : qsTr("Airplane mode off");
            case "mode": {
                const m = ShellState.mode;
                return qsTr("%1 mode").arg(m.charAt(0).toUpperCase() + m.slice(1));
            }
            }
            return "";
        }
        readonly property string percentText: Math.round(value * 100) + "%"
        readonly property string spoken: isLevel
            ? (muted ? qsTr("%1 muted").arg(label) : label + " " + percentText)
            : kind === "layout" ? qsTr("Keyboard layout %1").arg(label) : label

        function show(k, v) {
            animate = showing && k === kind;
            kind = k;
            value = Math.max(0, Math.min(1.5, Number(v) || 0));
            showing = true;
            hideTimer.restart();
            announceTimer.restart();
        }
    }
    Connections {
        target: Services.osd
        function onRequested(kind, value) { osd.show(kind, value); }
    }
    Timer {
        id: hideTimer
        interval: bar.osdTimeoutMs
        onTriggered: osd.showing = false
    }
    Timer {
        // Debounced, so holding a volume key doesn't flood the screen reader.
        id: announceTimer
        interval: 250
        onTriggered: {
            // Accessible.announce() is Qt 6.8+; guarded so older runtimes only
            // lose the announcement (the live Accessible.name still updates).
            if (typeof center.Accessible.announce === "function")
                center.Accessible.announce(osd.spoken);
        }
    }

    Island {
        id: center
        objectName: "centerIsland"
        // Centered on the screen while its width springs.
        x: (bar.width - width) / 2
        y: Theme.islandMargin
        animateWidth: false   // the stage inside springs; the island follows it
        // Overlays that grow out of this island keep it lit.
        active: ShellState.notificationCenterOpen || ShellState.launcherOpen
        transform: DropIn { id: centerDrop; order: 1 }

        readonly property string clockName: {
            const n = Services.notifications;
            const parts = [Services.clock.longDate + ", " + Services.clock.time,
                           n.dnd ? qsTr("Do not disturb is on")
                           : n.count > 0 ? qsTr("%n notification(s)", "", n.count) : qsTr("No notifications")];
            if (Services.media.hasPlayer && Services.media.title !== "")
                parts.push((Services.media.playing ? qsTr("Playing: %1") : qsTr("Paused: %1")).arg(Services.media.title));
            return parts.join("; ");
        }
        text: osd.showing ? osd.spoken : clockName
        Accessible.description: qsTr("Open notifications and calendar")
        onClicked: ShellState.toggleNotificationCenter()

        Item {
            id: stage

            // Whole pixels, and the same parity as the bar, so the centered
            // island rests on the pixel grid and its text stays crisp.
            readonly property real target: {
                const inner = Math.ceil(osd.showing ? osdRow.implicitWidth : clockRow.implicitWidth);
                const odd = (Math.round(bar.width) - inner - center.leftPadding - center.rightPadding) % 2 !== 0;
                return inner + (odd ? 1 : 0);
            }
            property real w: target
            Behavior on w { enabled: bar._ready && !Theme.reduceMotion; Liquid {} }

            width: Math.max(0, w)
            height: Theme.islandHeight
            clip: w !== target

            // -- clock ------------------------------------------------------
            Row {
                id: clockRow
                anchors.centerIn: parent
                height: parent.height
                spacing: Theme.space4 + Theme.space2
                opacity: osd.showing ? 0 : 1
                visible: opacity > 0
                Behavior on opacity { Swap { entering: !osd.showing } }

                MediaBars {
                    objectName: "media"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Services.media.hasPlayer
                    playing: Services.media.playing
                }
                Label { text: Services.clock.date; color: Theme.textMuted }
                Label { text: "·"; color: Theme.textMuted }
                Label { text: Services.clock.time; font: Theme.typeLabelTnum }
                // Waiting notifications: a dot. Do not disturb: a slashed bell.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Services.notifications.count > 0 && !Services.notifications.dnd
                    width: 6
                    height: 6
                    radius: 3
                    color: Theme.accent
                    antialiasing: true
                }
                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Services.notifications.dnd
                    name: "bell-off"
                    size: 14
                    color: Theme.textMuted
                }
            }

            // -- OSD --------------------------------------------------------
            Row {
                id: osdRow
                anchors.centerIn: parent
                height: parent.height
                spacing: Theme.space8
                opacity: osd.showing ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { Swap { entering: osd.showing } }

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: osd.iconName
                    size: 16
                    color: osd.isLevel && osd.muted ? Theme.textMuted : Theme.text
                }
                Rectangle {
                    id: track
                    visible: osd.isLevel
                    anchors.verticalCenter: parent.verticalCenter
                    width: 120
                    height: 6
                    radius: 3
                    color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.18 : 0.14)

                    property real shownValue: Math.min(1, osd.value)
                    Behavior on shownValue { enabled: osd.animate; Fade {} }

                    Rectangle {
                        height: parent.height
                        radius: parent.radius
                        width: track.shownValue > 0 ? Math.max(height, parent.width * track.shownValue) : 0
                        color: osd.muted ? Theme.textMuted : Theme.accent
                        antialiasing: true
                        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
                    }
                }
                Label {
                    visible: osd.isLevel
                    width: Math.ceil(pctMetrics.advanceWidth)
                    horizontalAlignment: Text.AlignRight
                    text: osd.percentText
                    font: Theme.typeLabelTnum
                    color: osd.muted ? Theme.textMuted : Theme.text
                    TextMetrics { id: pctMetrics; font: Theme.typeLabelTnum; text: "100%" }
                }
                Label {
                    visible: !osd.isLevel
                    text: osd.label
                }
            }
        }
    }

    // ---- status island: layout · network · Bluetooth · volume · battery ------
    Island {
        id: status
        objectName: "statusIsland"
        x: bar.width - width - Theme.islandSideMargin
        y: Theme.islandMargin
        active: ShellState.controlCenterOpen
        transform: DropIn { id: statusDrop; order: 2 }

        text: Status.summary(Services.network, Services.bluetooth, Services.audio, Services.power, Services.keyboard)
        Accessible.description: qsTr("Open the control center")
        onClicked: ShellState.toggleControlCenter()

        Label {
            objectName: "layout"
            visible: Services.keyboard.layouts.length > 1
            text: Services.keyboard.current.toUpperCase()
        }
        Icon {
            id: netIcon
            anchors.verticalCenter: parent.verticalCenter
            size: 16
            name: Status.networkIcon(Services.network)
            color: Theme.text
            // Gentle pulse while joining a network.
            SequentialAnimation on opacity {
                running: Services.network.connectingSsid !== "" && !Theme.reduceMotion
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
            // Secondary click: straight to the Wi-Fi drawer.
            TapHandler {
                acceptedButtons: Qt.RightButton
                margin: Theme.space4
                onTapped: ShellState.openControlCenter("wifi")
            }
        }
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            visible: Status.bluetoothShown(Services.bluetooth)
            size: 16
            name: "bluetooth-connected"
            color: Theme.text
        }
        Icon {
            anchors.verticalCenter: parent.verticalCenter
            size: 16
            name: Status.volumeIcon(Services.audio)
            color: Theme.text
            TapHandler {
                acceptedButtons: Qt.RightButton
                margin: Theme.space4
                onTapped: ShellState.openControlCenter("sound")
            }
        }
        Row {
            visible: Services.power.hasBattery
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space4
            readonly property bool low: Status.batteryLow(Services.power)
            Icon {
                anchors.verticalCenter: parent.verticalCenter
                size: 16
                name: Status.batteryIcon(Services.power)
                color: parent.low ? Theme.danger : Theme.text
            }
            Label {
                visible: bar.showBatteryPercent || Services.power.batteryPercent <= 20
                text: Services.power.batteryPercent + "%"
                font: Theme.typeLabelTnum
                color: parent.low ? Theme.danger : Theme.text
            }
        }
    }
}

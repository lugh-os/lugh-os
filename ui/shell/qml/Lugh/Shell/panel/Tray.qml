// The Panel's tray: ONE compact button at the right end with the status
// icons and the clock (→ quick panel / control center).
//
//   [media] [layout] network · Bluetooth · volume · battery   12:45
//                                                            Wed 11 Nov •
//
// Which icons show, the clock format and the date line follow ShellSettings
// (trayShow*, clock24h, clockShowSeconds, clockShowDate, clockDateFormat). A
// dot on the clock says there are notifications (a slashed bell under do not
// disturb). Right click on the network or volume icon opens that page of the
// control center directly.
//
// It is also the OSD: on Services.osd.requested the content swaps to icon +
// level + value (or icon + label) for `osdTimeoutMs`; the width glides with
// the liquid spring and the tray grows to the left (it is right-anchored).
//
// `clockItem` is the clock (the Panel publishes it as ShellState.centerIsland);
// `restingWidth` is the width without the OSD, for the Panel's layout.
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell
import "../bar"
import "../bar/status.js" as Status

PanelButton {
    id: tray

    readonly property int osdTimeoutMs: 1200
    readonly property Item clockItem: clock
    readonly property real restingWidth: Math.ceil(normalRow.implicitWidth) + leftPadding + rightPadding
    property bool _ready: false
    Component.onCompleted: Qt.callLater(() => tray._ready = true)

    readonly property bool _notified: Services.notifications.count > 0 && !Services.notifications.dnd
    readonly property string timeText: {
        const s = ShellSettings.clockShowSeconds;
        const f = ShellSettings.clock24h ? (s ? "HH:mm:ss" : "HH:mm") : (s ? "h:mm:ss AP" : "h:mm AP");
        return Qt.formatTime(Services.clock.now, f);
    }
    readonly property string dateText: Qt.formatDate(Services.clock.now, ShellSettings.clockDateFormat || "ddd d MMM")
    readonly property string spokenStatus: {
        const n = Services.notifications;
        return [Services.clock.longDate + ", " + timeText,
                Status.summary(Services.network, Services.bluetooth, Services.audio, Services.power, Services.keyboard),
                n.dnd ? qsTr("Do not disturb is on")
                : n.count > 0 ? qsTr("%n notification(s)", "", n.count) : qsTr("No notifications")].join("; ");
    }

    label: osd.showing ? "" : Services.clock.longDate
    active: ShellState.controlCenterOpen || ShellState.notificationCenterOpen
    leftPadding: Theme.space12 - 2
    rightPadding: Theme.space12 - 2
    radius: Math.min(height / 2, Theme.radiusMd + 2)
    Accessible.name: osd.showing ? osd.spoken : spokenStatus
    Accessible.description: qsTr("Open quick settings, calendar and notifications")
    onClicked: ShellState.toggleControlCenter()

    component Label: Text {
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        font: Theme.typeLabel
        color: Theme.text
        textFormat: Text.PlainText
        Accessible.ignored: true
    }
    component StatusIcon: Icon {
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        size: 16
        color: Theme.text
    }
    component Swap: SequentialAnimation {
        id: swap
        property bool entering: false
        PauseAnimation { duration: swap.entering && !Theme.reduceMotion ? Theme.durMicro : 0 }
        NumberAnimation {
            duration: Theme.dur(swap.entering ? Theme.durSmall : Theme.durMicro)
            easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        }
    }

    // ---- OSD state ------------------------------------------------------------
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
        interval: tray.osdTimeoutMs
        onTriggered: osd.showing = false
    }
    Timer {
        // Debounced, so holding a volume key doesn't flood the screen reader.
        id: announceTimer
        interval: 250
        onTriggered: {
            // Accessible.announce() is Qt 6.8+; guarded.
            if (typeof tray.Accessible.announce === "function")
                tray.Accessible.announce(osd.spoken);
        }
    }

    contentItem: Item {
        id: stage

        // Whole pixels so the text stays on the pixel grid.
        readonly property real target: Math.ceil(osd.showing ? osdRow.implicitWidth : normalRow.implicitWidth)
        property real w: target
        Behavior on w {
            enabled: tray._ready && !Theme.reduceMotion
            SpringAnimation { spring: Theme.liquidSpring; damping: Theme.liquidDamping; mass: Theme.liquidMass; epsilon: Theme.springEpsilon }
        }

        implicitWidth: Math.max(0, w)
        implicitHeight: tray.height
        clip: w !== target

        // -- status icons + clock -----------------------------------------------
        Row {
            id: normalRow
            anchors.right: parent.right
            height: parent.height
            spacing: Theme.space12
            opacity: osd.showing ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { Swap { entering: !osd.showing } }

            Row {
                id: icons
                height: parent.height
                spacing: Theme.space8
                visible: visibleChildren.length > 0

                MediaBars {
                    objectName: "media"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: ShellSettings.trayShowMedia && Services.media.hasPlayer
                    playing: Services.media.playing
                }
                Label {
                    objectName: "layout"
                    visible: ShellSettings.trayShowKeyboard && Services.keyboard.layouts.length > 0
                    text: Services.keyboard.current.toUpperCase()
                    font: Theme.typeCaption
                }
                StatusIcon {
                    id: netIcon
                    visible: ShellSettings.trayShowNetwork
                    name: Status.networkIcon(Services.network)
                    // Gentle pulse while joining a network.
                    SequentialAnimation on opacity {
                        running: netIcon.visible && Services.network.connectingSsid !== "" && !Theme.reduceMotion
                        loops: Animation.Infinite
                        alwaysRunToEnd: true
                        NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        gesturePolicy: TapHandler.WithinBounds
                        margin: Theme.space4
                        onTapped: ShellState.openControlCenter("wifi")
                    }
                }
                StatusIcon {
                    visible: ShellSettings.trayShowBluetooth && Status.bluetoothShown(Services.bluetooth)
                    name: "bluetooth-connected"
                }
                StatusIcon {
                    visible: ShellSettings.trayShowVolume
                    name: Status.volumeIcon(Services.audio)
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        gesturePolicy: TapHandler.WithinBounds
                        margin: Theme.space4
                        onTapped: ShellState.openControlCenter("sound")
                    }
                }
                Row {
                    readonly property bool low: Status.batteryLow(Services.power)
                    visible: ShellSettings.trayShowBattery && Services.power.hasBattery
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space2
                    StatusIcon {
                        name: Status.batteryIcon(Services.power)
                        color: parent.low ? Theme.danger : Theme.text
                    }
                    Label {
                        visible: ShellSettings.showBatteryPercent || Services.power.batteryPercent <= 20
                        text: Services.power.batteryPercent + "%"
                        font: Theme.typeCaptionTnum
                        color: parent.low ? Theme.danger : Theme.text
                    }
                }
            }

            // -- clock: time over date ----------------------------------------------
            Item {
                id: clock
                objectName: "clock"
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: Math.ceil(Math.max(timeLabel.implicitWidth, dateLabel.visible ? dateLabel.implicitWidth : 0))
                                + (badge.visible ? badge.width + 3 : 0)
                implicitHeight: clockCol.implicitHeight
                width: implicitWidth
                height: implicitHeight

                Column {
                    id: clockCol
                    anchors.right: parent.right
                    anchors.rightMargin: badge.visible ? badge.width + 3 : 0
                    spacing: -1
                    Text {
                        id: timeLabel
                        anchors.right: parent.right
                        text: tray.timeText
                        font: Theme.typeLabelTnum
                        color: Theme.text
                        textFormat: Text.PlainText
                        Accessible.ignored: true
                    }
                    Text {
                        id: dateLabel
                        anchors.right: parent.right
                        visible: ShellSettings.clockShowDate && tray.height >= 32
                        text: tray.dateText
                        font: Theme.typeCaption
                        color: Theme.textMuted
                        textFormat: Text.PlainText
                        Accessible.ignored: true
                    }
                }
                // Notifications waiting: an accent dot. Do not disturb: a
                // slashed bell. Shape, not color alone (the name says it too).
                Item {
                    id: badge
                    anchors.right: parent.right
                    anchors.top: clockCol.top
                    anchors.topMargin: 2
                    width: Services.notifications.dnd ? 12 : 6
                    height: width
                    visible: tray._notified || Services.notifications.dnd
                    Rectangle {
                        anchors.fill: parent
                        visible: !Services.notifications.dnd
                        radius: width / 2
                        color: Theme.focusRing
                        antialiasing: true
                    }
                    Icon {
                        visible: Services.notifications.dnd
                        name: "bell-off"
                        size: 12
                        color: Theme.textMuted
                    }
                }
            }
        }

        // -- OSD ------------------------------------------------------------------
        Row {
            id: osdRow
            anchors.right: parent.right
            height: parent.height
            spacing: Theme.space8
            opacity: osd.showing ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { Swap { entering: osd.showing } }

            StatusIcon {
                name: osd.iconName
                color: osd.isLevel && osd.muted ? Theme.textMuted : Theme.text
            }
            Rectangle {
                id: track
                visible: osd.isLevel
                anchors.verticalCenter: parent.verticalCenter
                width: 96
                height: 6
                radius: 3
                color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.18 : 0.14)

                property real shownValue: Math.min(1, osd.value)
                Behavior on shownValue {
                    enabled: osd.animate
                    NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                }

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: track.shownValue > 0 ? Math.max(height, parent.width * track.shownValue) : 0
                    color: osd.muted ? Theme.textMuted : Theme.focusRing
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

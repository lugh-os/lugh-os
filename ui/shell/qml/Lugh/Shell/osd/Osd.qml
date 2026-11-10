// On-screen display (shell spec §OSDs): a glass pill at the bottom centre,
// shown for 1.2 s after the last Services.osd.requested(kind, value).
// Content-sized: the frame anchors this item bottom-centre (96 px above the
// screen edge); implicitWidth/Height include room for the pill's shadow on
// the sides and above (below falls into the frame's 96 px padding).
//
// Kinds (Services.osd): value is 0..1 for levels; 1 = on / 0 = off for toggles.
//   volume      speaker icon by level (volume-x when muted or 0), thin bar, %
//   brightness  sun-dim / sun, thin bar, %
//   mic         mic / mic-off + "Microphone on/off" (1 = live, 0 = muted)
//   caps        "Caps Lock on/off"
//   layout      keyboard icon + Services.keyboard.current (upper case)
//   airplane    "Airplane mode on/off"
//   mode        "<Mode> mode" from ShellState.mode (mode-switch OSD)
// Re-requests while visible update in place (the bar animates) and restart
// the 1.2 s timer. Fades in/out in 180 ms; fully hidden (not rendered) when
// faded out. Changes are announced to screen readers (debounced, so holding
// a volume key doesn't flood them).
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell

Item {
    id: root

    readonly property int pillWidth: 260
    readonly property int pillHeight: 52
    readonly property int timeoutMs: 1200
    // Shadow room (Shadow "popover" level: ~30 px sides, ~24 px above).
    readonly property int padX: 30
    readonly property int padTop: 24

    property string kind: ""
    property real value: 0
    property bool _active: false

    readonly property bool shown: _active || pill.opacity > 0
    readonly property bool isLevel: kind === "volume" || kind === "brightness"
    readonly property bool muted: kind === "volume" && (Services.audio.muted || value <= 0)
    readonly property bool isOn: value >= 0.5

    readonly property string iconName: {
        switch (kind) {
        case "volume":
            return muted ? "volume-x" : value < 0.34 ? "volume" : value < 0.67 ? "volume-1" : "volume-2";
        case "brightness": return value < 0.5 ? "sun-dim" : "sun";
        case "mic": return isOn ? "mic" : "mic-off";
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
        case "mic": return isOn ? qsTr("Microphone on") : qsTr("Microphone off");
        case "caps": return isOn ? qsTr("Caps Lock on") : qsTr("Caps Lock off");
        case "layout": return qsTr("Keyboard layout");
        case "airplane": return isOn ? qsTr("Airplane mode on") : qsTr("Airplane mode off");
        case "mode": {
            const m = ShellState.mode;
            return qsTr("%1 mode").arg(m.charAt(0).toUpperCase() + m.slice(1));
        }
        }
        return "";
    }
    readonly property string percentText: Math.round(Math.max(0, Math.min(1, value)) * 100) + "%"
    readonly property string spoken: isLevel
        ? (muted ? qsTr("Volume muted") : label + " " + percentText)
        : kind === "layout" ? label + " " + Services.keyboard.current.toUpperCase() : label

    implicitWidth: pillWidth + 2 * padX
    implicitHeight: pillHeight + padTop

    function show(k, v) {
        kind = k;
        value = Math.max(0, Math.min(1, Number(v) || 0));
        _active = true;
        hideTimer.restart();
        announceTimer.restart();
    }

    Connections {
        target: Services.osd
        function onRequested(kind, value) { root.show(kind, value); }
    }

    Timer {
        id: hideTimer
        interval: root.timeoutMs
        onTriggered: root._active = false
    }
    Timer {
        id: announceTimer
        interval: 250
        onTriggered: {
            // Accessible.announce() is Qt 6.8+; guarded so older runtimes only
            // lose the announcement (the live Accessible.name still updates).
            if (typeof pill.Accessible.announce === "function")
                pill.Accessible.announce(root.spoken);
        }
    }

    GlassPanel {
        id: pill
        x: root.padX
        y: root.padTop
        width: root.pillWidth
        height: root.pillHeight
        radius: height / 2
        elevation: "popover"

        opacity: root._active ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: Theme.dur(Theme.durSmall)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }
        scale: root._active || Theme.reduceMotion ? 1 : 0.96
        Behavior on scale {
            enabled: !Theme.reduceMotion
            NumberAnimation {
                duration: Theme.durSmall
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }

        Accessible.role: root.isLevel ? Accessible.ProgressBar : Accessible.StaticText
        Accessible.name: root.spoken

        // ---- level: icon, bar, percentage -----------------------------------
        RowLayout {
            visible: root.isLevel
            anchors.fill: parent
            anchors.leftMargin: Theme.space20
            anchors.rightMargin: Theme.space20
            spacing: Theme.space12

            Icon {
                name: root.iconName
                size: 20
                color: root.muted ? Theme.textMuted : Theme.text
            }
            Rectangle {
                id: track
                Layout.fillWidth: true
                Layout.preferredHeight: 6
                radius: 3
                color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.16 : 0.12)

                property real shownValue: root.value
                Behavior on shownValue {
                    enabled: pill.opacity > 0.5
                    NumberAnimation {
                        duration: Theme.dur(Theme.durSmall)
                        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                    }
                }
                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: track.shownValue > 0 ? Math.max(height, parent.width * track.shownValue) : 0
                    color: root.muted ? Theme.textMuted : Theme.accent
                    Behavior on color { ColorAnimation { duration: Theme.durMicro } }
                }
            }
            Text {
                Layout.preferredWidth: pctMetrics.width
                horizontalAlignment: Text.AlignRight
                text: root.percentText
                font: Theme.typeBodyTnum
                color: root.muted ? Theme.textMuted : Theme.text
                TextMetrics { id: pctMetrics; font: Theme.typeBodyTnum; text: "100%" }
            }
        }

        // ---- toggles / text: centred icon + label (+ layout name) -----------
        RowLayout {
            visible: !root.isLevel
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - 2 * Theme.space20)
            spacing: Theme.space12

            Icon {
                name: root.iconName
                size: 20
                color: Theme.text
            }
            Text {
                Layout.fillWidth: true
                text: root.label
                font: Theme.typeBodyStrong
                color: Theme.text
                elide: Text.ElideRight
            }
            Rectangle {
                visible: root.kind === "layout"
                Layout.preferredWidth: layoutName.implicitWidth + 2 * Theme.space8
                Layout.preferredHeight: 24
                radius: Theme.radiusSm
                color: Theme.selectedBg
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                Text {
                    id: layoutName
                    anchors.centerIn: parent
                    text: Services.keyboard.current.toUpperCase()
                    font: Theme.typeBodyTnum
                    color: Theme.accentText
                }
            }
        }
    }
}

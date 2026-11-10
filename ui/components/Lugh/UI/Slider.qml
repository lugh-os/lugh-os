// Thick control-center slider (volume, brightness).
//
//   Slider { iconName: "volume-2"; iconTooltip: qsTr("Mute"); showValue: true
//            value: audio.volume; onMoved: audio.volume = value
//            onIconClicked: audio.muted = !audio.muted }
//
// 28 px rounded track; the accent fill grows from the left with a straight
// leading edge (clipped, no offscreen pass) and a small grip. `compact: true`
// gives the 20 px track used in islands, the OSD and control-center rows. The optional
// leading icon sits inside the track and switches to `onAccent` exactly where
// the fill covers it. Arrow keys step by `stepSize`; Page Up/Down by 10 %.
import QtQuick
import QtQuick.Templates as T

T.Slider {
    id: control

    property string iconName: ""
    property string iconTooltip: ""
    property bool showValue: false
    property bool compact: false

    signal iconClicked()

    readonly property int _trackH: compact ? 20 : 28
    readonly property int _iconSize: compact ? 14 : 16
    readonly property int _iconZone: iconName !== "" ? (compact ? 26 : 32) : 0
    readonly property int _valueW: showValue ? 40 : 0
    readonly property real _fillW: Math.round(visualPosition * track.width)
    readonly property bool _hot: enabled && (hovered || pressed)

    implicitWidth: 240
    implicitHeight: Math.max(Theme.hitTarget, _trackH)
    orientation: Qt.Horizontal
    stepSize: 0.01
    padding: 0
    rightPadding: showValue ? _valueW + Theme.space8 : 0
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.disabledOpacity

    Keys.onPressed: event => {
        if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
            const step = (to - from) / 10 * (event.key === Qt.Key_PageUp ? 1 : -1);
            value = Math.max(Math.min(from, to), Math.min(Math.max(from, to), value + step));
            moved();
            event.accepted = true;
        }
    }

    Accessible.role: Accessible.Slider
    Accessible.name: iconTooltip !== "" ? iconTooltip : iconName

    background: Rectangle {
        id: track
        x: control.leftPadding
        y: (control.height - height) / 2
        width: control.availableWidth
        height: control._trackH
        radius: height / 2
        antialiasing: true
        color: control._hot ? Qt.tint(Theme.surface3, Theme.hoverOverlay) : Theme.surface3
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
        // hairline so the unfilled part reads on dark surfaces and on glass
        border.width: 1
        border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.16 : 0.10)

        // muted icon (under the fill)
        Icon {
            id: iconBase
            visible: control.iconName !== ""
            x: (control._iconZone - size) / 2 + 2
            anchors.verticalCenter: parent.verticalCenter
            name: control.iconName
            size: control._iconSize
            color: Theme.textMuted
        }

        // fill: a full-width pill seen through a clip that grows from the left
        Item {
            id: fillClip
            width: control._fillW
            height: parent.height
            clip: true

            Rectangle {
                width: track.width
                height: track.height
                radius: track.radius
                antialiasing: true
                color: control.pressed ? Qt.tint(Theme.accent, Theme.pressedOverlay)
                     : control._hot ? Qt.tint(Theme.accent, Theme.hoverOverlay) : Theme.accent
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }
            }

            // same icon, on-accent, only where the fill is
            Icon {
                visible: control.iconName !== ""
                x: iconBase.x
                anchors.verticalCenter: parent.verticalCenter
                name: control.iconName
                size: control._iconSize
                color: Theme.onAccent
            }

            // grip at the leading edge
            Rectangle {
                width: 3
                height: control.compact ? 8 : 12
                radius: 1.5
                x: parent.width - width - 6
                anchors.verticalCenter: parent.verticalCenter
                visible: x > Math.max(6, control._iconZone + 2)
                color: Theme.onAccent
                opacity: control._hot || control.visualFocus ? 0.55 : 0.3
                Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
            }
        }

        // icon tap target (does not move the value)
        MouseArea {
            id: iconArea
            visible: control.iconName !== ""
            width: control._iconZone
            height: parent.height
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: control.iconClicked()
            Accessible.role: Accessible.Button
            Accessible.name: control.iconTooltip !== "" ? control.iconTooltip : control.iconName
            Accessible.onPressAction: control.iconClicked()

            Rectangle {
                anchors.fill: parent
                anchors.margins: 2
                radius: height / 2
                color: iconArea.pressed ? Theme.pressedOverlay : Theme.hoverOverlay
                opacity: iconArea.containsMouse ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
            }

            Tooltip {
                text: control.iconTooltip
                visible: control.iconTooltip !== "" && iconArea.containsMouse && !iconArea.pressed
            }
        }

        FocusRing { show: control.visualFocus }
    }

    handle: null

    Text {
        visible: control.showValue
        x: control.width - width
        width: control._valueW
        height: control.height
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: Math.round(control.position * 100) + "%"
        font: Theme.typeCaptionTnum
        color: Theme.textMuted
        Accessible.ignored: true
    }
}

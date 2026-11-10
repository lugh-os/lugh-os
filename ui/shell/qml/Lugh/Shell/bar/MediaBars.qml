// Tiny "now playing" indicator for the center island: three bars that dance
// while `playing` and rest at fixed heights when paused. The only looping
// animation in the bar; it runs only while playing, visible and motion is
// allowed.
import QtQuick
import Lugh.UI

Item {
    id: root

    property bool playing: false
    property color color: playing ? Theme.accentText : Theme.textMuted
    readonly property bool running: playing && visible && !Theme.reduceMotion

    implicitWidth: 10
    implicitHeight: 12

    component Bar: Rectangle {
        id: b
        property real rest: 6
        property int period: 420
        width: 2
        height: rest
        y: (root.height - height) / 2
        radius: 1
        color: root.color
        antialiasing: true
        SequentialAnimation on height {
            id: dance
            running: root.running
            loops: Animation.Infinite
            NumberAnimation { to: 12; duration: b.period; easing.type: Easing.InOutSine }
            NumberAnimation { to: 3; duration: b.period; easing.type: Easing.InOutSine }
        }
        Connections {
            target: root
            function onRunningChanged() { if (!root.running) b.height = b.rest; }
        }
    }

    Bar { x: 0; rest: 6; period: 380 }
    Bar { x: 4; rest: 11; period: 290 }
    Bar { x: 8; rest: 4; period: 450 }
}

// Tiny "now playing" indicator for the center island: three bars that step
// between heights while `playing` and rest at fixed heights when paused.
//
// It is the only repeating animation in the bar, so it is deliberately cheap:
// the bars change in discrete steps a few times a second (one frame per
// step, ~3 frames/s) instead of a continuous 60 fps tween that would keep the
// whole bar surface and the compositor's blur redrawing for as long as music
// plays. It runs only while playing, visible and motion is allowed.
import QtQuick
import Lugh.UI

Item {
    id: root

    property bool playing: false
    property color color: playing ? Theme.accentText : Theme.textMuted
    readonly property bool running: playing && visible && !Theme.reduceMotion
    // Step patterns (bar heights in px); the timer walks through them.
    readonly property var _steps: [[6, 11, 4], [10, 5, 8], [4, 9, 12], [8, 12, 6], [12, 6, 9], [5, 8, 3]]
    property int _step: 0

    implicitWidth: 10
    implicitHeight: 12

    Timer {
        interval: 320
        repeat: true
        running: root.running
        onTriggered: root._step = (root._step + 1) % root._steps.length
    }
    onRunningChanged: if (!running) _step = 0

    Repeater {
        model: 3
        Rectangle {
            required property int index
            x: index * 4
            width: 2
            height: root.running ? root._steps[root._step][index] : root._steps[0][index]
            y: (root.height - height) / 2
            radius: 1
            color: root.color
            antialiasing: true
        }
    }
}

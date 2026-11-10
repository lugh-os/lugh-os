// Activity spinner for actions in progress (DESIGN-SYSTEM §7: content loads
// with Skeleton, actions with a spinner).
//
//   Spinner { size: 16; running: busy }
//
// A faint full ring with a round-capped arc turning on it. The shape is
// static; only its rotation animates, on the render thread (RotationAnimator).
// Under reduce motion it keeps turning (it carries meaning) but slower.
import QtQuick
import QtQuick.Shapes

Item {
    id: root

    property bool running: true
    property int size: 16
    property color color: Theme.textMuted

    readonly property real _stroke: Math.max(1.5, size / 8)
    readonly property real _r: (size - _stroke) / 2

    implicitWidth: size
    implicitHeight: size
    opacity: running ? 1 : 0
    visible: opacity > 0
    Behavior on opacity {
        NumberAnimation { duration: Theme.dur(Theme.durMicro) }
    }

    Accessible.role: Accessible.Animation
    Accessible.name: qsTr("Loading")

    // track
    Rectangle {
        anchors.centerIn: parent
        width: root.size - root._stroke
        height: width
        radius: width / 2
        color: "transparent"
        border.width: root._stroke
        border.color: root.color
        opacity: 0.2
        antialiasing: true
    }

    // arc
    Shape {
        id: arc
        anchors.centerIn: parent
        width: root.size
        height: root.size
        preferredRendererType: Shape.CurveRenderer
        antialiasing: true

        ShapePath {
            strokeColor: root.color
            strokeWidth: root._stroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.size / 2
                centerY: root.size / 2
                radiusX: root._r
                radiusY: root._r
                startAngle: -90
                sweepAngle: 100
            }
        }

        RotationAnimator on rotation {
            from: 0
            to: 360
            duration: Theme.reduceMotion ? 1600 : 800
            loops: Animation.Infinite
            running: root.running && root.visible
        }
    }
}

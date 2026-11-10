// Round icon toggle for the control center (docs/design/lugh-mode.md §3).
//
//   IconToggle {
//       iconName: "wifi-off"; checkedIconName: "wifi"
//       label: qsTr("Wi-Fi"); stateText: net.ssid       // "Wi-Fi, on, Kigali Heights 5G"
//       checked: net.wifiEnabled; hasDetail: true; busy: net.scanning
//       onToggled: net.wifiEnabled = checked
//       onDetailRequested: wifiDrawer.expanded = true
//   }
//
// Off = translucent neutral fill + hairline (reads on glass); on = the tone
// fill growing from the center (liquid spring) with the on-tone icon. The
// grid never spells the state: tooltip and accessible name do, and the icon
// swaps (`checkedIconName`) so it is not color alone. Click, Space or Enter
// toggle and emit toggled() (as with any QtQuick button, a user toggle
// replaces a `checked:` binding — re-assert it from your service state).
// `hasDetail` adds a chevron tick at the bottom-right; the tick, a 500 ms long
// press, right click or the Right arrow emit detailRequested() without
// toggling. `busy` turns a thin arc around the rim.
// tone: accent | danger | success | info | neutral.
import QtQuick
import QtQuick.Shapes
import QtQuick.Templates as T

T.Button {
    id: control

    property string iconName: ""
    property string checkedIconName: ""
    property int size: 48
    property string label: ""
    property string stateText: ""
    property bool hasDetail: false
    property bool busy: false
    property string tone: "accent"

    signal detailRequested()

    readonly property color _fill: tone === "danger" ? Theme.danger
        : tone === "success" ? Theme.success
        : tone === "info" ? Theme.info
        : tone === "neutral" ? Theme.text : Theme.accent
    readonly property color _on: tone === "accent" ? Theme.onAccent
        : tone === "neutral" ? Theme.bg : Theme.onDanger
    readonly property bool _down: enabled && (down || area.pressed)
    readonly property bool _hover: enabled && area.containsMouse
    readonly property int _iconSize: Math.round(size * 0.42)

    function _toggle() { toggle(); toggled(); }

    implicitWidth: Math.max(size, Theme.hitTarget)
    implicitHeight: implicitWidth
    padding: 0
    checkable: true
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : Theme.disabledOpacity

    Keys.onReturnPressed: _toggle()
    Keys.onEnterPressed: _toggle()
    Keys.onRightPressed: event => {
        if (hasDetail) detailRequested();
        else event.accepted = false;
    }

    Accessible.role: Accessible.Button
    Accessible.name: label + ", " + (checked ? qsTr("on") : qsTr("off"))
                     + (stateText !== "" ? ", " + stateText : "")
    Accessible.checkable: true
    Accessible.checked: checked

    background: null

    contentItem: Item {
        Item {
            id: visual
            anchors.centerIn: parent
            width: control.size
            height: control.size
            scale: control._down && !Theme.reduceMotion ? Theme.squishScale : 1
            Behavior on scale {
                enabled: !Theme.reduceMotion
                SpringAnimation {
                    spring: Theme.snappySpring; damping: Theme.snappyDamping
                    mass: Theme.snappyMass; epsilon: 0.0005
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                antialiasing: true
                color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
                border.width: 1
                border.color: Theme.glassBorder
            }
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                antialiasing: true
                color: control._fill
                scale: control.checked || Theme.reduceMotion ? 1 : 0
                opacity: control.checked ? 1 : 0
                visible: opacity > 0
                Behavior on scale {
                    enabled: !Theme.reduceMotion
                    SpringAnimation {
                        spring: Theme.liquidSpring; damping: Theme.liquidDamping
                        mass: Theme.liquidMass; epsilon: 0.002
                    }
                }
                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.dur(Theme.durSmall)
                        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                    }
                }
            }
            Rectangle {
                id: overlay
                anchors.fill: parent
                radius: width / 2
                antialiasing: true
                color: control._down ? Theme.pressedOverlay : control._hover ? Theme.hoverOverlay : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }

                FocusRing { show: control.visualFocus }
            }

            Icon {
                anchors.centerIn: parent
                name: control.iconName
                size: control._iconSize
                color: Theme.text
                opacity: control.checked ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }
            }
            Icon {
                anchors.centerIn: parent
                name: control.checkedIconName !== "" ? control.checkedIconName : control.iconName
                size: control._iconSize
                color: control._on
                opacity: control.checked ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }
            }

            Loader {
                anchors.fill: parent
                active: control.busy
                sourceComponent: Shape {
                    preferredRendererType: Shape.CurveRenderer
                    antialiasing: true
                    Accessible.role: Accessible.Animation
                    Accessible.name: qsTr("Working…")

                    ShapePath {
                        strokeColor: control.checked ? control._on : Theme.focusRing
                        strokeWidth: 2
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        PathAngleArc {
                            centerX: control.size / 2
                            centerY: control.size / 2
                            radiusX: control.size / 2 - 3
                            radiusY: radiusX
                            startAngle: -90
                            sweepAngle: 90
                        }
                    }
                    RotationAnimator on rotation {
                        from: 0; to: 360
                        duration: Theme.reduceMotion ? 1800 : 900
                        loops: Animation.Infinite
                        running: control.busy && control.visible
                    }
                }
            }
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        pressAndHoldInterval: 500
        onPressed: control.forceActiveFocus(Qt.MouseFocusReason)
        onPressAndHold: mouse => {
            if (control.hasDetail && mouse.button === Qt.LeftButton)
                control.detailRequested();
        }
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
                if (control.hasDetail) control.detailRequested();
            } else if (!(mouse.wasHeld && control.hasDetail)) {
                control._toggle();
            }
        }
    }

    // Detail tick: a 14 px chevron badge hanging off the bottom-right, with a
    // 22 px hit area of its own.
    MouseArea {
        id: tick
        visible: control.hasDetail
        enabled: control.enabled
        width: 22
        height: 22
        x: (control.width + control.size) / 2 - 16
        y: (control.height + control.size) / 2 - 16
        hoverEnabled: true
        onClicked: control.detailRequested()
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("%1 details").arg(control.label)
        Accessible.onPressAction: control.detailRequested()

        Rectangle {
            anchors.centerIn: parent
            width: 14
            height: 14
            radius: 7
            antialiasing: true
            color: tick.pressed ? Theme.surface3 : tick.containsMouse ? Theme.surface2 : Theme.surface
            border.width: 1
            border.color: Theme.border

            Icon {
                anchors.centerIn: parent
                name: "chevron-right"
                size: 10
                color: tick.containsMouse ? Theme.text : Theme.textMuted
            }
        }
    }

    Tooltip {
        text: control.label + (control.stateText !== "" ? ", " + control.stateText : "")
        visible: text !== "" && !area.pressed
                 && (area.containsMouse || tick.containsMouse || control.visualFocus)
    }
}

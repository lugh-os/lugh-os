// On/off switch.
//
//   Toggle { checked: wifi.on; onToggled: wifi.on = checked }
//   Toggle { text: qsTr("Do not disturb"); checked: dnd }   // label left, fills the row
//
// Pill track; on = accent fill, knob slides right and shows a check glyph
// (state is never color alone). Knob has a soft static shadow (a slightly
// larger translucent circle below it, no offscreen pass).
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T

T.Switch {
    id: control

    // Screen-reader name; empty = derived from the visible label.
    property string accessibleName: ""
    property string disabledReason: ""

    readonly property int _trackW: 40
    readonly property int _trackH: 24
    readonly property int _knob: 18
    readonly property int _inset: (_trackH - _knob) / 2

    implicitWidth: text !== "" ? Math.max(implicitContentWidth + spacing + _trackW, 160) : _trackW
    implicitHeight: Math.max(Theme.hitTarget, implicitContentHeight)
    Layout.fillWidth: text !== ""

    padding: 0
    spacing: Theme.space12
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    font: Theme.typeBody
    opacity: enabled ? 1 : Theme.disabledOpacity

    Accessible.role: Accessible.CheckBox
    Accessible.name: accessibleName !== "" ? accessibleName : text
    Accessible.checkable: true
    Accessible.checked: checked
    Accessible.description: !enabled ? disabledReason : ""

    indicator: Item {
        id: ind
        x: control.width - width
        y: (control.height - height) / 2
        width: control._trackW
        height: control._trackH

        Rectangle {
            id: track
            anchors.fill: parent
            radius: height / 2
            antialiasing: true
            // off: a neutral that keeps 3:1 against bg/surface (WCAG 1.4.11)
            readonly property color _off: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.24 : 0.20)
            readonly property color _base: control.checked ? Theme.accent : _off
            color: control.enabled && control.down ? Qt.tint(_base, Theme.pressedOverlay)
                 : control.enabled && control.hovered ? Qt.tint(_base, Theme.hoverOverlay) : _base
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durSmall) } }
            // The off fill alone is ~1.5:1 on surface; the hairline carries
            // the 3:1 non-text contrast (textMuted is > 6:1 on bg/surface).
            border.width: control.checked ? 0 : 1
            border.color: Theme.textMuted

            FocusRing { show: control.visualFocus }
        }

        Item {
            id: knob
            width: control._knob
            height: control._knob
            y: control._inset
            x: control._inset + control.visualPosition * (ind.width - width - 2 * control._inset)
            Behavior on x {
                enabled: !Theme.reduceMotion && !control.pressed
                SpringAnimation {
                    spring: Theme.springSpring
                    damping: Theme.springDamping
                    epsilon: Theme.springEpsilon
                }
            }

            // shadow: soft halo + a tighter contact shadow, both static
            Rectangle {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 1
                width: parent.width + 2
                height: width
                radius: width / 2
                color: Theme.shadowColor
                opacity: 0.35
                antialiasing: true
            }
            Rectangle {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 0.5
                width: parent.width + 0.5
                height: width
                radius: width / 2
                color: Theme.shadowColor
                opacity: 0.5
                antialiasing: true
            }
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                // white knob in light; warm off-white in dark (reads on both tracks)
                color: Theme.dark ? Theme.text : Theme.surface
                antialiasing: true
                scale: control.down && control.enabled && !Theme.reduceMotion ? 0.92 : 1
                Behavior on scale { NumberAnimation { duration: Theme.durMicro } }

                Icon {
                    anchors.centerIn: parent
                    name: "check"
                    size: 12
                    color: Theme.dark ? Theme.onAccent : Theme.accentText
                    opacity: control.checked ? 1 : 0
                    scale: control.checked || Theme.reduceMotion ? 1 : 0.6
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }
                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.durSmall
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Theme.easeStandard
                        }
                    }
                }
            }
        }
    }

    contentItem: Text {
        visible: control.text !== ""
        leftPadding: 0
        rightPadding: control.indicator.width + control.spacing
        text: control.text
        font: control.font
        color: Theme.text
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
    }

    HoverHandler { id: _hover }
    Tooltip {
        text: control.disabledReason
        visible: !control.enabled && control.disabledReason !== "" && _hover.hovered
    }
}

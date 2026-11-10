// Small selectable capsule (audio outputs, power profiles).
//
//   Chip { text: qsTr("Speakers"); iconName: "speaker"; selected: out === "spk"
//          onClicked: out = "spk" }
//
// 28 px capsule in a 32 px hit target. selected = accent tint + accent text +
// a check (replacing the icon, or leading when there is none), so it is never
// color alone. Hover/press overlays, squish on press, FocusRing, dimmed when
// disabled. The chip does not select itself: set `selected` from your state.
import QtQuick
import QtQuick.Templates as T

T.Button {
    id: control

    property string iconName: ""
    property bool selected: false
    property string size: "md"

    readonly property bool _lead: selected || iconName !== ""
    // The label stays Theme.text when selected: accentText on the selected tint
    // over glass drops below AA. Selection shows through the tint, border and check.
    readonly property color _fg: Theme.text

    implicitWidth: implicitContentWidth + leftPadding + rightPadding
    implicitHeight: Theme.hitTarget
    topInset: (implicitHeight - 28) / 2
    bottomInset: topInset
    leftPadding: _lead ? 10 : Theme.space12
    rightPadding: Theme.space12
    spacing: 6
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    font: Theme.typeLabel
    opacity: enabled ? 1 : Theme.disabledOpacity

    scale: down && enabled && !Theme.reduceMotion ? Theme.squishScale : 1
    Behavior on scale {
        enabled: !Theme.reduceMotion
        SpringAnimation {
            spring: Theme.snappySpring; damping: Theme.snappyDamping
            mass: Theme.snappyMass; epsilon: 0.0005
        }
    }

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.checkable: true
    Accessible.checked: selected

    background: Rectangle {
        implicitHeight: 28
        radius: height / 2
        antialiasing: true
        color: control.selected ? Theme.selectedBg
                                : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.08)
        border.width: 1
        border.color: control.selected ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
                                       : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.14)
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            antialiasing: true
            color: !control.enabled ? "transparent"
                 : control.down ? Theme.pressedOverlay
                 : control.hovered ? Theme.hoverOverlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.durMicro } }
        }
        FocusRing { show: control.visualFocus }
    }

    contentItem: Item {
        id: body
        implicitWidth: (control._lead ? 14 + control.spacing : 0) + label.implicitWidth
        implicitHeight: row.implicitHeight

        Row {
            id: row
            anchors.centerIn: parent
            spacing: control.spacing

            Icon {
                visible: control._lead
                anchors.verticalCenter: parent.verticalCenter
                name: control.selected ? "check" : control.iconName
                size: 14
                color: control.selected ? Theme.accentText : Theme.textMuted
            }
            Text {
                id: label
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, Math.max(0, body.width - (control._lead ? 14 + control.spacing : 0)))
                text: control.text
                font: control.font
                color: control._fg
                elide: Text.ElideRight
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }
            }
        }
    }
}

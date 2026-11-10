// One 36 px row in a control-center drawer: icon, name, and at the right a
// muted detail, a spinner while `busy`, a check when `selected` (never color
// alone) or a `trailingIcon`. Click, Space or Enter emit clicked().
import QtQuick
import QtQuick.Templates as T
import Lugh.UI

T.AbstractButton {
    id: control

    property string iconName: ""
    property string detail: ""
    property bool selected: false
    property bool busy: false
    property string trailingIcon: ""
    property bool danger: false

    readonly property color _fg: danger ? Theme.danger : selected ? Theme.accentText : Theme.text

    implicitWidth: 240
    implicitHeight: 36
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.disabledOpacity

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    Accessible.role: Accessible.Button
    Accessible.name: text + (detail !== "" ? ", " + detail : "") + (busy ? ", " + qsTr("working") : "")

    background: Rectangle {
        radius: Theme.radiusMd - 2
        antialiasing: true
        color: !control.enabled ? "transparent"
             : control.down ? Theme.pressedOverlay
             : control.hovered ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
        FocusRing { show: control.visualFocus }
    }

    contentItem: Item {
        Icon {
            id: lead
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            visible: control.iconName !== ""
            name: control.iconName
            size: 16
            color: control.danger ? Theme.danger : control.selected ? Theme.accentText : Theme.textMuted
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: lead.visible ? 36 : 10
            anchors.right: tail.left
            anchors.rightMargin: Theme.space8
            anchors.verticalCenter: parent.verticalCenter
            text: control.text
            font: Theme.typeLabel
            color: control._fg
            elide: Text.ElideRight
        }
        Row {
            id: tail
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: control.detail !== "" && !control.busy
                text: control.detail
                font: Theme.typeCaptionTnum
                color: Theme.textMuted
            }
            Spinner {
                anchors.verticalCenter: parent.verticalCenter
                visible: control.busy
                running: visible
                size: 14
            }
            Icon {
                anchors.verticalCenter: parent.verticalCenter
                visible: !control.busy && (control.selected || control.trailingIcon !== "")
                name: control.selected ? "check" : control.trailingIcon
                size: 14
                color: control.selected ? Theme.accentText : Theme.textMuted
            }
        }
    }
}

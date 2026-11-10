// Inline error (DESIGN-SYSTEM §7): danger icon, plain-language cause and a
// recovery action. Tinted danger at 10% with a 40% danger hairline.
//
//   ErrorBanner {
//       width: parent.width
//       text: qsTr("Couldn’t reach the update server. Check your connection.")
//       actionText: qsTr("Try again")
//       onAction: updates.refresh()
//       onDismissed: visible = false
//   }
//
// Dismissing only emits dismissed(); the owner decides whether to hide it.
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property string text: ""
    property string actionText: ""
    property bool dismissible: true

    signal action()
    signal dismissed()

    implicitWidth: row.implicitWidth + row.anchors.leftMargin + row.anchors.rightMargin
    implicitHeight: Math.max(44, row.implicitHeight + 2 * Theme.space8)

    radius: Theme.radiusMd
    color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.10)
    border.width: 1
    border.color: Qt.rgba(Theme.danger.r, Theme.danger.g, Theme.danger.b, 0.40)
    antialiasing: true

    Accessible.role: Accessible.AlertMessage
    Accessible.name: text

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: Theme.space12
        anchors.rightMargin: root.dismissible ? Theme.space4 : (root.actionText !== "" ? Theme.space8 : Theme.space12)
        anchors.topMargin: Theme.space8
        anchors.bottomMargin: Theme.space8
        spacing: Theme.space8

        Icon {
            Layout.alignment: message.lineCount > 1 ? Qt.AlignTop : Qt.AlignVCenter
            Layout.topMargin: message.lineCount > 1 ? 1 : 0
            name: "circle-alert"
            size: 18
            color: Theme.danger
        }

        Text {
            id: message
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: root.text
            font: Theme.typeBody
            // Wrapped text gets the body line height. Decided from the measured
            // single-line width, not lineCount (that would be a binding loop).
            lineHeight: messageMetrics.advanceWidth > width + 0.5 ? Theme.lineBody : 1
            color: Theme.text
            wrapMode: Text.Wrap
            textFormat: Text.PlainText

            TextMetrics {
                id: messageMetrics
                font: message.font
                text: message.text
            }
        }

        Button {
            Layout.alignment: Qt.AlignVCenter
            visible: root.actionText !== ""
            text: root.actionText
            variant: "ghost"
            size: "sm"
            onClicked: root.action()
        }

        IconButton {
            Layout.alignment: Qt.AlignVCenter
            visible: root.dismissible
            iconName: "x"
            tooltip: qsTr("Dismiss")
            size: 32
            iconSize: 16
            onClicked: root.dismissed()
        }
    }
}

// Empty state (DESIGN-SYSTEM §7): illustration-free message plus one primary
// action, centered, at most 320 px wide.
//
//   EmptyState {
//       anchors.centerIn: parent
//       iconName: "package"
//       title: qsTr("No bottles yet")
//       body: qsTr("Windows apps you install get their own bottle.")
//       actionText: qsTr("Install a Windows app")
//       onAction: installer.open()
//   }
import QtQuick
import QtQuick.Layouts

Item {
    id: root

    property string iconName: ""
    property string title: ""
    property string body: ""
    property string actionText: ""

    signal action()

    implicitWidth: Math.min(320, Math.max(column.implicitWidth, 1))
    implicitHeight: column.implicitHeight

    Accessible.role: Accessible.Grouping
    Accessible.name: title
    Accessible.description: body

    ColumnLayout {
        id: column
        width: Math.min(320, root.width)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: Theme.space16
            visible: root.iconName !== ""
            implicitWidth: 48
            implicitHeight: 48
            radius: width / 2
            color: Theme.surface2

            Icon {
                anchors.centerIn: parent
                name: root.iconName
                size: 24
                color: Theme.textMuted
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.maximumWidth: 320
            visible: text !== ""
            text: root.title
            font: Theme.typeTitle3
            lineHeight: lineCount > 1 ? Theme.lineHeading : 1
            color: Theme.text
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Text {
            Layout.fillWidth: true
            Layout.maximumWidth: 320
            Layout.topMargin: Theme.space8
            visible: text !== ""
            text: root.body
            font: Theme.typeBody
            lineHeight: lineCount > 1 ? Theme.lineBody : 1
            color: Theme.textMuted
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }

        Button {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.space20
            visible: root.actionText !== ""
            text: root.actionText
            variant: "primary"
            onClicked: root.action()
        }
    }
}

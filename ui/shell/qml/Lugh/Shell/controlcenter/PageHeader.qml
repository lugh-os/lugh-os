// Sub-page header: back chevron, title, then any trailing items (a Toggle,
// a rescan button…) placed as children.
//
//   PageHeader { title: qsTr("Wi-Fi"); onBack: cc.back(); Toggle { … } }
import QtQuick
import QtQuick.Layouts
import Lugh.UI

RowLayout {
    id: root

    property string title: ""
    readonly property Item backButton: back
    default property alias trailing: tail.data

    signal backRequested()

    spacing: Theme.space4
    implicitHeight: 40

    IconButton {
        id: back
        iconName: "chevron-left"
        tooltip: qsTr("Back")
        size: 32
        iconSize: 18
        onClicked: root.backRequested()
        Layout.alignment: Qt.AlignVCenter
    }

    Text {
        text: root.title
        font: Theme.typeTitle3
        color: Theme.text
        elide: Text.ElideRight
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    RowLayout {
        id: tail
        spacing: Theme.space8
        Layout.alignment: Qt.AlignVCenter
        Layout.rightMargin: Theme.space4
    }
}

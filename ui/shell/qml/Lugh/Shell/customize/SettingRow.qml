// One setting in a Customize group: title, a one-line description, and the
// control on the right (or below, when `stacked` or the row is narrow).
//
//   SettingRow { title: qsTr("Height"); description: qsTr("…"); keywords: "size"
//                Slider { … } }
//
// Children go into the control slot (a RowLayout). The row hides itself when
// the panel's search query (the `customizeQuery` of an ancestor) does not
// match its title, description, keywords or section. `clickable` rows (the
// toggle rows) emit rowClicked() when the text part is clicked. A hairline
// separates it from the row above (none on the first visible row).
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import "util.js" as U

Item {
    id: row

    property string title: ""
    property string description: ""
    property string keywords: ""
    property string iconName: ""      // optional leading symbol
    property bool stacked: false
    property bool clickable: false
    default property alias control: slot.data

    signal rowClicked()

    readonly property Item _ctx: U.ancestor(row.parent, "customizeQuery")
    readonly property Item _page: U.ancestor(row.parent, "pageTitle")
    readonly property bool matches: U.match(_ctx ? _ctx.customizeQuery : "",
        title + " " + description + " " + keywords + " " + (_page ? _page.pageTitle : ""))
    // Stacked when asked, when narrow, or when the control would leave the
    // text less than 40 % of the row (long translations, wide segments).
    readonly property bool _stack: stacked || width < 440 || slot.implicitWidth > (width - 2 * Theme.space16) * 0.6

    visible: matches
    width: parent ? parent.width : implicitWidth
    implicitWidth: 360
    implicitHeight: Math.max(56, grid.implicitHeight + 2 * Theme.space12)
    opacity: enabled ? 1 : Theme.disabledOpacity

    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: Theme.radiusMd - 2
        color: area.pressed ? Theme.pressedOverlay : Theme.hoverOverlay
        opacity: row.clickable && row.enabled && area.containsMouse ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
    }
    Rectangle {
        visible: row.y > 0
        x: Theme.space12
        width: parent.width - 2 * Theme.space12
        height: 1
        color: Theme.glassBorder
    }

    MouseArea {
        id: area
        anchors.fill: parent
        enabled: row.clickable && row.enabled
        hoverEnabled: true
        cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: row.rowClicked()
    }

    GridLayout {
        id: grid
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.space16
        anchors.rightMargin: Theme.space16
        anchors.verticalCenter: parent.verticalCenter
        columns: row._stack ? 1 : 2
        columnSpacing: Theme.space16
        rowSpacing: Theme.space12

        RowLayout {
            spacing: Theme.space12
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter

            Icon {
                visible: row.iconName !== ""
                name: row.iconName
                size: 18
                color: Theme.textMuted
                Layout.alignment: Qt.AlignVCenter
            }

            ColumnLayout {
                spacing: 2
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter

                Text {
                    text: row.title
                    font: Theme.typeBody
                    color: Theme.text
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    Layout.fillWidth: true
                }
                Text {
                    visible: row.description !== ""
                    text: row.description
                    font: Theme.typeCaption
                    color: Theme.textMuted
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    lineHeight: 1.15
                    Layout.fillWidth: true
                }
            }
        }

        RowLayout {
            id: slot
            spacing: Theme.space8
            Layout.alignment: row._stack ? Qt.AlignLeft | Qt.AlignVCenter : Qt.AlignRight | Qt.AlignVCenter
            Layout.fillWidth: row._stack
        }
    }
}

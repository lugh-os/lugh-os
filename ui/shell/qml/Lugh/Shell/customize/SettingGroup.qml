// A titled card of SettingRows. Hidden when no row matches the search.
//
//   SettingGroup { title: qsTr("Layout"); ToggleRow { … } SliderRow { … } }
//
// `count` = rows currently matching (the page sums them for the results).
import QtQuick
import QtQuick.Layouts
import Lugh.UI

ColumnLayout {
    id: group

    property string title: ""
    property string footnote: ""
    default property alias rows: list.data

    readonly property int count: {
        let n = 0;
        for (let i = 0; i < list.children.length; ++i)
            if (list.children[i].matches === true) ++n;
        return n;
    }

    visible: count > 0
    spacing: Theme.space8
    Layout.fillWidth: true

    Text {
        visible: group.title !== ""
        text: group.title
        font: Theme.typeBodyStrong
        color: Theme.text
        elide: Text.ElideRight
        Layout.fillWidth: true
        Layout.leftMargin: Theme.space4
        Accessible.role: Accessible.Heading
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: list.implicitHeight + 2 * Theme.space4
        radius: Theme.radiusMd + 2
        color: Theme.dark ? Qt.rgba(1, 1, 1, 0.035) : Qt.rgba(1, 1, 1, 0.55)
        border.width: 1
        border.color: Theme.glassBorder

        Column {
            id: list
            x: Theme.space4
            y: Theme.space4
            width: parent.width - 2 * Theme.space4
        }
    }

    Text {
        visible: group.footnote !== ""
        text: group.footnote
        font: Theme.typeCaption
        color: Theme.textMuted
        wrapMode: Text.Wrap
        Layout.fillWidth: true
        Layout.leftMargin: Theme.space4
    }
}

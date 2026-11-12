// One section of the Customize panel. Shows alone when it is the current
// page; while searching, every page with matching rows shows, under a small
// section label.
//
//   CustomizePage { key: "panel"; pageTitle: qsTr("Panel"); iconName: "panel-bottom"
//                   SettingGroup { … } }
import QtQuick
import QtQuick.Layouts
import Lugh.UI

ColumnLayout {
    id: page

    property string key: ""
    property string pageTitle: ""
    property string iconName: ""
    property bool current: false
    property bool searching: false
    default property alias content: body.data

    readonly property int count: {
        let n = 0;
        for (let i = 0; i < body.children.length; ++i) {
            const c = body.children[i].count;
            if (typeof c === "number") n += c;
        }
        return n;
    }

    visible: searching ? count > 0 : current
    spacing: Theme.space12
    Layout.fillWidth: true

    RowLayout {
        visible: page.searching
        spacing: Theme.space8
        Layout.topMargin: Theme.space4
        Icon { name: page.iconName; size: 16; color: Theme.accentText }
        Text {
            text: page.pageTitle
            font: Theme.typeLabel
            color: Theme.accentText
            Accessible.role: Accessible.Heading
        }
    }

    ColumnLayout {
        id: body
        spacing: Theme.space24
        Layout.fillWidth: true
    }
}

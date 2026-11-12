// A SettingRow with a SegmentedControl over a few values.
//
//   ChoiceRow { title: qsTr("Style"); value: ShellSettings.panelFloating
//               options: [{ text: qsTr("Floating"), value: true }, { text: qsTr("Edge to edge"), value: false }]
//               onEdited: v => ShellSettings.panelFloating = v }
import QtQuick
import QtQuick.Layouts
import Lugh.UI

SettingRow {
    id: r

    property var options: []        // [{ text, iconName?, value }]
    property var value
    signal edited(var value)

    function _index() {
        for (let i = 0; i < options.length; ++i)
            if (options[i].value === value) return i;
        return -1;
    }

    SegmentedControl {
        id: seg
        model: r.options.map(o => ({ text: o.text, iconName: o.iconName || "" }))
        currentIndex: r._index()
        Layout.fillWidth: r._stack
        accessibleName: r.title
        onActivated: i => {
            r.edited(r.options[i].value);
            currentIndex = Qt.binding(() => r._index());
        }
    }
}

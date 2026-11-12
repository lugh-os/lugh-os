// A SettingRow with a Toggle. Clicking anywhere on the row flips it.
//
//   ToggleRow { title: qsTr("Auto-hide"); checked: ShellSettings.panelAutohide
//               onEdited: v => ShellSettings.panelAutohide = v }
import QtQuick
import Lugh.UI

SettingRow {
    id: r

    property bool checked: false
    property string disabledReason: ""
    signal edited(bool value)

    clickable: true
    onRowClicked: edited(!checked)

    Toggle {
        id: sw
        checked: r.checked
        disabledReason: r.disabledReason
        accessibleName: r.title
        Accessible.description: r.enabled ? r.description : r.disabledReason
        onToggled: {
            r.edited(checked);
            checked = Qt.binding(() => r.checked);
        }
    }
}

// Edits an ordered selection of ids (quick toggles, title-bar buttons): the
// chosen ones in order, each with move up / move down / remove, then the
// unused ones as chips to add. Never mutates `items`: emits edited(newArray).
//
//   OrderedList { items: ShellSettings.quickToggles; catalog: U.quickToggles
//                 allIds: U.quickToggleIds; onEdited: a => ShellSettings.quickToggles = a }
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import "util.js" as U

ColumnLayout {
    id: root

    property var items: []
    property var catalog: ({})          // id → { name, icon }; name is a QT_TRANSLATE_NOOP key (util.js)
    property var allIds: []             // every known id, in the order chips are offered
    property var locked: []             // ids that can't be removed
    property string lockedReason: ""
    property string emptyText: qsTr("Nothing here yet. Add some below.")
    property string addLabel: qsTr("Add")
    signal edited(var items)

    readonly property var available: allIds.filter(id => items.indexOf(id) < 0)

    // Rows are rebuilt when the array changes; keep keyboard focus on the
    // control that was used ("up" | "down" | "remove" | "add").
    property int _focusIndex: -1
    property string _focusWhich: ""

    function _name(id) { return U.name(catalog, id); }
    function _icon(id) { return catalog[id] ? catalog[id].icon : "circle"; }
    function _move(i, d) {
        const a = items.slice(), t = a[i];
        a[i] = a[i + d]; a[i + d] = t;
        _focusIndex = i + d;
        _focusWhich = (d < 0 && i + d === 0) ? "down" : (d > 0 && i + d === a.length - 1) ? "up" : (d < 0 ? "up" : "down");
        edited(a);
    }
    function _remove(i) {
        const a = items.slice();
        a.splice(i, 1);
        _focusIndex = Math.min(i, a.length - 1);
        _focusWhich = "remove";
        edited(a);
    }
    function _add(id) {
        _focusIndex = -1;
        _focusWhich = "add";
        edited(items.concat([id]));
    }

    spacing: Theme.space8
    Layout.fillWidth: true

    Text {
        visible: root.items.length === 0
        text: root.emptyText
        font: Theme.typeCaption
        color: Theme.textMuted
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }

    Column {
        Layout.fillWidth: true
        visible: root.items.length > 0
        spacing: 2

        Repeater {
            model: root.items

            Rectangle {
                id: entry
                required property string modelData
                required property int index
                readonly property bool isLocked: root.locked.indexOf(modelData) >= 0
                width: parent.width
                height: 40
                radius: Theme.radiusSm + 2
                color: hov.hovered ? Theme.hoverOverlay : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }
                Accessible.role: Accessible.ListItem
                Accessible.name: qsTr("%1, position %2 of %3").arg(root._name(modelData)).arg(index + 1).arg(root.items.length)

                HoverHandler { id: hov }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space8
                    anchors.rightMargin: Theme.space4
                    spacing: Theme.space12

                    Text {
                        text: entry.index + 1
                        font: Theme.typeCaptionTnum
                        color: Theme.textMuted
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: 14
                    }
                    Rectangle {
                        implicitWidth: 28; implicitHeight: 28
                        radius: 14
                        color: Theme.selectedBg
                        Icon { anchors.centerIn: parent; name: root._icon(entry.modelData); size: 15; color: Theme.accentText }
                    }
                    Text {
                        text: root._name(entry.modelData)
                        font: Theme.typeBody
                        color: Theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    IconButton {
                        id: upBtn
                        iconName: "arrow-up"
                        tooltip: qsTr("Move %1 up").arg(root._name(entry.modelData))
                        enabled: entry.index > 0
                        onClicked: root._move(entry.index, -1)
                    }
                    IconButton {
                        id: downBtn
                        iconName: "arrow-down"
                        tooltip: qsTr("Move %1 down").arg(root._name(entry.modelData))
                        enabled: entry.index < root.items.length - 1
                        onClicked: root._move(entry.index, 1)
                    }
                    IconButton {
                        id: removeBtn
                        iconName: "x"
                        tooltip: entry.isLocked ? root.lockedReason : qsTr("Remove %1").arg(root._name(entry.modelData))
                        enabled: !entry.isLocked
                        onClicked: root._remove(entry.index)
                    }
                }

                Component.onCompleted: {
                    if (entry.index !== root._focusIndex) return;
                    const b = root._focusWhich === "up" ? upBtn : root._focusWhich === "down" ? downBtn
                            : root._focusWhich === "remove" ? removeBtn : null;
                    if (b && b.enabled) b.forceActiveFocus(Qt.TabFocusReason);
                    root._focusIndex = -1;
                }
            }
        }
    }

    Text {
        visible: root.available.length > 0
        text: root.addLabel
        font: Theme.typeCaption
        color: Theme.textMuted
        Layout.topMargin: Theme.space4
    }
    Flow {
        id: chips
        visible: root.available.length > 0
        spacing: Theme.space8
        Layout.fillWidth: true

        Repeater {
            model: root.available
            Chip {
                required property string modelData
                required property int index
                text: root._name(modelData)
                iconName: "plus"
                accessibleName: qsTr("Add %1").arg(text)
                onClicked: root._add(modelData)
                Component.onCompleted: {
                    if (root._focusWhich === "add" && index === 0) {
                        forceActiveFocus(Qt.TabFocusReason);
                        root._focusWhich = "";
                    }
                }
            }
        }
    }
}

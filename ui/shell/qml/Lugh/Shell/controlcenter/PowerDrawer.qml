// Control center › power-profile drawer: one chip per available profile.
import QtQuick
import Lugh.UI
import Lugh.Shell

Drawer {
    id: drawer

    property var cc
    readonly property var power: Services.power

    expanded: cc.drawer === "power"

    function focusFirst(viaKeyboard) {
        if (loader.item) loader.item.focusFirst(viaKeyboard);
    }
    function name(p) {
        return p === "power-saver" ? qsTr("Saver") : p === "performance" ? qsTr("Performance")
             : p === "balanced" ? qsTr("Balanced") : p;
    }

    Loader {
        id: loader
        width: parent.width
        active: drawer.loaded
        sourceComponent: DrawerWell {
            function focusFirst(viaKeyboard) {
                for (let i = 0; i < chips.count; ++i) {
                    const c = chips.itemAt(i);
                    if (c && (c.selected || i === chips.count - 1)) {
                        c.forceActiveFocus(viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason);
                        return;
                    }
                }
            }

            Flow {
                id: flow
                width: parent.width
                spacing: 6

                Repeater {
                    id: chips
                    model: drawer.power.profiles
                    Chip {
                        required property string modelData
                        width: Math.min(implicitWidth, flow.width)
                        text: drawer.name(modelData)
                        selected: drawer.power.profile === modelData
                        Accessible.name: modelData === "power-saver" ? qsTr("Power saver") : text
                        onClicked: drawer.power.setProfile(modelData)
                    }
                }
            }
        }
    }
}

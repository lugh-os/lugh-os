// Control center › Bluetooth drawer: switch + paired devices (click toggles
// the connection). Content is created on first expand.
import QtQuick
import Lugh.UI
import Lugh.Shell

Drawer {
    id: drawer

    property var cc
    readonly property var bt: Services.bluetooth
    readonly property bool on: bt.available && bt.enabled

    expanded: cc.drawer === "bluetooth"

    function focusFirst(viaKeyboard) { if (loader.item) loader.item.focusFirst(viaKeyboard); }

    Loader {
        id: loader
        width: parent.width
        active: drawer.loaded
        sourceComponent: DrawerWell {
            id: well
            active: drawer.expanded

            function focusFirst(viaKeyboard) {
                const reason = viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason;
                if (list.visible) list.forceActiveFocus(reason);
                else power.forceActiveFocus(reason);
            }

            Column {
                width: parent.width

                Item {
                    width: parent.width
                    height: 32

                    Text {
                        x: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Bluetooth")
                        font: Theme.typeBodyStrong
                        color: Theme.text
                    }
                    Toggle {
                        id: power
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        checked: drawer.on
                        Accessible.name: qsTr("Bluetooth")
                        onToggled: {
                            drawer.bt.setEnabled(checked);
                            checked = Qt.binding(() => drawer.on);
                        }
                    }
                }

                DrawerNote {
                    visible: !drawer.on
                    width: parent.width
                    iconName: "bluetooth-off"
                    text: qsTr("Bluetooth is off")
                    actionText: qsTr("Turn on")
                    onAction: drawer.bt.setEnabled(true)
                }
                DrawerNote {
                    visible: drawer.on && list.count === 0
                    width: parent.width
                    iconName: "bluetooth"
                    text: qsTr("No paired devices")
                }

                ListView {
                    id: list
                    visible: drawer.on && count > 0
                    width: parent.width
                    height: Math.min(count, 6) * 36
                    interactive: count > 6
                    clip: interactive
                    boundsBehavior: Flickable.StopAtBounds
                    activeFocusOnTab: true
                    keyNavigationEnabled: true
                    highlightMoveDuration: 0
                    model: drawer.bt.devices
                    Accessible.role: Accessible.List
                    Accessible.name: qsTr("Bluetooth devices")

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            if (currentItem && !currentItem.busy) drawer.bt.toggleDevice(currentItem.address);
                            event.accepted = true;
                        }
                    }

                    delegate: DrawerRow {
                        id: d

                        required property int index
                        required property var model
                        readonly property string address: model.address
                        readonly property bool connected: model.connected
                        readonly property int battery: model.battery

                        width: ListView.view.width
                        focusPolicy: Qt.NoFocus
                        current: ListView.isCurrentItem && list.activeFocus
                        entering: well.entering
                        order: index
                        text: model.name
                        busy: model.busy
                        iconName: model.icon !== "" ? model.icon : "bluetooth"
                        selected: connected
                        detail: !connected ? "" : battery >= 0 ? qsTr("%1%").arg(battery) : qsTr("Connected")
                        onClicked: if (!busy) drawer.bt.toggleDevice(address)
                        Accessible.name: [model.name,
                                          busy ? qsTr("connecting") : connected ? qsTr("connected") : qsTr("not connected"),
                                          connected && battery >= 0 ? qsTr("battery %1 percent").arg(battery) : ""]
                                         .filter(s => s !== "").join(", ")
                    }
                }
            }
        }
    }
}

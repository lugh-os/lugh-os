// Control center › Bluetooth: power toggle and paired devices. Clicking a
// device connects or disconnects it (Services.bluetooth.toggleDevice).
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: page

    property Item cc
    property real maxHeight: 640

    readonly property QtObject bt: Services.bluetooth
    readonly property bool _on: bt.available && bt.enabled

    implicitWidth: 336
    implicitHeight: col.implicitHeight

    function focusFirst(viaKeyboard) {
        const r = viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason;
        if (page._on && list.count > 0) list.forceActiveFocus(r);
        else header.backButton.forceActiveFocus(r);
    }
    function activate(index) {
        const dev = bt.devices.get(index);
        if (!dev || dev.busy) return;
        list.currentIndex = index;
        bt.toggleDevice(dev.address);
    }

    ColumnLayout {
        id: col
        width: parent.width
        spacing: Theme.space8

        PageHeader {
            id: header
            Layout.fillWidth: true
            title: qsTr("Bluetooth")
            onBackRequested: page.cc.back()

            Toggle {
                checked: page.bt.enabled
                enabled: page.bt.available
                disabledReason: qsTr("No Bluetooth adapter")
                onToggled: page.bt.setEnabled(checked)
                Accessible.name: qsTr("Bluetooth")
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
        }

        Item {
            visible: !page._on || page.bt.devices.count === 0
            Layout.fillWidth: true
            implicitHeight: btState.implicitHeight + 2 * Theme.space24
            EmptyState {
                id: btState
                anchors.centerIn: parent
                width: Math.min(parent.width - 2 * Theme.space16, 280)
                iconName: "bluetooth-off"
                title: !page.bt.available ? qsTr("No Bluetooth adapter")
                     : !page.bt.enabled ? qsTr("Bluetooth is off") : qsTr("No paired devices")
                body: !page.bt.available ? qsTr("This computer has no Bluetooth radio.")
                    : !page.bt.enabled ? qsTr("Turn Bluetooth on to use headphones, keyboards and speakers.")
                    : qsTr("Pair new devices with bluetoothctl for now; pairing in Settings arrives in Phase 2.")
                actionText: page.bt.available && !page.bt.enabled ? qsTr("Turn on Bluetooth") : ""
                onAction: page.bt.setEnabled(true)
            }
        }

        Text {
            visible: list.visible
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.topMargin: Theme.space4
            text: qsTr("Paired devices")
            font: Theme.typeCaption
            color: Theme.textMuted
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        ListView {
            id: list
            visible: page._on && count > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, Math.max(120, page.maxHeight - header.implicitHeight - 48))
            interactive: contentHeight > height
            clip: interactive
            boundsBehavior: Flickable.StopAtBounds
            activeFocusOnTab: true
            keyNavigationEnabled: true
            model: page.bt.devices
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Paired devices")

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    page.activate(currentIndex);
                    event.accepted = true;
                }
            }

            delegate: ListRow {
                id: row
                required property int index
                required property string address
                required property string name
                required property var model   // "icon" clashes with AbstractButton.icon
                required property bool connected
                required property int battery
                required property bool busy

                width: ListView.view.width
                focusPolicy: Qt.NoFocus
                title: name
                iconName: model.icon !== "" ? model.icon : "bluetooth"
                subtitle: busy ? (connected ? qsTr("Disconnecting…") : qsTr("Connecting…"))
                        : connected ? (battery >= 0 ? qsTr("Connected · Battery %1%").arg(battery) : qsTr("Connected"))
                        : qsTr("Not connected")
                selected: connected
                trailing: busy ? spin : null
                onClicked: page.activate(index)
                Accessible.name: name + ", " + subtitle

                Component {
                    id: spin
                    Spinner { size: 14; running: true }
                }
            }
        }
    }
}

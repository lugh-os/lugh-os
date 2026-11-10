// Control center › Wi-Fi drawer: switch, network list (6 rows, then scroll),
// inline password + Connect, scanning skeletons, off / empty notes and an
// inline error with Retry. Content is created on first expand.
import QtQuick
import Lugh.UI
import Lugh.Shell
import "icons.js" as Icons

Drawer {
    id: drawer

    property var cc
    readonly property var net: Services.network
    readonly property bool on: net.wifiAvailable && net.wifiEnabled

    expanded: cc.drawer === "wifi"

    function focusFirst(viaKeyboard) { if (loader.item) loader.item.focusFirst(viaKeyboard); }

    function activate(index) {
        const n = net.networks.get(index);
        if (!n) return;
        const ssid = n.ssid;
        if (n.connected || (n.secure && !n.known)) {
            cc.wifiExpandedSsid = cc.wifiExpandedSsid === ssid ? "" : ssid;
            return;
        }
        if (net.connectingSsid !== "") return;
        connect(ssid, "");
    }
    function connect(ssid, password) {
        cc.wifiAttemptSsid = ssid;
        net.connectTo(ssid, password);
    }

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
                        text: qsTr("Wi-Fi")
                        font: Theme.typeBodyStrong
                        color: Theme.text
                    }
                    IconButton {
                        anchors.right: power.left
                        anchors.rightMargin: Theme.space4
                        anchors.verticalCenter: parent.verticalCenter
                        visible: drawer.on
                        enabled: !drawer.net.scanning
                        size: 28
                        iconSize: 14
                        iconName: "refresh-cw"
                        tooltip: drawer.net.scanning ? qsTr("Looking for networks…") : qsTr("Scan again")
                        onClicked: drawer.net.rescan()
                    }
                    Toggle {
                        id: power
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        enabled: drawer.net.wifiAvailable
                        checked: drawer.on
                        Accessible.name: qsTr("Wi-Fi")
                        onToggled: {
                            drawer.net.setWifiEnabled(checked);
                            checked = Qt.binding(() => drawer.on);
                        }
                    }
                }

                DrawerNote {
                    visible: !drawer.on
                    width: parent.width
                    iconName: drawer.net.airplaneMode ? "plane" : "wifi-off"
                    text: !drawer.net.wifiAvailable ? qsTr("No Wi-Fi adapter")
                        : drawer.net.airplaneMode ? qsTr("Airplane mode is on") : qsTr("Wi-Fi is off")
                    actionText: drawer.net.wifiAvailable ? qsTr("Turn on") : ""
                    onAction: {
                        if (drawer.net.airplaneMode) drawer.net.setAirplaneMode(false);
                        drawer.net.setWifiEnabled(true);
                    }
                }

                DrawerNote {
                    visible: drawer.on && list.count === 0 && !drawer.net.scanning
                    width: parent.width
                    iconName: "wifi-zero"
                    text: qsTr("No networks found")
                    actionText: qsTr("Scan again")
                    onAction: drawer.net.rescan()
                }

                // First scan: placeholders where the rows will be.
                Column {
                    visible: drawer.on && list.count === 0 && drawer.net.scanning
                    width: parent.width
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Looking for networks…")

                    Repeater {
                        model: 3
                        Item {
                            id: ghost
                            required property int index
                            width: parent.width
                            height: 40
                            Skeleton { x: 10; anchors.verticalCenter: parent.verticalCenter; width: 16; height: 16; radius: 8 }
                            Skeleton { x: 36; anchors.verticalCenter: parent.verticalCenter; width: [128, 92, 150][ghost.index]; height: 10 }
                        }
                    }
                }

                ListView {
                    id: list

                    // Extra height of the row that is open (password, error).
                    property real openExtra: 0

                    visible: drawer.on && count > 0
                    width: parent.width
                    height: Math.min(count, 6) * 40 + openExtra
                    interactive: contentHeight > height + 0.5
                    clip: interactive
                    boundsBehavior: Flickable.StopAtBounds
                    activeFocusOnTab: true
                    keyNavigationEnabled: true
                    highlightMoveDuration: 0
                    model: drawer.net.networks
                    Accessible.role: Accessible.List
                    Accessible.name: qsTr("Wi-Fi networks")

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            drawer.activate(currentIndex);
                            event.accepted = true;
                        }
                    }

                    delegate: FocusScope {
                        id: d

                        required property int index
                        required property string ssid
                        required property int strength
                        required property bool secure
                        required property bool known
                        required property bool connected

                        readonly property bool connecting: drawer.net.connectingSsid === ssid
                        readonly property bool failed: drawer.net.lastError !== "" && !connecting
                                                       && drawer.cc.wifiAttemptSsid === ssid
                        readonly property bool needsPassword: secure && !known && !connected
                        readonly property bool open: drawer.cc.wifiExpandedSsid === ssid || failed
                        readonly property bool wantsPassword: needsPassword || (failed && secure && !connected)

                        width: ListView.view.width
                        height: 40 + extra.height

                        onOpenChanged: {
                            if (open && wantsPassword) {
                                Qt.callLater(() => {
                                    if (!d.open) return;
                                    d.ListView.view.positionViewAtIndex(d.index, ListView.Contain);
                                    field.forceActiveFocus();
                                });
                            } else if (!open && field.activeFocus) {
                                row.forceActiveFocus(Qt.TabFocusReason);    // never leave focus in a hidden field
                            }
                        }
                        Binding { target: list; property: "openExtra"; value: extra.height; when: d.open }

                        DrawerRow {
                            id: row
                            width: parent.width
                            height: 40
                            focus: true
                            focusPolicy: Qt.NoFocus
                            current: d.ListView.isCurrentItem && list.activeFocus && !field.activeFocus
                            entering: well.entering
                            order: d.index
                            text: d.ssid
                            iconName: Icons.signal(d.strength)
                            selected: d.connected
                            busy: d.connecting
                            detail: d.connected ? qsTr("Connected") : ""
                            trailingIcon: d.secure ? "lock" : ""
                            onClicked: drawer.activate(d.index)
                            Accessible.name: [d.ssid,
                                              d.connected ? qsTr("connected") : d.connecting ? qsTr("connecting") : "",
                                              d.secure ? qsTr("secured") : qsTr("open"),
                                              qsTr("signal %1 percent").arg(d.strength)].filter(s => s !== "").join(", ")
                        }

                        // Inline: password + Connect, or Disconnect, plus the error.
                        Item {
                            id: extra
                            y: 40
                            width: parent.width
                            height: d.open ? more.height + Theme.space8 : 0
                            visible: d.open

                            Column {
                                id: more
                                x: 10
                                width: parent.width - 20
                                spacing: Theme.space8

                                Item {
                                    id: pass
                                    visible: d.wantsPassword
                                    width: parent.width
                                    height: field.implicitHeight

                                    TextField {
                                        id: field
                                        anchors.left: parent.left
                                        anchors.right: go.left
                                        anchors.rightMargin: Theme.space8
                                        password: true
                                        enabled: !d.connecting
                                        placeholderText: qsTr("Password")
                                        Accessible.name: qsTr("Password for %1").arg(d.ssid)
                                        onAccepted: if (text.length > 0) drawer.connect(d.ssid, text)
                                        Keys.onEscapePressed: event => {
                                            drawer.cc.wifiExpandedSsid = "";
                                            list.forceActiveFocus(Qt.TabFocusReason);
                                            event.accepted = true;
                                        }
                                        Keys.onUpPressed: event => { event.accepted = true; }
                                        Keys.onDownPressed: event => { event.accepted = true; }
                                    }
                                    Button {
                                        id: go
                                        anchors.right: parent.right
                                        text: qsTr("Connect")
                                        variant: "primary"
                                        loading: d.connecting
                                        enabled: field.length > 0
                                        disabledReason: qsTr("Enter the password first")
                                        onClicked: drawer.connect(d.ssid, field.text)
                                    }
                                }

                                Item {
                                    visible: d.connected && !d.failed
                                    width: parent.width
                                    height: 28

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: qsTr("Signal %1%").arg(d.strength)
                                        font: Theme.typeCaptionTnum
                                        color: Theme.textMuted
                                    }
                                    Button {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: qsTr("Disconnect")
                                        size: "sm"
                                        onClicked: { drawer.cc.wifiExpandedSsid = ""; drawer.net.disconnect(); }
                                    }
                                }

                                ErrorBanner {
                                    visible: d.failed
                                    width: parent.width
                                    text: drawer.net.lastError
                                    actionText: qsTr("Retry")
                                    dismissible: false
                                    onAction: {
                                        if (d.wantsPassword && field.length > 0) drawer.connect(d.ssid, field.text);
                                        else if (d.wantsPassword) { field.forceActiveFocus(); field.selectAll(); }
                                        else drawer.connect(d.ssid, "");
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

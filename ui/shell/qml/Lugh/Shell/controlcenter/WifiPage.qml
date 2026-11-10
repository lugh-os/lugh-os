// Control center › Wi-Fi: on/off, network list, inline password + connect,
// scanning shimmer, off/empty states and inline errors with Retry.
//
// Expansion and the last attempted network live on the ControlCenter
// (`wifiExpandedSsid`, `wifiAttemptSsid`) so they survive the page reloading.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell
import "icons.js" as Icons

FocusScope {
    id: page

    property Item cc
    // Tallest the page may get (the panel caps it to the screen); the list scrolls past it.
    property real maxHeight: 640

    readonly property QtObject net: Services.network
    readonly property bool _on: net.wifiAvailable && net.wifiEnabled
    readonly property bool _orphanError: net.lastError !== "" && (cc.wifiAttemptSsid === "" || !_hasNetwork(cc.wifiAttemptSsid))

    implicitWidth: 336
    implicitHeight: col.implicitHeight

    function focusFirst(viaKeyboard) {
        const r = viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason;
        if (page._on && list.count > 0) list.forceActiveFocus(r);
        else header.backButton.forceActiveFocus(r);
    }

    function _hasNetwork(ssid) {
        for (let i = 0; i < net.networks.count; ++i) if (net.networks.get(i).ssid === ssid) return true;
        return false;
    }

    // Row click / Enter.
    function activate(index) {
        const n = net.networks.get(index);
        if (!n || net.connectingSsid !== "") return;
        list.currentIndex = index;
        if (n.connected || (n.secure && !n.known)) {
            cc.wifiExpandedSsid = cc.wifiExpandedSsid === n.ssid ? "" : n.ssid;
        } else {
            cc.wifiExpandedSsid = "";
            connect(n.ssid, "");
        }
    }
    function connect(ssid, password) {
        cc.wifiAttemptSsid = ssid;
        net.connectTo(ssid, password);
    }

    ColumnLayout {
        id: col
        width: parent.width
        spacing: Theme.space8

        PageHeader {
            id: header
            Layout.fillWidth: true
            title: qsTr("Wi-Fi")
            onBackRequested: page.cc.back()

            Item {
                visible: page._on
                implicitWidth: 32
                implicitHeight: 32
                IconButton {
                    anchors.fill: parent
                    visible: !page.net.scanning
                    iconName: "refresh-cw"
                    iconSize: 16
                    tooltip: qsTr("Scan for networks")
                    onClicked: page.net.rescan()
                }
                Spinner {
                    anchors.centerIn: parent
                    visible: page.net.scanning
                    running: visible
                    size: 16
                    Accessible.role: Accessible.Animation
                    Accessible.name: qsTr("Scanning for networks")
                }
            }
            Toggle {
                checked: page.net.wifiEnabled
                enabled: page.net.wifiAvailable
                disabledReason: qsTr("No Wi-Fi adapter")
                onToggled: page.net.setWifiEnabled(checked)
                Accessible.name: qsTr("Wi-Fi")
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
        }

        // An error not tied to a listed network (e.g. it went out of range).
        ErrorBanner {
            visible: page._on && page._orphanError
            Layout.fillWidth: true
            text: page.net.lastError
            actionText: qsTr("Rescan")
            dismissible: false
            onAction: page.net.rescan()
        }

        // ---- off / unavailable -----------------------------------------------
        Item {
            visible: !page._on
            Layout.fillWidth: true
            implicitHeight: offState.implicitHeight + 2 * Theme.space24
            EmptyState {
                id: offState
                anchors.centerIn: parent
                width: Math.min(parent.width - 2 * Theme.space16, 280)
                iconName: "wifi-off"
                title: !page.net.wifiAvailable ? qsTr("No Wi-Fi adapter") : qsTr("Wi-Fi is off")
                body: !page.net.wifiAvailable ? qsTr("Plug in a Wi-Fi adapter or use a cable.")
                    : page.net.airplaneMode ? qsTr("Airplane mode is on. Turn Wi-Fi on to see networks nearby.")
                    : qsTr("Turn Wi-Fi on to see networks nearby.")
                actionText: page.net.wifiAvailable ? qsTr("Turn on Wi-Fi") : ""
                onAction: page.net.setWifiEnabled(true)
            }
        }

        // ---- empty -----------------------------------------------------------
        Item {
            visible: page._on && !page.net.scanning && page.net.networks.count === 0
            Layout.fillWidth: true
            implicitHeight: emptyState.implicitHeight + 2 * Theme.space24
            EmptyState {
                id: emptyState
                anchors.centerIn: parent
                width: Math.min(parent.width - 2 * Theme.space16, 280)
                iconName: "wifi-zero"
                title: qsTr("No networks found")
                body: qsTr("Move closer to a router, or scan again.")
                actionText: qsTr("Rescan")
                onAction: page.net.rescan()
            }
        }

        // ---- list ------------------------------------------------------------
        ListView {
            id: list
            visible: page._on && count > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, Math.max(120, page.maxHeight - header.implicitHeight - 64
                                                                    - (scanTail.visible ? scanTail.implicitHeight : 0)))
            interactive: contentHeight > height
            clip: interactive
            boundsBehavior: Flickable.StopAtBounds
            activeFocusOnTab: true
            keyNavigationEnabled: true
            spacing: 0
            model: page.net.networks
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Wi-Fi networks")

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    page.activate(currentIndex);
                    event.accepted = true;
                }
            }

            // A FocusScope so the current row's ListRow takes the list's focus
            // (and shows its keyboard focus ring) while the password field can
            // still take focus inside it.
            delegate: FocusScope {
                id: d
                required property int index
                required property string ssid
                required property int strength
                required property bool secure
                required property bool known
                required property bool connected

                readonly property bool expanded: page.cc.wifiExpandedSsid === ssid
                readonly property bool connecting: page.net.connectingSsid === ssid
                readonly property bool failed: page.net.lastError !== "" && page.cc.wifiAttemptSsid === ssid
                readonly property bool needsPassword: secure && !known && !connected
                readonly property bool open: expanded || failed

                width: ListView.view.width
                implicitHeight: rowCol.implicitHeight
                height: implicitHeight

                onOpenChanged: {
                    if (open && needsPassword)
                        Qt.callLater(() => { if (d.open) field.forceActiveFocus(); });
                    else if (!open && field.focus)
                        rowItem.forceActiveFocus(Qt.TabFocusReason);   // don't leave focus in a hidden field
                }

                Column {
                id: rowCol
                width: parent.width

                ListRow {
                    id: rowItem
                    width: parent.width
                    focus: true
                    focusPolicy: Qt.NoFocus
                    title: d.ssid
                    subtitle: d.connecting ? qsTr("Connecting…")
                        : d.connected ? qsTr("Connected")
                        : d.known ? qsTr("Saved")
                        : d.secure ? qsTr("Password required") : qsTr("Open network")
                    iconName: Icons.signal(d.strength)
                    selected: d.connected
                    trailing: d.secure || d.connecting ? trailingComp : null
                    onClicked: page.activate(d.index)
                    Accessible.name: [d.ssid,
                                      d.connected ? qsTr("connected") : d.connecting ? qsTr("connecting") : "",
                                      d.secure ? qsTr("secured") : qsTr("open"),
                                      qsTr("signal %1 percent").arg(d.strength)].filter(s => s !== "").join(", ")

                    Component {
                        id: trailingComp
                        Item {
                            implicitWidth: 16
                            implicitHeight: 16
                            Spinner { anchors.centerIn: parent; visible: d.connecting; running: visible; size: 14 }
                            Icon {
                                anchors.centerIn: parent
                                visible: !d.connecting
                                name: "lock"
                                size: 14
                                color: Theme.textMuted
                                Accessible.ignored: true
                            }
                        }
                    }
                }

                // Inline expansion: password + Connect, or Disconnect, plus errors.
                Item {
                    width: parent.width
                    height: d.open ? body.implicitHeight + Theme.space8 : 0
                    clip: true
                    visible: height > 0.5
                    Behavior on height {
                        NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                    }

                    ColumnLayout {
                        id: body
                        x: Theme.space12
                        y: Theme.space4
                        width: parent.width - 2 * Theme.space12
                        spacing: Theme.space8
                        opacity: d.open ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }

                        RowLayout {
                            visible: d.needsPassword || (d.failed && d.secure && !d.connected)
                            spacing: Theme.space8
                            Layout.fillWidth: true

                            TextField {
                                id: field
                                Layout.fillWidth: true
                                password: true
                                enabled: !d.connecting
                                placeholderText: qsTr("Password")
                                Accessible.name: qsTr("Password for %1").arg(d.ssid)
                                onAccepted: if (text.length > 0) page.connect(d.ssid, text)
                                Keys.onEscapePressed: event => {
                                    page.cc.wifiExpandedSsid = "";
                                    rowItem.forceActiveFocus(Qt.TabFocusReason);
                                    event.accepted = true;
                                }
                                Keys.onUpPressed: event => { event.accepted = true; }
                                Keys.onDownPressed: event => { event.accepted = true; }
                            }
                            Button {
                                text: qsTr("Connect")
                                variant: "primary"
                                loading: d.connecting
                                enabled: field.length > 0
                                disabledReason: qsTr("Enter the password first")
                                onClicked: page.connect(d.ssid, field.text)
                            }
                        }

                        RowLayout {
                            visible: d.connected && d.expanded
                            spacing: Theme.space8
                            Layout.fillWidth: true
                            Text {
                                Layout.fillWidth: true
                                text: qsTr("Signal %1%").arg(d.strength)
                                font: Theme.typeCaptionTnum
                                color: Theme.textMuted
                            }
                            Button {
                                text: qsTr("Disconnect")
                                size: "sm"
                                onClicked: { page.cc.wifiExpandedSsid = ""; page.net.disconnect(); }
                            }
                        }

                        ErrorBanner {
                            visible: d.failed
                            Layout.fillWidth: true
                            text: page.net.lastError
                            actionText: qsTr("Retry")
                            dismissible: false
                            onAction: {
                                if (field.visible && field.length > 0) page.connect(d.ssid, field.text);
                                else if (d.needsPassword || d.secure) { page.cc.wifiExpandedSsid = d.ssid; field.forceActiveFocus(); field.selectAll(); }
                                else page.connect(d.ssid, "");
                            }
                        }
                    }
                }
                }
            }
        }

        // ---- scanning shimmer --------------------------------------------------
        Column {
            id: scanTail
            visible: page._on && page.net.scanning
            Layout.fillWidth: true
            Accessible.role: Accessible.Animation
            Accessible.name: qsTr("Scanning for networks")
            Repeater {
                model: page.net.networks.count === 0 ? 4 : 1
                delegate: Item {
                    required property int index
                    width: scanTail.width
                    height: 52
                    Skeleton {
                        x: Theme.space16
                        anchors.verticalCenter: parent.verticalCenter
                        width: 20; height: 20; radius: 10
                    }
                    Column {
                        x: Theme.space16 + 20 + Theme.space12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Skeleton { width: [150, 110, 170, 128][index % 4]; height: 11 }
                        Skeleton { width: [72, 56, 84, 64][index % 4]; height: 9 }
                    }
                }
            }
        }
    }
}

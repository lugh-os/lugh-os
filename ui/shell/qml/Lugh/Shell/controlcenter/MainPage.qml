// Control center main page: quick tiles, volume/brightness, media, and the
// user/battery/power footer. Sized by its content (implicitHeight).
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI
import Lugh.Shell
import "icons.js" as Icons

FocusScope {
    id: page

    // The ControlCenter (openPage, back, setDarkAnimated, close).
    property Item cc

    readonly property QtObject net: Services.network
    readonly property QtObject bt: Services.bluetooth
    readonly property QtObject audio: Services.audio
    readonly property QtObject display: Services.display
    readonly property QtObject power: Services.power
    readonly property QtObject media: Services.media
    readonly property QtObject session: Services.session

    property bool _profilesOpen: false
    readonly property var _profiles: ["power-saver", "balanced", "performance"]
    readonly property var _profileNames: [qsTr("Saver"), qsTr("Balanced"), qsTr("Performance")]
    readonly property bool _hasLayouts: Services.keyboard.layouts.length > 1

    implicitWidth: 336
    implicitHeight: col.implicitHeight

    function focusFirst(viaKeyboard) {
        wifiTile.bodyButton.forceActiveFocus(viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason);
    }
    // The control that opened a sub-page, to give focus back to it.
    function opener(name) {
        return name === "wifi" ? wifiTile.detailButton
             : name === "bluetooth" ? btTile.detailButton
             : name === "sound" ? soundButton : null;
    }
    // Back to the opening state: drawer closed, focus on the page itself (the
    // first Tab then lands on the Wi-Fi tile).
    function reset() {
        _profilesOpen = false;
        focusAnchor.forceActiveFocus();
    }
    function showPowerModes() { _profilesOpen = true; }

    function _profileLabel(p) { const i = _profiles.indexOf(p); return i >= 0 ? _profileNames[i] : p; }
    function _onOff(on) { return on ? qsTr("On") : qsTr("Off"); }

    // Holds focus when nothing on the page has it yet; not in the Tab chain.
    Item { id: focusAnchor; focus: true }

    ColumnLayout {
        id: col
        width: parent.width
        spacing: Theme.space12

        // ---- quick tiles -------------------------------------------------
        GridLayout {
            id: grid
            columns: 2
            columnSpacing: Theme.space8
            rowSpacing: Theme.space8
            Layout.fillWidth: true

            readonly property real tileW: (col.width - columnSpacing) / 2

            QuickTile {
                id: wifiTile
                Layout.preferredWidth: grid.tileW
                Layout.fillWidth: true
                title: qsTr("Wi-Fi")
                enabled: page.net.wifiAvailable
                disabledReason: qsTr("No Wi-Fi adapter")
                on: page.net.wifiEnabled
                iconName: Icons.wifi(page.net.wifiEnabled, page.net.connected, page.net.strength)
                subtitle: !page.net.wifiAvailable ? qsTr("Unavailable")
                    : !page.net.wifiEnabled ? (page.net.airplaneMode ? qsTr("Off · Airplane mode") : qsTr("Off"))
                    : page.net.connectingSsid !== "" ? qsTr("Connecting…")
                    : page.net.connected ? page.net.ssid : qsTr("Not connected")
                accessibleState: !page.net.wifiEnabled ? qsTr("off")
                    : page.net.connected ? qsTr("on, connected to %1").arg(page.net.ssid)
                    : qsTr("on, not connected")
                hasDetail: true
                detailName: qsTr("Wi-Fi networks")
                onActivated: page.net.setWifiEnabled(!page.net.wifiEnabled)
                onDetailRequested: kb => page.cc.openPage("wifi", kb)
            }

            QuickTile {
                id: btTile
                Layout.preferredWidth: grid.tileW
                Layout.fillWidth: true
                title: qsTr("Bluetooth")
                enabled: page.bt.available
                disabledReason: qsTr("No Bluetooth adapter")
                on: page.bt.enabled
                iconName: !page.bt.enabled ? "bluetooth-off" : page.bt.connectedCount > 0 ? "bluetooth-connected" : "bluetooth"
                readonly property string _device: {
                    const m = page.bt.devices;
                    page.bt.connectedCount;     // re-evaluate when connections change
                    for (let i = 0; i < m.count; ++i) if (m.get(i).connected) return m.get(i).name;
                    return "";
                }
                subtitle: !page.bt.available ? qsTr("Unavailable")
                    : !page.bt.enabled ? qsTr("Off")
                    : page.bt.connectedCount > 1 ? qsTr("%1 devices").arg(page.bt.connectedCount)
                    : _device !== "" ? _device : qsTr("On")
                accessibleState: !page.bt.enabled ? qsTr("off")
                    : _device !== "" ? qsTr("on, connected to %1").arg(subtitle) : qsTr("on")
                hasDetail: true
                detailName: qsTr("Bluetooth devices")
                onActivated: page.bt.setEnabled(!page.bt.enabled)
                onDetailRequested: kb => page.cc.openPage("bluetooth", kb)
            }

            QuickTile {
                Layout.preferredWidth: grid.tileW
                Layout.fillWidth: true
                title: qsTr("Airplane mode")
                iconName: "plane"
                on: page.net.airplaneMode
                subtitle: page._onOff(on)
                onActivated: page.net.setAirplaneMode(!page.net.airplaneMode)
            }

            QuickTile {
                Layout.preferredWidth: grid.tileW
                Layout.fillWidth: true
                title: qsTr("Do not disturb")
                iconName: on ? "bell-off" : "bell"
                on: Services.notifications.dnd
                subtitle: page._onOff(on)
                accessibleState: page._onOff(on).toLowerCase()
                onActivated: Services.notifications.dnd = !Services.notifications.dnd
            }

            QuickTile {
                Layout.preferredWidth: grid.tileW
                Layout.fillWidth: true
                title: qsTr("Dark mode")
                iconName: "moon"
                on: Services.appearance.dark
                subtitle: page._onOff(on)
                onActivated: page.cc.setDarkAnimated(!Services.appearance.dark)
            }

            QuickTile {
                Layout.preferredWidth: grid.tileW
                Layout.fillWidth: true
                title: qsTr("Night light")
                iconName: "sunset"
                on: page.display.nightLight
                subtitle: page._onOff(on)
                accessibleState: page._onOff(on).toLowerCase()
                onActivated: page.display.setNightLight(!page.display.nightLight)
            }

            QuickTile {
                id: profileTile
                Layout.preferredWidth: grid.tileW
                Layout.fillWidth: true
                Layout.columnSpan: page._hasLayouts ? 1 : 2
                title: qsTr("Power mode")
                checkable: false
                iconName: Icons.profile(page.power.profile)
                subtitle: page._profileLabel(page.power.profile)
                accessibleState: qsTr("%1, activate to switch").arg(subtitle)
                hasDetail: true
                detailIcon: page._profilesOpen ? "chevron-up" : "chevron-down"
                detailName: page._profilesOpen ? qsTr("Hide power modes") : qsTr("Show power modes")
                onActivated: {
                    const i = page._profiles.indexOf(page.power.profile);
                    page.power.setProfile(page._profiles[(i + 1) % page._profiles.length]);
                }
                onDetailRequested: kb => {
                    page._profilesOpen = !page._profilesOpen;
                    if (page._profilesOpen && kb) {
                        const cur = Math.max(0, page._profiles.indexOf(page.power.profile));
                        profileRep.itemAt(cur).forceActiveFocus(Qt.TabFocusReason);
                    }
                }
            }

            QuickTile {
                visible: page._hasLayouts
                Layout.preferredWidth: grid.tileW
                Layout.fillWidth: true
                title: qsTr("Keyboard")
                checkable: false
                iconName: "keyboard"
                subtitle: Services.keyboard.current.toUpperCase()
                accessibleState: qsTr("layout %1, activate to switch").arg(subtitle)
                onActivated: Services.keyboard.next()
            }
        }

        // Inline power-mode picker, opened from the Power mode chevron.
        Item {
            id: profileDrawer
            Layout.fillWidth: true
            Layout.topMargin: page._profilesOpen ? 0 : -col.spacing
            Layout.preferredHeight: page._profilesOpen ? profiles.implicitHeight : 0
            Behavior on Layout.preferredHeight {
                NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
            }
            Behavior on Layout.topMargin {
                NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
            }
            // clip only while sliding, so focus rings show when open
            clip: Layout.preferredHeight < profiles.implicitHeight - 0.5
            // (visible as soon as it opens: a hidden Column measures 0 tall)
            visible: page._profilesOpen || Layout.preferredHeight > 0.5

            Column {
                id: profiles
                width: parent.width
                enabled: page._profilesOpen
                opacity: page._profilesOpen ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSmall) } }
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Power mode")

                Repeater {
                    id: profileRep
                    model: [
                        { p: "power-saver", text: qsTr("Power saver"), hint: qsTr("Longer battery life") },
                        { p: "balanced", text: qsTr("Balanced"), hint: "" },
                        { p: "performance", text: qsTr("Performance"), hint: qsTr("Faster, more power") }
                    ]
                    delegate: ListRow {
                        required property var modelData
                        required property int index
                        width: profiles.width
                        leftInset: 0
                        rightInset: 0
                        leftPadding: Theme.space12
                        rightPadding: Theme.space12
                        title: modelData.text
                        trailingText: modelData.hint
                        iconName: Icons.profile(modelData.p)
                        selected: page.power.profile === modelData.p
                        onClicked: page.power.setProfile(modelData.p)
                        Keys.onReturnPressed: page.power.setProfile(modelData.p)
                        Keys.onEnterPressed: page.power.setProfile(modelData.p)
                        Keys.onUpPressed: if (index > 0) profileRep.itemAt(index - 1).forceActiveFocus(Qt.TabFocusReason)
                        Keys.onDownPressed: if (index < 2) profileRep.itemAt(index + 1).forceActiveFocus(Qt.TabFocusReason)
                        Accessible.name: selected ? qsTr("%1, selected").arg(title) : title
                    }
                }
            }
        }

        // ---- sliders -----------------------------------------------------
        ColumnLayout {
            spacing: Theme.space8
            Layout.fillWidth: true
            Layout.topMargin: Theme.space4

            RowLayout {
                spacing: Theme.space4
                Layout.fillWidth: true

                Slider {
                    id: volume
                    Layout.fillWidth: true
                    iconName: Icons.volume(page.audio.volume, page.audio.muted)
                    iconTooltip: page.audio.muted ? qsTr("Unmute") : qsTr("Mute")
                    showValue: true
                    value: page.audio.volume
                    onMoved: page.audio.setVolume(value)
                    onIconClicked: page.audio.setMuted(!page.audio.muted)
                    Accessible.name: page.audio.muted ? qsTr("Volume, muted") : qsTr("Volume")
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_M) { page.audio.setMuted(!page.audio.muted); event.accepted = true; }
                    }
                }
                IconButton {
                    id: soundButton
                    iconName: "chevron-right"
                    tooltip: qsTr("Sound output")
                    size: 32
                    iconSize: 16
                    property bool _kb: false
                    onPressed: _kb = false
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            page.cc.openPage("sound", true);
                            event.accepted = true;
                        }
                    }
                    onClicked: page.cc.openPage("sound", _kb)
                }
            }

            RowLayout {
                visible: page.display.brightnessAvailable
                spacing: Theme.space4
                Layout.fillWidth: true

                Slider {
                    Layout.fillWidth: true
                    iconName: page.display.brightness < 0.4 ? "sun-dim" : "sun"
                    showValue: true
                    from: 0
                    to: 1
                    value: page.display.brightness
                    onMoved: page.display.setBrightness(value)
                    Accessible.name: qsTr("Brightness")
                }
                // keeps both tracks the same length
                Item { implicitWidth: soundButton.implicitWidth; implicitHeight: 1 }
            }
        }

        // ---- media -------------------------------------------------------
        Rectangle {
            visible: page.media.hasPlayer
            Layout.fillWidth: true
            implicitHeight: 64
            radius: Theme.radiusLg
            antialiasing: true
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.07 : 0.05)
            border.width: 1
            border.color: Theme.glassBorder
            Accessible.role: Accessible.Grouping
            Accessible.name: qsTr("Now playing in %1: %2 by %3").arg(page.media.player).arg(page.media.title).arg(page.media.artist)

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.space12 - 2
                anchors.rightMargin: Theme.space8
                spacing: Theme.space12

                Rectangle {
                    implicitWidth: 44
                    implicitHeight: 44
                    radius: Theme.radiusMd
                    antialiasing: true
                    color: Theme.surface3
                    Icon {
                        anchors.centerIn: parent
                        visible: art.status !== Image.Ready
                        name: "music"
                        size: 20
                        color: Theme.textMuted
                    }
                    Image {
                        id: art
                        anchors.fill: parent
                        visible: status === Image.Ready
                        source: page.media.artUrl
                        sourceSize: Qt.size(88, 88)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                    }
                }

                ColumnLayout {
                    spacing: 1
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: page.media.title
                        font: Theme.typeBodyStrong
                        color: Theme.text
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: page.media.artist !== "" ? page.media.artist + " · " + page.media.player : page.media.player
                        font: Theme.typeCaption
                        color: Theme.textMuted
                        elide: Text.ElideRight
                    }
                }

                Row {
                    spacing: 0
                    IconButton { iconName: "skip-back"; tooltip: qsTr("Previous"); iconSize: 16; onClicked: page.media.previous() }
                    IconButton {
                        iconName: page.media.playing ? "pause" : "play"
                        tooltip: page.media.playing ? qsTr("Pause") : qsTr("Play")
                        variant: "filled"
                        size: 36
                        iconSize: 18
                        onClicked: page.media.playPause()
                    }
                    IconButton { iconName: "skip-forward"; tooltip: qsTr("Next"); iconSize: 16; onClicked: page.media.next() }
                }
            }
        }

        // ---- footer: user, battery, session actions ----------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space2
            implicitHeight: 1
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
        }

        RowLayout {
            spacing: Theme.space8
            Layout.fillWidth: true
            Layout.topMargin: -Theme.space2

            Rectangle {
                implicitWidth: 32
                implicitHeight: 32
                radius: width / 2
                antialiasing: true
                color: Theme.selectedBg
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)
                Accessible.ignored: true
                Text {
                    anchors.centerIn: parent
                    visible: avatar.status !== Image.Ready
                    text: {
                        const parts = page.session.realName.trim().split(/\s+/);
                        const a = (parts[0] || page.session.userName || "?").charAt(0);
                        const b = parts.length > 1 ? parts[parts.length - 1].charAt(0) : "";
                        return (a + b).toUpperCase();
                    }
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.weight: 600
                    color: Theme.accentText
                }
                Image {
                    id: avatar
                    anchors.fill: parent
                    anchors.margins: 1
                    visible: status === Image.Ready
                    source: page.session.avatar
                    sourceSize: Qt.size(64, 64)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
            }

            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true

                Text {
                    Layout.fillWidth: true
                    text: page.session.realName !== "" ? page.session.realName : page.session.userName
                    font: Theme.typeBodyStrong
                    color: Theme.text
                    elide: Text.ElideRight
                }
                RowLayout {
                    spacing: Theme.space4
                    Layout.fillWidth: true
                    readonly property string _detail: !page.power.hasBattery ? page.session.hostName
                        : page.power.charging ? qsTr("%1% · Charging").arg(page.power.batteryPercent)
                        : page.power.timeRemaining !== ""
                          ? qsTr("%1% · %2 left").arg(page.power.batteryPercent).arg(page.power.timeRemaining)
                          : qsTr("%1%").arg(page.power.batteryPercent)
                    Accessible.role: Accessible.StaticText
                    Accessible.name: page.power.hasBattery ? qsTr("Battery %1").arg(_detail) : _detail

                    Icon {
                        visible: page.power.hasBattery
                        name: Icons.battery(page.power.batteryPercent, page.power.charging)
                        size: 14
                        color: page.power.batteryPercent <= 15 && !page.power.charging ? Theme.danger : Theme.textMuted
                    }
                    Text {
                        Layout.fillWidth: true
                        text: parent._detail
                        font: Theme.typeCaptionTnum
                        color: Theme.textMuted
                        elide: Text.ElideRight
                        Accessible.ignored: true
                    }
                }
            }

            IconButton {
                iconName: "settings"
                tooltip: qsTr("Settings")
                enabled: false
                disabledReason: qsTr("Settings arrive in Phase 2")
            }
            IconButton {
                iconName: "lock"
                tooltip: qsTr("Lock")
                onClicked: { page.cc.close(); page.session.lock(); }
            }
            IconButton {
                id: powerButton
                iconName: "power"
                tooltip: qsTr("Power")
                checkable: false
                checked: powerMenu.visible
                onClicked: powerMenu.visible ? powerMenu.close() : powerMenu.open()
                Accessible.description: qsTr("Log out, restart or shut down")

                Menu {
                    id: powerMenu
                    x: powerButton.width - width
                    y: -height - Theme.space4
                    transformOrigin: T.Popup.BottomRight
                    MenuItem {
                        text: qsTr("Log out")
                        iconName: "log-out"
                        onTriggered: { page.cc.close(); page.session.logout(); }
                    }
                    MenuItem {
                        text: qsTr("Restart")
                        iconName: "rotate-ccw"
                        onTriggered: { page.cc.close(); page.session.restart(); }
                    }
                    MenuSeparator {}
                    MenuItem {
                        text: qsTr("Shut down")
                        iconName: "power"
                        danger: true
                        onTriggered: { page.cc.close(); page.session.shutdown(); }
                    }
                }
            }
        }
    }
}

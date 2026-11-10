// Control center (docs/design/lugh-mode.md §3): a full-screen overlay whose
// 320 px glass panel grows out of the status island.
//
//   ControlCenter { anchors.fill: parent }    // frame maps it while `shown`
//
// Opens on ShellState.controlCenterOpen; ShellState.controlCenterPage
// ("wifi" | "bluetooth" | "sound" | "power") opens with that drawer already
// expanded. Esc closes the open drawer first, then the panel; a click outside
// closes.
//
// Layout: a grid of round icon toggles, one caption line that names the
// toggle under the pointer / focus, one volume row (its chevron opens the
// sound drawer), brightness, media and a footer. Detail lives in drawers, one
// open at a time; the panel height follows the open drawer.
//
// Keyboard: Tab walks the groups (grid → caption chevron → drawer → volume →
// brightness → media → footer); arrows move inside the grid and the lists;
// Space / Enter act; → on a toggle with a tick opens its drawer; M mutes on
// the volume slider.
//
// Performance: drawer bodies are created on first expand; no layer or shader
// of its own; sliders call the Services setters directly; nothing polls and
// nothing animates at rest. The dark-mode switch cross-fades from a one-off
// snapshot of the panel (grabToImage) so the theme change reads as one fade.
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell
import "icons.js" as Icons

FocusScope {
    id: root

    // ---- surface contract ---------------------------------------------------
    readonly property bool open: ShellState.controlCenterOpen
    // Open, or still morphing back: the frame keeps the layer mapped while true.
    readonly property bool shown: open || morph.shown
    readonly property bool wantsKeyboard: open
    // The glass panel itself (geometry, opacity) and where it rests.
    readonly property Item panelItem: morph._panel
    readonly property rect panelRect: morph.targetRect

    // ---- geometry -------------------------------------------------------------
    readonly property int panelWidth: 320
    readonly property int padding: 12
    property int rightMargin: 10
    property int islandGap: 6

    // ---- state ------------------------------------------------------------------
    // Open drawer: "" | "wifi" | "bluetooth" | "power" | "sound" | "session".
    property string drawer: ""
    readonly property string page: drawer === "" ? "main" : drawer
    // Wi-Fi drawer: the network whose row is expanded and the one we last
    // tried to connect to (its error shows inline in its row).
    property string wifiExpandedSsid: ""
    property string wifiAttemptSsid: ""
    // Power menu: the action waiting for confirmation.
    property string sessionConfirm: ""

    // Caption line: toggle under the pointer / keyboard focus, else the last touched.
    property string hot: ""
    property string touched: ""
    // Grid: the toggle that holds the grid's single Tab stop.
    property string gridFocus: ""
    readonly property string gridKey: {
        const t = _toggle(gridFocus);
        if (t && t.present) return gridFocus;
        const v = _toggles();
        return v.length > 0 ? v[0].key : "";
    }
    readonly property Item _captioned: {
        const v = _toggles();     // (also re-evaluates when one appears or goes)
        return _toggle(hot) || _toggle(touched) || (v.length > 0 ? v[0] : null);
    }
    property bool _themeBusy: false

    focus: true
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Control center")

    // ---- API ----------------------------------------------------------------------
    // Opens a drawer ("main" or "" closes it). With `viaKeyboard`, focus moves
    // into it with a visible ring.
    function openPage(name, viaKeyboard) {
        name = _valid(name);
        if (name === "") { back(viaKeyboard); return; }
        if (drawer === name && !viaKeyboard) { back(false); return; }   // the tick toggles
        _setDrawer(name, false);
        if (viaKeyboard)
            Qt.callLater(() => { if (root.drawer === name) root._drawerItem(name).focusFirst(true); });
    }
    function back(viaKeyboard) {
        if (drawer === "") return;
        const from = drawer;
        _setDrawer("", false);
        const o = from === "sound" ? soundChevron : from === "session" ? powerButton : _toggle(from);
        if (o && viaKeyboard) o.forceActiveFocus(Qt.TabFocusReason);
        else if (!viaKeyboard) focusHome.forceActiveFocus();
    }
    function close() { ShellState.closeAll(); }
    // Keyboard focus (with ring) on the first control, e.g. opened by a shortcut.
    function focusFirst() {
        if (drawer !== "") { _drawerItem(drawer).focusFirst(true); return; }
        const t = _toggle(gridKey);
        if (t) t.forceActiveFocus(Qt.TabFocusReason);
    }
    function showPowerModes() { openPage("power", false); }

    // Arrow keys in the toggle grid (wraps).
    function moveInGrid(from, dx, dy) {
        const v = _toggles(), n = v.length, i = v.indexOf(from);
        if (i < 0 || n === 0) return;
        let j = i;
        if (dx !== 0) {
            j = (i + dx + n) % n;
        } else {
            const cols = grid.columns;
            j = i + dy * cols;
            if (j >= n) j = i % cols;
            else if (j < 0) { j = i + cols * Math.floor((n - 1 - i) / cols); }
        }
        v[j].forceActiveFocus(Qt.TabFocusReason);
    }

    // Switches the theme and cross-fades the panel from a snapshot of how it
    // looked before (one offscreen grab, no live layer).
    function setDarkAnimated(on) {
        if (_themeBusy || Services.appearance.dark === on) return;
        const p = morph._panel;
        if (!morph.settled || Theme.reduceMotion || p.width <= 0) { Services.appearance.setDark(on); return; }
        const dpr = Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1;
        _themeBusy = true;
        const ok = p.grabToImage(result => {
            snapshot.source = result.url;
            snapshot.opacity = 1;
            Services.appearance.setDark(on);
            snapshotFade.restart();
        }, Qt.size(Math.ceil(p.width * dpr), Math.ceil(p.height * dpr)));
        if (!ok) {
            _themeBusy = false;
            Services.appearance.setDark(on);
        }
    }

    // ---- private ------------------------------------------------------------------------
    function _toggles() {
        const out = [];
        for (let i = 0; i < grid.children.length; ++i) {
            const c = grid.children[i];
            if (c.key !== undefined && c.present) out.push(c);
        }
        return out;
    }
    function _toggle(key) {
        if (key === "") return null;
        for (let i = 0; i < grid.children.length; ++i) {
            const c = grid.children[i];
            if (c.key === key && c.present) return c;
        }
        return null;
    }
    function _drawerItem(name) {
        return name === "wifi" ? wifiDrawer : name === "bluetooth" ? bluetoothDrawer
             : name === "power" ? powerDrawer : name === "sound" ? soundDrawer : sessionDrawer;
    }
    function _valid(name) {
        if (name === "sound" || name === "session") return name;
        if (name === "wifi" || name === "bluetooth" || name === "power") return _toggle(name) ? name : "";
        return "";
    }
    // `instant`: no spring (the panel is closed, or is about to morph open
    // at its final size). Drawer has no public switch for that; its private
    // `_ready` gates both of its Behaviors.
    function _setDrawer(name, instant) {
        const all = [wifiDrawer, bluetoothDrawer, powerDrawer, soundDrawer, sessionDrawer];
        if (instant) for (const d of all) d._ready = false;
        if (name !== "session") sessionConfirm = "";
        if (name !== "wifi") wifiExpandedSsid = "";
        drawer = name;
        if (_toggle(name)) touched = name;      // the caption names the open drawer
        if (instant) for (const d of all) d._ready = true;
    }
    function _enter() {
        const fresh = !morph.shown;
        if (fresh) _reset();
        const p = _valid(ShellState.controlCenterPage);
        if (p !== "" || !fresh) _setDrawer(p, fresh);
    }
    function _reset() {
        _setDrawer("", true);
        hot = "";
        touched = "";
        flick.contentY = 0;
        focusHome.focus = true;     // the next open starts at the top, not where focus was left
    }

    onOpenChanged: if (open) _enter()
    Component.onCompleted: if (open) _enter()

    Connections {
        target: morph
        function onShownChanged() { if (!morph.shown) root._reset(); }
    }
    // A toggle that went away (adapter unplugged) takes its drawer with it.
    onGridKeyChanged: if (drawer !== "" && _valid(drawer) === "") _setDrawer("", false)

    Keys.onEscapePressed: event => {
        if (sessionConfirm !== "") sessionConfirm = "";
        else if (drawer !== "") back(true);
        else close();
        event.accepted = true;
    }

    // ---- wifi bookkeeping ------------------------------------------------------------------
    Connections {
        target: Services.network
        function onConnectingSsidChanged() {
            const n = Services.network;
            if (n.connectingSsid !== "" || n.lastError !== "" || root.wifiAttemptSsid === "") return;
            if (n.connected && n.ssid === root.wifiAttemptSsid) {
                if (root.wifiExpandedSsid === root.wifiAttemptSsid) root.wifiExpandedSsid = "";
                root.wifiAttemptSsid = "";
            }
        }
    }

    // Holds the focus when no control does; Tab from here enters the grid.
    Item { id: focusHome; focus: true }

    // ---- outside click closes ---------------------------------------------------------------
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.AllButtons
        onPressed: root.close()
    }

    // ---- panel ----------------------------------------------------------------------------------
    MorphPanel {
        id: morph

        anchors.fill: parent
        open: root.open
        originRect: ShellState.statusIsland
        targetRect: Qt.rect(root.width - root.rightMargin - root.panelWidth,
                            ShellState.statusIsland.y + ShellState.statusIsland.height + root.islandGap,
                            root.panelWidth,
                            Math.min(body.implicitHeight + 2 * root.padding,
                                     Math.max(200, root.height - ShellState.statusIsland.y
                                              - ShellState.statusIsland.height - root.islandGap - Theme.space16)))

        Flickable {
            id: flick
            anchors.fill: parent
            contentWidth: width
            contentHeight: body.implicitHeight + 2 * root.padding
            interactive: contentHeight > height + 0.5
            clip: interactive
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: body
                x: root.padding
                y: root.padding
                width: root.panelWidth - 2 * root.padding

                // ---- toggles ---------------------------------------------------------------------
                Item {
                    width: parent.width
                    height: grid.height

                    Grid {
                        id: grid
                        anchors.horizontalCenter: parent.horizontalCenter
                        columns: 4
                        columnSpacing: Math.floor((body.width - columns * 48) / (columns - 1))
                        rowSpacing: Theme.space12

                        CcToggle {
                            cc: root; key: "wifi"
                            readonly property var net: Services.network
                            present: net.wifiAvailable
                            label: qsTr("Wi-Fi")
                            iconName: "wifi-off"
                            checkedIconName: Icons.wifi(true, net.connected, net.strength)
                            on: net.wifiEnabled
                            hasDetail: true
                            busy: on && (net.scanning || net.connectingSsid !== "")
                            caption: !on ? qsTr("Off")
                                   : net.connectingSsid !== "" ? qsTr("Connecting to %1…").arg(net.connectingSsid)
                                   : net.connected && net.ssid !== "" ? net.ssid : qsTr("Not connected")
                            stateText: !on ? "" : net.connected && net.ssid !== "" ? qsTr("connected to %1").arg(net.ssid)
                                                : qsTr("not connected")
                            onAct: net.setWifiEnabled(!on)
                        }
                        CcToggle {
                            cc: root; key: "bluetooth"
                            readonly property var bt: Services.bluetooth
                            present: bt.available
                            label: qsTr("Bluetooth")
                            iconName: "bluetooth-off"
                            checkedIconName: "bluetooth"
                            on: bt.enabled
                            hasDetail: true
                            caption: !on ? qsTr("Off")
                                   : bt.connectedCount === 0 ? qsTr("On")
                                   : qsTr("%n device(s) connected", "", bt.connectedCount)
                            stateText: on && bt.connectedCount > 0 ? caption : ""
                            onAct: bt.setEnabled(!on)
                        }
                        CcToggle {
                            cc: root; key: "dnd"
                            label: qsTr("Do Not Disturb")
                            iconName: "bell"
                            checkedIconName: "bell-off"
                            on: Services.notifications.dnd
                            caption: on ? qsTr("Notifications are silenced") : qsTr("Off")
                            onAct: Services.notifications.setDnd(!on)
                        }
                        CcToggle {
                            cc: root; key: "airplane"
                            label: qsTr("Airplane mode")
                            iconName: "plane"
                            on: Services.network.airplaneMode
                            caption: on ? qsTr("Wi-Fi and Bluetooth are off") : qsTr("Off")
                            onAct: Services.network.setAirplaneMode(!on)
                        }
                        CcToggle {
                            cc: root; key: "dark"
                            label: qsTr("Dark mode")
                            iconName: "sun"
                            checkedIconName: "moon"
                            on: Services.appearance.dark
                            caption: on ? qsTr("On") : qsTr("Off")
                            onAct: root.setDarkAnimated(!on)
                        }
                        CcToggle {
                            cc: root; key: "nightlight"
                            present: Services.display.nightLightAvailable
                            label: qsTr("Night light")
                            iconName: "sunset"
                            on: Services.display.nightLight
                            caption: on ? qsTr("Warmer colors") : qsTr("Off")
                            onAct: Services.display.setNightLight(!on)
                        }
                        CcToggle {
                            cc: root; key: "power"
                            readonly property var power: Services.power
                            present: power.profiles.length > 0
                            label: qsTr("Power mode")
                            iconName: Icons.profile(power.profile)
                            on: power.profile !== "balanced"
                            hasDetail: true
                            caption: power.profile === "power-saver" ? qsTr("Power saver")
                                   : power.profile === "performance" ? qsTr("Performance") : qsTr("Balanced")
                            stateText: caption
                            onAct: {
                                const all = power.profiles;
                                power.setProfile(all[(all.indexOf(power.profile) + 1) % all.length]);
                            }
                        }
                        CcToggle {
                            cc: root; key: "keyboard"
                            readonly property var kb: Services.keyboard
                            present: kb.layouts.length > 1
                            label: qsTr("Keyboard layout")
                            glyph: kb.current.toUpperCase().slice(0, 3)
                            caption: kb.current.toUpperCase()
                            stateText: qsTr("layout %1").arg(kb.current)
                            onAct: kb.next()
                        }
                    }
                }

                // ---- caption ------------------------------------------------------------------------
                Item {
                    id: captionLine

                    readonly property Item of: root._captioned
                    readonly property string want: of ? of.label + "  ·  " + of.caption : ""

                    width: parent.width
                    height: 32
                    onWantChanged: {
                        if (!morph.shown || Theme.reduceMotion) { swap.stop(); captionText.opacity = 1; captionText.text = want; }
                        else swap.restart();
                    }
                    Component.onCompleted: captionText.text = want

                    SequentialAnimation {
                        id: swap
                        NumberAnimation { target: captionText; property: "opacity"; to: 0; duration: 60 }
                        ScriptAction { script: captionText.text = captionLine.want }
                        NumberAnimation { target: captionText; property: "opacity"; to: 1; duration: 60 }
                    }

                    Text {
                        id: captionText
                        x: 2
                        y: 6
                        width: parent.width - 34
                        height: 24
                        verticalAlignment: Text.AlignVCenter
                        font: Theme.typeCaption
                        color: Theme.textMuted
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                    IconButton {
                        id: captionChevron
                        readonly property bool isOpen: captionLine.of !== null && root.drawer === captionLine.of.key
                        anchors.right: parent.right
                        y: 4
                        visible: captionLine.of !== null && captionLine.of.hasDetail
                        size: 28
                        iconSize: 14
                        iconName: isOpen ? "chevron-up" : "chevron-down"
                        tooltip: !captionLine.of ? "" : isOpen ? qsTr("Hide %1 details").arg(captionLine.of.label)
                                                           : qsTr("Show %1 details").arg(captionLine.of.label)
                        onClicked: {
                            const k = captionLine.of.key;
                            root.touched = k;
                            if (isOpen) root.back(visualFocus);
                            else root.openPage(k, visualFocus);
                        }
                    }
                }

                WifiDrawer { id: wifiDrawer; cc: root; width: parent.width }
                BluetoothDrawer { id: bluetoothDrawer; cc: root; width: parent.width }
                PowerDrawer { id: powerDrawer; cc: root; width: parent.width }

                Item { width: 1; height: Theme.space8 }

                // ---- volume: one row -------------------------------------------------------------------
                Item {
                    width: parent.width
                    height: 32

                    LevelSlider {
                        id: volume
                        readonly property var audio: Services.audio
                        anchors.left: parent.left
                        anchors.right: soundChevron.left
                        anchors.rightMargin: Theme.space8
                        level: audio.muted ? 0 : audio.volume
                        iconName: Icons.volume(audio.volume, audio.muted)
                        iconTooltip: audio.muted ? qsTr("Unmute") : qsTr("Mute")
                        Accessible.name: qsTr("Volume")
                        onMoved: audio.setVolume(value)
                        onIconClicked: audio.setMuted(!audio.muted)
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_M) {
                                audio.setMuted(!audio.muted);
                                event.accepted = true;
                            }
                        }
                    }
                    IconButton {
                        id: soundChevron
                        readonly property bool isOpen: root.drawer === "sound"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        size: 28
                        iconSize: 14
                        iconName: isOpen ? "chevron-up" : "chevron-down"
                        tooltip: isOpen ? qsTr("Hide outputs, apps and microphone") : qsTr("Outputs, apps and microphone")
                        onClicked: isOpen ? root.back(visualFocus) : root.openPage("sound", visualFocus)
                    }
                }
                SoundDrawer { id: soundDrawer; cc: root; width: parent.width }

                // ---- brightness ---------------------------------------------------------------------------
                Item {
                    visible: Services.display.brightnessAvailable
                    width: parent.width
                    height: 32

                    LevelSlider {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.rightMargin: soundChevron.width + Theme.space8
                        level: Services.display.brightness
                        from: 0.05
                        iconName: "sun"
                        Accessible.name: qsTr("Brightness")
                        onMoved: Services.display.setBrightness(value)
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: soundChevron.width
                        horizontalAlignment: Text.AlignHCenter
                        text: Math.round(Services.display.brightness * 100)
                        font: Theme.typeCaptionTnum
                        color: Theme.textMuted
                        Accessible.ignored: true
                    }
                }

                // ---- media: one row ---------------------------------------------------------------------------
                Item {
                    readonly property var media: Services.media
                    visible: media.hasPlayer
                    width: parent.width
                    height: 36

                    Icon {
                        x: 6
                        anchors.verticalCenter: parent.verticalCenter
                        name: "music"
                        size: 14
                        color: Theme.textMuted
                    }
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 26
                        anchors.right: transport.left
                        anchors.rightMargin: Theme.space8
                        anchors.verticalCenter: parent.verticalCenter
                        text: parent.media.artist !== "" ? parent.media.title + "  ·  " + parent.media.artist
                                                        : parent.media.title !== "" ? parent.media.title : parent.media.player
                        font: Theme.typeLabel
                        color: Theme.text
                        elide: Text.ElideRight
                        Accessible.name: qsTr("Now playing: %1").arg(text)
                    }
                    Row {
                        id: transport
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter

                        IconButton {
                            size: 28; iconSize: 14
                            iconName: "skip-back"
                            tooltip: qsTr("Previous")
                            onClicked: Services.media.previous()
                        }
                        IconButton {
                            size: 28; iconSize: 14
                            iconName: Services.media.playing ? "pause" : "play"
                            tooltip: Services.media.playing ? qsTr("Pause") : qsTr("Play")
                            onClicked: Services.media.playPause()
                        }
                        IconButton {
                            size: 28; iconSize: 14
                            iconName: "skip-forward"
                            tooltip: qsTr("Next")
                            onClicked: Services.media.next()
                        }
                    }
                }

                // ---- footer -------------------------------------------------------------------------------------
                Item {
                    width: parent.width
                    height: 9
                    Rectangle { y: 4; width: parent.width; height: 1; color: Theme.glassBorder }
                }
                Item {
                    width: parent.width
                    height: 32

                    Row {
                        readonly property var power: Services.power
                        x: 4
                        anchors.verticalCenter: parent.verticalCenter
                        visible: power.hasBattery
                        spacing: 6
                        Accessible.role: Accessible.StaticText
                        Accessible.name: qsTr("Battery %1 percent").arg(power.batteryPercent)
                                         + (power.charging ? ", " + qsTr("charging") : "")
                                         + (power.timeRemaining !== "" ? ", " + power.timeRemaining : "")

                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: Icons.battery(parent.power.batteryPercent, parent.power.charging)
                            size: 16
                            color: !parent.power.charging && parent.power.batteryPercent <= 15 ? Theme.danger : Theme.text
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, body.width - 150)
                            text: parent.power.batteryPercent + "%"
                                  + (parent.power.timeRemaining !== "" ? "  ·  " + parent.power.timeRemaining : "")
                            font: Theme.typeCaptionTnum
                            color: Theme.textMuted
                            elide: Text.ElideRight
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.space4

                        Item {
                            id: avatar
                            readonly property string who: Services.session.realName !== "" ? Services.session.realName
                                                                                          : Services.session.userName
                            width: 32
                            height: 28
                            anchors.verticalCenter: parent.verticalCenter
                            Accessible.role: Accessible.StaticText
                            Accessible.name: qsTr("Signed in as %1").arg(who)

                            Rectangle {
                                width: 28
                                height: 28
                                radius: 14
                                antialiasing: true
                                color: Theme.selectedBg
                                border.width: 1
                                border.color: Theme.glassBorder

                                Text {
                                    anchors.centerIn: parent
                                    text: avatar.who.split(/\s+/).filter(w => w !== "").slice(0, 2)
                                              .map(w => w.charAt(0).toUpperCase()).join("")
                                    font: Theme.typeCaption
                                    color: Theme.accentText
                                }
                            }
                        }
                        IconButton {
                            size: 28; iconSize: 16
                            iconName: "lock"
                            tooltip: qsTr("Lock")
                            onClicked: { root.close(); Services.session.lock(); }
                        }
                        IconButton {
                            id: powerButton
                            size: 28; iconSize: 16
                            iconName: "power"
                            tooltip: root.drawer === "session" ? qsTr("Hide power options") : qsTr("Power options")
                            checkable: true
                            checked: root.drawer === "session"
                            onClicked: {
                                const viaKeyboard = visualFocus;
                                if (root.drawer === "session") root.back(viaKeyboard);
                                else root.openPage("session", viaKeyboard);
                                checked = Qt.binding(() => root.drawer === "session");
                            }
                        }
                    }
                }
                SessionDrawer { id: sessionDrawer; cc: root; width: parent.width }
            }
        }
    }

    // Old-theme snapshot, faded out over the new theme (see setDarkAnimated).
    Image {
        id: snapshot
        x: morph.targetRect.x
        y: morph.targetRect.y
        width: morph.targetRect.width
        height: morph.targetRect.height
        opacity: 0
        visible: opacity > 0 && source.toString() !== ""
        cache: false
        smooth: true
        Accessible.ignored: true
    }
    NumberAnimation {
        id: snapshotFade
        target: snapshot; property: "opacity"; from: 1; to: 0
        duration: Theme.dur(Theme.durLarge)
        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
        onFinished: { snapshot.source = ""; root._themeBusy = false; }
    }
}

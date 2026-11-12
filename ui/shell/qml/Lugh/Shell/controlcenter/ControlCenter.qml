// Quick panel: clock, calendar and controls in one compact glass panel that
// pops out of the panel's tray (ShellState.statusIsland) at the bottom-right,
// its bottom edge ShellState.panelReserved + 8 px above the screen bottom.
//
//   ControlCenter { anchors.fill: parent }    // frame maps it while `shown`
//
// Opens on ShellState.controlCenterOpen; ShellState.controlCenterPage
// ("wifi" | "bluetooth" | "sound" | "power") opens with that drawer already
// expanded. Esc backs out one step (power confirmation → edit mode → drawer)
// and then closes; a click outside closes.
//
// Sections, top to bottom (each hidden per ShellSettings):
//   header         big time + long date (ShellSettings.clock24h /
//                  clockShowSeconds); Customize (→ "quick" page), lock, power
//                  (session drawer)
//   calendar       quickShowCalendar: month calendar, folds to this week
//                  (saved in quickCalendarFolded)
//   quick settings ShellSettings.quickToggles, two-column pill tiles; Wi-Fi,
//                  Bluetooth and Power mode have a chevron that opens their
//                  drawer. The pencil turns on edit mode: drag a tile (or
//                  Shift+arrows) to reorder, ⊖ / Delete to remove, the chips
//                  below add the rest. Every change assigns a new array to
//                  ShellSettings.quickToggles (persisted).
//   sliders        quickShowSliders: volume (chevron → sound drawer), brightness,
//                  each with its value ("62%", "Muted")
//   media          quickShowMedia && a player: one slim now-playing row
//   notifications  quickShowNotifications: count, Do Not Disturb, clear, the
//                  newest three (tap to expand), "Show all" → notification center
//
// Auto-fit (`fitLevel`): when the resting layout is taller than the screen
// minus ShellState.panelReserved and the margins, it tightens spacing and
// tiles, then folds the calendar, then shows fewer notifications — never
// touching the saved settings. Drawers and an expanded notification scroll.
// "Keep awake" is Services.session.idleInhibited / setIdleInhibit(on).
// Test: ui/shell/qml/tests/tst_quickpanel.qml.
//
// Keyboard: Tab walks header buttons → calendar → edit → tiles (one Tab stop;
// arrows move between tiles, Space toggles, Enter opens the drawer) → drawer
// → sliders → media → notifications. M mutes on the volume slider.
//
// Motion: PopSurface (scale towards the tray + fade, shape and content
// together; reduce motion = fade). Drawer bodies are created on first expand;
// nothing polls or animates at rest. The dark-mode tile cross-fades from a
// one-off snapshot of the panel (grabToImage).
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell
import "icons.js" as Icons
import "../notifications" as Notif

FocusScope {
    id: root

    // ---- surface contract ---------------------------------------------------
    readonly property bool open: ShellState.controlCenterOpen
    // Open, or still fading out: the frame keeps the layer mapped while true.
    readonly property bool shown: open || surface.shown
    readonly property bool wantsKeyboard: open
    // The glass panel itself (geometry, opacity) and where it rests.
    readonly property Item panelItem: surface.panel
    readonly property rect panelRect: surface.targetRect

    // ---- geometry -------------------------------------------------------------
    readonly property int panelWidth: 360
    readonly property int padding: 14
    property int edgeMargin: 10        // from the screen's right edge
    property int panelGap: 8           // above the bottom panel's reserved zone
    property int topMargin: Theme.space16
    readonly property int tileGap: Theme.space8
    readonly property int tileHeight: _tileH(fitLevel)
    readonly property real tileWidth: (body.width - tileGap) / 2
    readonly property color cardFill: Theme.dark ? Qt.rgba(1, 1, 1, 0.055) : Qt.rgba(1, 1, 1, 0.55)
    readonly property int cardHeight: 40       // a collapsed notification row
    readonly property int maxNotifications: 3

    // ---- auto-fit ---------------------------------------------------------------
    // Height the panel may take: from the top margin down to the bottom panel.
    readonly property real availableHeight: surface.restBottom - topMargin
    // The first level whose resting height fits (drawers and an expanded
    // notification are transient and scroll instead):
    //   0 as configured   1 tighter spacing, 44 px tiles   2 + calendar folded
    //   3/4/5 + only 2/1/0 notifications (the heading and "Show all" stay)
    // Never written to settings: the saved fold stays the user's.
    readonly property int fitLevel: {
        for (let l = 0; l < 5; ++l)
            if (_fitHeight(l) <= availableHeight) return l;
        return 5;
    }
    readonly property bool autoFold: fitLevel >= 2
    readonly property int sectionGap: fitLevel >= 1 ? Theme.space8 : Theme.space12
    readonly property int notificationLimit: _notifLimit(fitLevel)

    function _tileH(level) { return level >= 1 ? 44 : 48; }
    function _notifLimit(level) { return level >= 3 ? 5 - level : maxNotifications; }
    // Resting height of the panel at fit `level`, from level-independent parts.
    function _fitHeight(level) {
        const gap = level >= 1 ? Theme.space8 : Theme.space12;
        let h = 2 * padding + headerRow.height, sections = 1;
        if (ShellSettings.quickShowCalendar) {
            h += calendar.heightFor(ShellSettings.quickCalendarFolded || (level >= 2 && !calendarPeek));
            sections++;
        }
        const rows = Math.ceil(tileIds.length / 2);
        h += qsHeading.height + (rows > 0 ? qsColumn.spacing + rows * _tileH(level) + (rows - 1) * tileGap : 0)
           + (editing ? qsColumn.spacing + addColumn.implicitHeight : 0);
        sections++;
        if (ShellSettings.quickShowSliders) {
            h += volumeRow.height + (Services.display.brightnessAvailable ? sliders.spacing + brightnessRow.height : 0);
            sections++;
        }
        if (ShellSettings.quickShowMedia && Services.media.hasPlayer) { h += mediaRow.height; sections++; }
        if (ShellSettings.quickShowNotifications) {
            const count = Services.notifications.count;
            const k = Math.min(Math.min(count, maxNotifications), _notifLimit(level));
            h += notifHeader.height + k * (notifColumn.spacing + cardHeight)
               + (count === 0 ? notifColumn.spacing + emptyRow.height : 0)
               + (count > k ? notifColumn.spacing + showAll.height : 0);
            sections++;
        }
        return h + (sections - 1) * gap;
    }
    // Calendar chevron: unfolding by hand while auto-folded only lasts this
    // opening; otherwise it flips the saved choice.
    function toggleCalendarFold() {
        if (calendarCollapsed) {
            ShellSettings.quickCalendarFolded = false;
            calendarPeek = true;
        } else if (autoFold && calendarPeek) {
            calendarPeek = false;
        } else {
            ShellSettings.quickCalendarFolded = true;
        }
    }

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
    // Tile edit mode.
    property bool editing: false
    // Calendar: the saved fold (ShellSettings.quickCalendarFolded), or folded
    // by the auto-fit unless unfolded by hand for this opening (`calendarPeek`).
    property bool calendarPeek: false
    readonly property bool calendarCollapsed: ShellSettings.quickCalendarFolded || (autoFold && !calendarPeek)
    property int openNid: -1
    property bool _themeBusy: false

    readonly property var knownToggles: ["wifi", "bluetooth", "dnd", "nightlight", "airplane",
                                         "powerprofile", "darkmode", "caffeine"]
    // Configured tiles this machine can show, in order.
    readonly property var tileIds: {
        const out = [], src = ShellSettings.quickToggles || [];
        for (let i = 0; i < src.length; ++i) {
            const id = String(src[i]);
            if (knownToggles.indexOf(id) >= 0 && out.indexOf(id) < 0 && _present(id)) out.push(id);
        }
        return out;
    }
    // What edit mode offers to add.
    readonly property var spareIds: knownToggles.filter(id => tileIds.indexOf(id) < 0 && _present(id))
    // Roving Tab stop of the tile grid.
    property string tileFocus: ""
    readonly property string tileKey: tileIds.indexOf(tileFocus) >= 0 ? tileFocus : (tileIds.length > 0 ? tileIds[0] : "")
    // Drag reorder: index being dragged and where it would land.
    property int _dragFrom: -1
    property int _dragTo: -1

    // A slider's value, right-aligned in the column before the sound chevron.
    component ValueLabel: Text {
        width: 44
        anchors.verticalCenter: parent.verticalCenter
        rightPadding: 2
        horizontalAlignment: Text.AlignRight
        font: Theme.typeCaptionTnum
        color: Theme.textMuted
        Accessible.ignored: true
    }
    function _percent(v) { return qsTr("%1%").arg(Math.round(v * 100)); }

    focus: true
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Quick settings")

    // ---- API ----------------------------------------------------------------------
    // Opens a drawer ("main" or "" closes it); the same one again closes it.
    // With `viaKeyboard`, focus moves into it with a visible ring.
    function openPage(name, viaKeyboard) {
        name = _valid(name);
        if (name === "") { back(viaKeyboard); return; }
        if (drawer === name && !viaKeyboard) { back(false); return; }
        _setDrawer(name, false);
        if (viaKeyboard)
            Qt.callLater(() => { if (root.drawer === name) root._drawerItem(name).focusFirst(true); });
    }
    function back(viaKeyboard) {
        if (drawer === "") return;
        const from = drawer;
        _setDrawer("", false);
        const o = from === "sound" ? soundChevron : from === "session" ? powerButton : _tileItem(_tileOf(from));
        if (o && viaKeyboard) o.forceActiveFocus(Qt.TabFocusReason);
        else if (!viaKeyboard) focusHome.forceActiveFocus();
    }
    function close() { ShellState.closeAll(); }
    // Keyboard focus (with ring) on the first control, e.g. opened by a shortcut.
    function focusFirst() {
        if (drawer !== "") { _drawerItem(drawer).focusFirst(true); return; }
        const t = _tileItem(tileKey);
        if (t) t.forceActiveFocus(Qt.TabFocusReason);
        else settingsButton.forceActiveFocus(Qt.TabFocusReason);
    }
    function showPowerModes() { openPage("power", false); }

    // ---- tiles --------------------------------------------------------------------
    function _present(id) {
        switch (id) {
        case "wifi": return Services.network.wifiAvailable;
        case "bluetooth": return Services.bluetooth.available;
        case "nightlight": return Services.display.nightLightAvailable;
        case "powerprofile": return Services.power.profiles.length > 0;
        default: return true;
        }
    }
    function _profileName(p) {
        return p === "power-saver" ? qsTr("Power saver") : p === "performance" ? qsTr("Performance") : qsTr("Balanced");
    }
    // Label, icon, state and drawer of a tile (reads the services it shows,
    // so a binding on it follows them).
    function tileMeta(id) {
        const net = Services.network, bt = Services.bluetooth, p = Services.power;
        switch (id) {
        case "wifi": {
            const on = net.wifiEnabled;
            return { label: qsTr("Wi-Fi"), icon: Icons.wifi(on, net.connected, net.strength), on: on, drawer: "wifi",
                     sub: !on ? qsTr("Off") : net.connectingSsid !== "" ? qsTr("Connecting…")
                        : net.connected && net.ssid !== "" ? net.ssid : qsTr("Not connected") };
        }
        case "bluetooth": {
            const on = bt.enabled;
            return { label: qsTr("Bluetooth"), icon: on ? "bluetooth" : "bluetooth-off", on: on, drawer: "bluetooth",
                     sub: !on ? qsTr("Off") : bt.connectedCount === 0 ? qsTr("On")
                        : qsTr("%n connected", "", bt.connectedCount) };
        }
        case "dnd": {
            const on = Services.notifications.dnd;
            return { label: qsTr("Do Not Disturb"), icon: on ? "bell-off" : "bell", on: on, drawer: "",
                     sub: on ? qsTr("Silenced") : qsTr("Off") };
        }
        case "nightlight": {
            const on = Services.display.nightLight;
            return { label: qsTr("Night light"), icon: "sunset", on: on, drawer: "",
                     sub: on ? qsTr("Warmer colors") : qsTr("Off") };
        }
        case "airplane": {
            const on = net.airplaneMode;
            return { label: qsTr("Airplane mode"), icon: "plane", on: on, drawer: "", sub: on ? qsTr("On") : qsTr("Off") };
        }
        case "powerprofile":
            return { label: qsTr("Power mode"), icon: Icons.profile(p.profile), on: p.profile !== "balanced",
                     drawer: "power", sub: _profileName(p.profile) };
        case "darkmode":
            return { label: qsTr("Dark mode"), icon: Theme.dark ? "moon" : "sun", on: Theme.dark, drawer: "",
                     sub: Theme.dark ? qsTr("On") : qsTr("Off") };
        case "caffeine": {
            const on = Services.session.idleInhibited;
            return { label: qsTr("Keep awake"), icon: "coffee", on: on, drawer: "",
                     sub: on ? qsTr("Screen stays on") : qsTr("Off") };
        }
        }
        return { label: id, icon: "circle", on: false, drawer: "", sub: "" };
    }
    function toggleTile(id) {
        const net = Services.network, bt = Services.bluetooth, p = Services.power;
        switch (id) {
        case "wifi": net.setWifiEnabled(!net.wifiEnabled); break;
        case "bluetooth": bt.setEnabled(!bt.enabled); break;
        case "dnd": Services.notifications.setDnd(!Services.notifications.dnd); break;
        case "nightlight": Services.display.setNightLight(!Services.display.nightLight); break;
        case "airplane": net.setAirplaneMode(!net.airplaneMode); break;
        case "powerprofile": {
            const all = p.profiles;
            p.setProfile(all[(all.indexOf(p.profile) + 1) % all.length]);
            break;
        }
        case "darkmode": setDarkAnimated(!Theme.dark); break;
        case "caffeine": Services.session.setIdleInhibit(!Services.session.idleInhibited); break;
        }
    }
    // Writes the visible order back, keeping configured tiles this machine
    // can't show (an unplugged adapter) at the end. Always a new array so
    // Settings persists it. `focusId` gets keyboard focus afterwards.
    function _commitTiles(ids, focusId) {
        const kept = (ShellSettings.quickToggles || []).map(String)
            .filter(id => ids.indexOf(id) < 0 && knownToggles.indexOf(id) >= 0 && !_present(id));
        ShellSettings.quickToggles = ids.concat(kept);
        if (focusId) {
            const t = _tileItem(focusId);
            if (t) t.forceActiveFocus(Qt.TabFocusReason);
        }
    }
    // Deferred: the tiles are rebuilt, and the caller may be one of them.
    function moveTile(id, to, keepFocus) {
        Qt.callLater(() => {
            const ids = root.tileIds.slice(), from = ids.indexOf(id);
            to = Math.max(0, Math.min(ids.length - 1, to));
            if (from < 0 || from === to) return;
            ids.splice(to, 0, ids.splice(from, 1)[0]);
            root._commitTiles(ids, keepFocus ? id : "");
        });
    }
    function removeTile(id) {
        Qt.callLater(() => {
            const ids = root.tileIds.slice(), i = ids.indexOf(id);
            if (i < 0) return;
            ids.splice(i, 1);
            root._commitTiles(ids, ids.length > 0 ? ids[Math.min(i, ids.length - 1)] : "");
            if (ids.length === 0) doneButton.forceActiveFocus(Qt.TabFocusReason);
        });
    }
    function addTile(id) {
        if (tileIds.indexOf(id) >= 0) return;
        _commitTiles(tileIds.concat([id]), "");
    }
    function setEditing(on) {
        editing = on;
        if (on && drawer !== "" && drawer !== "sound" && drawer !== "session") _setDrawer("", false);
    }
    // Where tile `i` is drawn while another one is being dragged.
    function _slotOf(i) {
        const f = _dragFrom, t = _dragTo;
        if (f < 0 || f === t) return i;
        if (i === f) return t;
        if (f < t && i > f && i <= t) return i - 1;
        if (f > t && i >= t && i < f) return i + 1;
        return i;
    }
    function _tileX(slot) { return (slot % 2) * (tileWidth + tileGap); }
    function _tileY(slot) { return Math.floor(slot / 2) * (tileHeight + tileGap); }
    function _tileItem(id) {
        const i = tileIds.indexOf(id);
        return i >= 0 ? tiles.itemAt(i) : null;
    }
    function _tileOf(drawerName) {
        return drawerName === "power" ? "powerprofile" : drawerName;
    }
    function _navigate(fromIndex, dx, dy) {
        const n = tileIds.length;
        let j = dx !== 0 ? fromIndex + dx : fromIndex + dy * 2;
        if (j < 0 || j >= n) return;
        const t = tiles.itemAt(j);
        if (t) t.forceActiveFocus(Qt.TabFocusReason);
    }

    // Switches the theme (ShellSettings.dark, mirrored into Theme) and
    // cross-fades the panel from a snapshot of how it looked before.
    function setDarkAnimated(on) {
        const apply = () => { ShellSettings.dark = on; Services.appearance.setDark(on); };
        if (_themeBusy || Theme.dark === on) return;
        const p = surface.panel;
        if (!surface.settled || Theme.reduceMotion || p.width <= 0) { apply(); return; }
        const dpr = Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1;
        _themeBusy = true;
        const ok = p.grabToImage(result => {
            snapshot.source = result.url;
            snapshot.opacity = 1;
            apply();
            snapshotFade.restart();
        }, Qt.size(Math.ceil(p.width * dpr), Math.ceil(p.height * dpr)));
        if (!ok) { _themeBusy = false; apply(); }
    }

    // ---- private ------------------------------------------------------------------------
    // Scrolls a focused control of the panel into view (a drawer can make the
    // panel taller than the screen).
    function _reveal(item) {
        let p = item;
        while (p && p !== body) p = p.parent;
        if (!p || !flick.interactive) return;
        const y = item.mapToItem(flick.contentItem, 0, 0).y;
        if (y < flick.contentY + root.padding)
            flick.contentY = Math.max(0, y - root.padding);
        else if (y + item.height > flick.contentY + flick.height - root.padding)
            flick.contentY = Math.min(flick.contentHeight - flick.height, y + item.height - flick.height + root.padding);
    }
    Connections {
        target: root.Window.window
        enabled: root.open
        function onActiveFocusItemChanged() { root._reveal(root.Window.window.activeFocusItem); }
    }
    function _drawerItem(name) {
        return name === "wifi" ? wifiDrawer : name === "bluetooth" ? bluetoothDrawer
             : name === "power" ? powerDrawer : name === "sound" ? soundDrawer : sessionDrawer;
    }
    function _valid(name) {
        if (name === "sound" || name === "session") return name;
        if (name === "wifi" || name === "bluetooth" || name === "power")
            return _present(_tileOf(name)) ? name : "";
        return "";
    }
    // `instant`: no spring (the panel is closed, or is about to open at its
    // final size). Drawer's private `_ready` gates both of its Behaviors.
    function _setDrawer(name, instant) {
        const all = [wifiDrawer, bluetoothDrawer, powerDrawer, soundDrawer, sessionDrawer];
        if (instant) for (const d of all) d._ready = false;
        if (name !== "session") sessionConfirm = "";
        if (name !== "wifi") wifiExpandedSsid = "";
        drawer = name;
        if (instant) for (const d of all) d._ready = true;
    }
    function _enter() {
        const fresh = !surface.shown;
        if (fresh) _reset();
        now = Date.now();
        _rev++;
        const p = _valid(ShellState.controlCenterPage);
        if (p !== "" || !fresh) _setDrawer(p, fresh);
    }
    function _reset() {
        _setDrawer("", true);
        editing = false;
        openNid = -1;
        calendarPeek = false;
        _dragFrom = -1;
        _dragTo = -1;
        calendar.reset();
        flick.contentY = 0;
        focusHome.focus = true;     // the next open starts at the top, not where focus was left
    }

    onOpenChanged: if (open) _enter()
    Component.onCompleted: if (open) _enter()

    Connections {
        target: surface
        function onShownChanged() { if (!surface.shown) root._reset(); }
    }
    // A tile whose drawer is open went away (adapter unplugged): close it.
    onTileIdsChanged: if (drawer !== "" && _valid(drawer) === "") _setDrawer("", false)

    Keys.onEscapePressed: event => {
        if (sessionConfirm !== "") sessionConfirm = "";
        else if (editing) setEditing(false);
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

    // ---- notifications: the newest three, rebuilt on change -----------------------------------
    property int _rev: 0
    property double now: Date.now()
    readonly property var recent: {
        _rev;
        const h = Services.notifications.history, out = [];
        if (!shown || !ShellSettings.quickShowNotifications) return out;
        for (let i = 0; i < Math.min(maxNotifications, h.count); ++i) {
            const r = h.get(i);
            out.push({ nid: r.nid, appName: r.appName, appIcon: r.appIcon, summary: r.summary, body: r.body,
                       urgency: r.urgency, time: r.time, actions: r.actions, image: r.image });
        }
        return out;
    }
    Connections {
        target: Services.notifications.history
        enabled: root.shown
        function onCountChanged() { root._rev++; }
        function onDataChanged() { root._rev++; }
    }
    Timer {     // relative times, only while open
        interval: 30000
        repeat: true
        running: root.open
        onTriggered: root.now = Date.now()
    }

    // Holds the focus when no control does; Tab from here enters the panel.
    Item { id: focusHome; focus: true }

    // ---- outside click closes ---------------------------------------------------------------
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.AllButtons
        onPressed: root.close()
    }

    // ---- panel ----------------------------------------------------------------------------------
    PopSurface {
        id: surface

        readonly property rect island: ShellState.statusIsland
        readonly property real restBottom: root.height - ShellState.panelReserved - root.panelGap

        anchors.fill: parent
        open: root.open
        origin: Qt.point(island.x + island.width / 2, island.y)
        radius: Theme.radiusXl
        targetRect: {
            const h = Math.min(body.implicitHeight + 2 * root.padding, Math.max(200, restBottom - root.topMargin));
            const want = island.width > 0 ? island.x + island.width - root.panelWidth
                                          : root.width - root.edgeMargin - root.panelWidth;
            const x = Math.max(root.edgeMargin, Math.min(root.width - root.edgeMargin - root.panelWidth, want));
            return Qt.rect(Math.round(x), Math.round(restBottom - h), root.panelWidth, Math.round(h));
        }

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
                spacing: root.sectionGap

                // ---- header: time, date, actions ------------------------------------------------
                Column {
                    width: parent.width
                    spacing: 0

                    Item {
                        id: headerRow
                        width: parent.width
                        height: 44

                        Column {
                            x: Theme.space4
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - actions.width - Theme.space8
                            spacing: 0

                            Row {
                                spacing: Theme.space4
                                Accessible.role: Accessible.StaticText
                                Accessible.name: Qt.formatTime(Services.clock.now, ShellSettings.clock24h ? "HH:mm" : "h:mm AP")

                                Text {
                                    id: timeText
                                    text: Qt.formatTime(Services.clock.now,
                                                        (ShellSettings.clock24h ? "HH:mm" : "h:mm")
                                                        + (ShellSettings.clockShowSeconds ? ":ss" : ""))
                                    font.family: Theme.fontUi
                                    font.pixelSize: Theme.typeTitle1.pixelSize
                                    font.weight: Font.DemiBold
                                    font.features: { "tnum": 1 }
                                    color: Theme.text
                                }
                                Text {
                                    anchors.baseline: timeText.baseline
                                    visible: !ShellSettings.clock24h
                                    text: Qt.formatTime(Services.clock.now, "AP")
                                    font: Theme.typeLabel
                                    color: Theme.textMuted
                                }
                            }
                            Text {
                                width: parent.width
                                text: Services.clock.longDate
                                font: Theme.typeCaption
                                color: Theme.textMuted
                                elide: Text.ElideRight
                            }
                        }

                        Row {
                            id: actions
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.space2

                            IconButton {
                                id: settingsButton
                                size: 32; iconSize: 16
                                iconName: "settings"
                                tooltip: qsTr("Customize quick settings")
                                onClicked: ShellState.openCustomize("quick")
                            }
                            IconButton {
                                size: 32; iconSize: 16
                                iconName: "lock"
                                tooltip: qsTr("Lock")
                                onClicked: { root.close(); Services.session.lock(); }
                            }
                            IconButton {
                                id: powerButton
                                size: 32; iconSize: 16
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

                // ---- calendar --------------------------------------------------------------------
                Notif.MonthCalendar {
                    id: calendar
                    visible: ShellSettings.quickShowCalendar
                    width: parent.width
                    fill: root.cardFill
                    pad: 6
                    cellHeight: 26
                    collapsible: true
                    collapsed: root.calendarCollapsed
                    animate: surface.settled
                    onFoldToggled: root.toggleCalendarFold()
                }

                // ---- quick settings --------------------------------------------------------------
                Column {
                    id: qsColumn
                    width: parent.width
                    spacing: Theme.space8

                    Item {
                        id: qsHeading
                        width: parent.width
                        height: 28

                        Text {
                            x: Theme.space4
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.editing ? qsTr("Edit quick settings") : qsTr("Quick settings")
                            font: Theme.typeCaption
                            color: Theme.textMuted
                            Accessible.role: Accessible.Heading
                        }
                        IconButton {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !root.editing
                            size: 28; iconSize: 14
                            iconName: "pencil"
                            tooltip: qsTr("Edit quick settings")
                            onClicked: {
                                const kb = visualFocus;
                                root.setEditing(true);
                                if (kb) Qt.callLater(() => doneButton.forceActiveFocus(Qt.TabFocusReason));
                            }
                        }
                        Button {
                            id: doneButton
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.editing
                            size: "sm"
                            variant: "primary"
                            text: qsTr("Done")
                            onClicked: root.setEditing(false)
                        }
                    }

                    Item {
                        id: grid
                        readonly property int rows: Math.ceil(root.tileIds.length / 2)
                        width: parent.width
                        height: rows > 0 ? rows * root.tileHeight + (rows - 1) * root.tileGap : 0
                        visible: rows > 0

                        Repeater {
                            id: tiles
                            model: root.tileIds

                            QuickTile {
                                id: tile
                                required property string modelData
                                required property int index
                                readonly property var meta: root.tileMeta(modelData)
                                readonly property int slot: root._slotOf(index)

                                key: modelData
                                label: meta.label
                                sub: meta.sub
                                iconName: meta.icon
                                on: meta.on
                                hasDrawer: meta.drawer !== ""
                                drawerOpen: hasDrawer && root.drawer === meta.drawer
                                editing: root.editing
                                width: root.tileWidth
                                height: root.tileHeight
                                x: dragging ? root._tileX(index) + dragOffset.x : root._tileX(slot)
                                y: dragging ? root._tileY(index) + dragOffset.y : root._tileY(slot)
                                focusPolicy: root.tileKey === modelData ? Qt.StrongFocus : Qt.ClickFocus

                                Behavior on x { enabled: !tile.dragging && !Theme.reduceMotion; NumberAnimation { duration: Theme.durSmall; easing.type: Easing.OutCubic } }
                                Behavior on y { enabled: !tile.dragging && !Theme.reduceMotion; NumberAnimation { duration: Theme.durSmall; easing.type: Easing.OutCubic } }

                                onActiveFocusChanged: if (activeFocus) root.tileFocus = modelData
                                onActivated: root.toggleTile(modelData)
                                onDrawerRequested: root.openPage(meta.drawer, visualFocus)
                                onRemoveRequested: root.removeTile(modelData)
                                onMoveRequested: step => root.moveTile(modelData, index + step, true)
                                onNavigate: (dx, dy) => root._navigate(index, dx, dy)
                                onDraggingChanged: if (dragging) { root._dragFrom = index; root._dragTo = index; }
                                onDragOffsetChanged: {
                                    if (!dragging) return;
                                    const n = root.tileIds.length;
                                    const cx = root._tileX(index) + dragOffset.x + width / 2;
                                    const cy = root._tileY(index) + dragOffset.y + height / 2;
                                    const col = cx < root.tileWidth + root.tileGap / 2 ? 0 : 1;
                                    const row = Math.max(0, Math.min(grid.rows - 1, Math.floor(cy / (root.tileHeight + root.tileGap))));
                                    root._dragTo = Math.max(0, Math.min(n - 1, row * 2 + col));
                                }
                                onDropped: {
                                    const to = root._dragTo;
                                    root._dragFrom = -1;
                                    root._dragTo = -1;
                                    if (to >= 0 && to !== index) root.moveTile(modelData, to, false);
                                }
                            }
                        }
                    }

                    // Edit mode: what can be added.
                    Column {
                        id: addColumn
                        visible: root.editing
                        width: parent.width
                        spacing: Theme.space4

                        Text {
                            x: Theme.space4
                            text: root.spareIds.length > 0 ? qsTr("Add") : qsTr("Every control is shown")
                            font: Theme.typeCaption
                            color: Theme.textMuted
                        }
                        Flow {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: root.editing ? root.spareIds : []
                                Chip {
                                    required property string modelData
                                    objectName: "add:" + modelData
                                    iconName: "plus"
                                    text: root.tileMeta(modelData).label
                                    Accessible.name: qsTr("Add %1").arg(text)
                                    onClicked: root.addTile(modelData)
                                }
                            }
                        }
                    }

                    WifiDrawer { id: wifiDrawer; cc: root; width: parent.width; visible: implicitHeight > 0.5 }
                    BluetoothDrawer { id: bluetoothDrawer; cc: root; width: parent.width; visible: implicitHeight > 0.5 }
                    PowerDrawer { id: powerDrawer; cc: root; width: parent.width; visible: implicitHeight > 0.5 }
                }

                // ---- sliders ---------------------------------------------------------------------
                // Each row: slider, its value ("64%", "Muted") in one right
                // column, then the sound chevron (or its width, empty).
                Column {
                    id: sliders
                    visible: ShellSettings.quickShowSliders
                    width: parent.width
                    spacing: Theme.space4

                    Item {
                        id: volumeRow
                        width: parent.width
                        height: 32

                        LevelSlider {
                            id: volume
                            readonly property var audio: Services.audio
                            anchors.left: parent.left
                            anchors.right: volumeValue.left
                            anchors.verticalCenter: parent.verticalCenter
                            level: audio.muted ? 0 : audio.volume
                            iconName: Icons.volume(audio.volume, audio.muted)
                            iconTooltip: audio.muted ? qsTr("Unmute") : qsTr("Mute")
                            Accessible.name: qsTr("Volume")
                            Accessible.description: volumeValue.text
                            onMoved: {
                                if (audio.muted && value > 0) audio.setMuted(false);
                                audio.setVolume(value);
                            }
                            onIconClicked: audio.setMuted(!audio.muted)
                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_M) {
                                    audio.setMuted(!audio.muted);
                                    event.accepted = true;
                                }
                            }
                        }
                        ValueLabel {
                            id: volumeValue
                            anchors.right: soundChevron.left
                            text: volume.audio.muted ? qsTr("Muted") : root._percent(volume.audio.volume)
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
                    SoundDrawer { id: soundDrawer; cc: root; width: parent.width; visible: implicitHeight > 0.5 }

                    Item {
                        id: brightnessRow
                        visible: Services.display.brightnessAvailable
                        width: parent.width
                        height: 32

                        LevelSlider {
                            anchors.left: parent.left
                            anchors.right: brightnessValue.left
                            anchors.verticalCenter: parent.verticalCenter
                            level: Services.display.brightness
                            from: 0.05
                            iconName: "sun"
                            Accessible.name: qsTr("Brightness")
                            Accessible.description: brightnessValue.text
                            onMoved: Services.display.setBrightness(value)
                        }
                        ValueLabel {
                            id: brightnessValue
                            anchors.right: parent.right
                            anchors.rightMargin: soundChevron.width
                            text: root._percent(Services.display.brightness)
                        }
                    }
                }

                // ---- media -----------------------------------------------------------------------
                Rectangle {
                    id: mediaRow
                    readonly property var media: Services.media
                    visible: ShellSettings.quickShowMedia && media.hasPlayer
                    width: parent.width
                    height: 44
                    radius: Theme.radiusLg
                    color: root.cardFill
                    border.width: 1
                    border.color: Theme.glassBorder

                    Rectangle {
                        id: art
                        x: 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        height: 32
                        radius: Theme.radiusMd
                        color: Theme.selectedBg
                        clip: true
                        Icon {
                            anchors.centerIn: parent
                            name: "music"
                            size: 16
                            color: Theme.accentText
                            visible: cover.status !== Image.Ready
                        }
                        Image {
                            id: cover
                            anchors.fill: parent
                            source: mediaRow.media.artUrl
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: status === Image.Ready
                        }
                    }
                    Column {
                        anchors.left: art.right
                        anchors.leftMargin: 10
                        anchors.right: transport.left
                        anchors.rightMargin: Theme.space4
                        anchors.verticalCenter: parent.verticalCenter
                        Accessible.role: Accessible.StaticText
                        Accessible.name: qsTr("Now playing: %1").arg(nowTitle.text + (nowArtist.text !== "" ? ", " + nowArtist.text : ""))

                        Text {
                            id: nowTitle
                            width: parent.width
                            text: mediaRow.media.title !== "" ? mediaRow.media.title : mediaRow.media.player
                            font: Theme.typeLabel
                            color: Theme.text
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        Text {
                            id: nowArtist
                            width: parent.width
                            visible: text !== ""
                            text: mediaRow.media.artist
                            font: Theme.typeCaption
                            color: Theme.textMuted
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }
                    Row {
                        id: transport
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space4
                        anchors.verticalCenter: parent.verticalCenter

                        IconButton {
                            size: 28; iconSize: 14
                            iconName: "skip-back"
                            tooltip: qsTr("Previous")
                            onClicked: Services.media.previous()
                        }
                        IconButton {
                            size: 28; iconSize: 16
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

                // ---- notifications ---------------------------------------------------------------
                Column {
                    id: notifColumn
                    // Cards shown: the auto-fit's limit, plus an expanded one.
                    readonly property int shownCount: {
                        let n = Math.min(root.recent.length, root.notificationLimit);
                        for (let i = n; i < root.recent.length; ++i)
                            if (root.recent[i].nid === root.openNid) n = i + 1;
                        return n;
                    }
                    visible: ShellSettings.quickShowNotifications
                    width: parent.width
                    spacing: Theme.space4

                    Item {
                        id: notifHeader
                        width: parent.width
                        height: 28

                        Text {
                            id: notifHeading
                            x: Theme.space4
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Notifications")
                            font: Theme.typeCaption
                            color: Theme.textMuted
                            Accessible.role: Accessible.Heading
                        }
                        Badge {
                            anchors.left: notifHeading.right
                            anchors.leftMargin: Theme.space8
                            anchors.verticalCenter: parent.verticalCenter
                            visible: Services.notifications.count > 0
                            text: Services.notifications.count > 99 ? "99+" : String(Services.notifications.count)
                            tone: "neutral"
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.space2

                            Button {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: Services.notifications.count > 0
                                text: qsTr("Clear all")
                                size: "sm"
                                variant: "ghost"
                                Accessible.name: qsTr("Clear all notifications")
                                onClicked: Services.notifications.clearAll()
                            }
                            IconButton {
                                anchors.verticalCenter: parent.verticalCenter
                                size: 28; iconSize: 14
                                iconName: Services.notifications.dnd ? "bell-off" : "bell"
                                tooltip: Services.notifications.dnd ? qsTr("Turn off Do Not Disturb") : qsTr("Do Not Disturb")
                                checkable: true
                                checked: Services.notifications.dnd
                                onClicked: {
                                    Services.notifications.setDnd(!Services.notifications.dnd);
                                    checked = Qt.binding(() => Services.notifications.dnd);
                                }
                            }
                        }
                    }

                    Repeater {
                        model: root.recent
                        Item {
                            id: slot
                            required property var modelData
                            required property int index
                            visible: index < notifColumn.shownCount
                            width: parent.width
                            height: card.height

                            HoverHandler { id: cardHover }
                            Notif.NotificationCard {
                                id: card
                                width: parent.width
                                height: implicitHeight
                                fill: root.cardFill
                                showIcon: true
                                collapsedHeight: root.cardHeight
                                padding: Theme.space12
                                bodyLines: 3
                                includeDefault: true
                                nid: slot.modelData.nid
                                appName: slot.modelData.appName
                                appIcon: slot.modelData.appIcon
                                summary: slot.modelData.summary
                                body: slot.modelData.body
                                urgency: slot.modelData.urgency
                                time: slot.modelData.time
                                actions: slot.modelData.actions
                                image: slot.modelData.image
                                now: root.now
                                expanded: root.openNid === slot.modelData.nid
                                closeVisible: cardHover.hovered || card.activeFocus
                                hovered: cardHover.hovered
                                pressed: cardTap.pressed
                                onCloseRequested: Services.notifications.dismiss(slot.modelData.nid)
                                Accessible.onPressAction: root.openNid = root.openNid === slot.modelData.nid ? -1 : slot.modelData.nid

                                TapHandler {
                                    id: cardTap
                                    onTapped: root.openNid = root.openNid === slot.modelData.nid ? -1 : slot.modelData.nid
                                }
                            }
                        }
                    }

                    Item {
                        id: emptyRow
                        visible: Services.notifications.count === 0
                        width: parent.width
                        height: 36
                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.space8
                            Icon { name: "bell"; size: 14; color: Theme.textMuted; anchors.verticalCenter: parent.verticalCenter }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("No notifications")
                                font: Theme.typeCaption
                                color: Theme.textMuted
                            }
                        }
                    }

                    Button {
                        id: showAll
                        visible: Services.notifications.count > notifColumn.shownCount
                        anchors.horizontalCenter: parent.horizontalCenter
                        size: "sm"
                        variant: "ghost"
                        text: qsTr("Show all %1").arg(Services.notifications.count)
                        Accessible.name: qsTr("Show all %1 notifications").arg(Services.notifications.count)
                        onClicked: ShellState.toggleNotificationCenter()
                    }
                }
            }
        }
    }

    // Old-theme snapshot, faded out over the new theme (see setDarkAnimated).
    Image {
        id: snapshot
        x: surface.targetRect.x
        y: surface.targetRect.y
        width: surface.targetRect.width
        height: surface.targetRect.height
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

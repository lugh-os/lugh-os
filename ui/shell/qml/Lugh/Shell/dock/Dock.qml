// Lugh-mode dock (DESIGN-SYSTEM §8, shell spec §Dock): a floating glass pill
// at the bottom centre with pinned apps, a divider, running unpinned apps, a
// divider and the Trash.
//
// Surface contract: the frame anchors this item to the bottom edge, full
// screen width, `implicitHeight` tall. Everything above the pill is
// transparent headroom for tooltips, the context menu and the launch-failure
// toast. The frame reads:
//   exclusiveZone  px to reserve at the bottom (0 when autohide)
//   inputRect      the part of the surface that takes pointer input, in this
//                  item's coordinates (the pill, the toast, or the whole
//                  surface while the context menu is open)
//   menuOpen       a context menu is open (grab the keyboard while true)
// and may call focusDock() from a keyboard shortcut.
//
// Input: click activates (focus or launch), middle click opens a new window,
// right click (or Menu / Shift+F10 on a focused tile) opens the context menu.
// Keyboard: Left/Right/Home/End move between tiles, Enter/Space activate.
//
// Performance: delegates are an AppIcon, a few Rectangles and one Text; no
// layers or effects. The only per-frame math is magnify (when on and
// hovered), a cosine per tile bound to one pointer x.
import QtQuick
import QtQuick.Templates as T
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: root

    // ---- public -------------------------------------------------------------
    property bool autohide: false
    property bool magnify: false
    property int iconSize: 56
    // True while a window overlaps the dock area (auto-hide only hides then).
    // Defaults to Services.wm.dockOverlapped when the backend provides it.
    property bool overlapped: Services.wm.dockOverlapped !== undefined ? Services.wm.dockOverlapped : true

    readonly property int padding: Theme.space8
    readonly property int bottomMargin: 10
    readonly property int headroom: 260
    // The pill: 8 px above the icons, 12 px below them for the running dots.
    readonly property int dockHeight: iconSize + padding + _bottomPad
    readonly property int _bottomPad: Theme.space12
    readonly property int exclusiveZone: autohide ? 0 : dockHeight + bottomMargin
    readonly property bool menuOpen: menu.visible
    readonly property rect inputRect: {
        if (menuOpen) return Qt.rect(0, 0, width, height);
        const grow = magnify ? _magGrow + Theme.space4 : 0;
        let r = _revealed ? Qt.rect(pill.x, pill.y - grow, pill.width, height - pill.y + grow) : Qt.rect(pill.x, height - _edgeStrip, pill.width, _edgeStrip);
        if (toast.visible) r = _union(r, Qt.rect(toast.x, toast.y, toast.width, toast.height));
        return r;
    }

    // Keyboard entry point (e.g. a compositor shortcut): focus the first tile.
    function focusDock() { _focusAt(0); }
    // Shows the inline "<App> couldn't start" toast (also wired to
    // Services.apps.launchFailed).
    function showLaunchError(appId, message) {
        toast.show(Services.apps.nameFor(appId), message);
    }

    // ---- private / debug ----------------------------------------------------
    // Force a tile's hover (tooltip + lift) or open a tile's menu, for demos
    // and screenshots. Index = position in the dock; dock count = the Trash.
    property int _debugHoverIndex: -1
    property int _debugMenuIndex: -1
    // Pretend the pointer rests over the dock at this x (root coords), to
    // screenshot magnify. -1 = off.
    property real _debugPointerX: -1

    readonly property var _model: Services.apps.dock
    readonly property real _maxMag: 1.6
    readonly property int _spacing: Theme.space8
    readonly property int _dividerSlot: 1 + Theme.space8
    readonly property int _edgeStrip: 4

    implicitWidth: pill.width + 2 * Theme.space64
    implicitHeight: headroom + dockHeight + bottomMargin

    on_DebugMenuIndexChanged: if (_debugMenuIndex >= 0) _debugMenuTimer.restart()
    // Width/position animations start after the first layout, so the dock
    // doesn't grow in from nothing when the shell starts.
    property bool _ready: false
    Component.onCompleted: {
        _rebuild();
        Qt.callLater(() => root._ready = true);
        if (_debugMenuIndex >= 0) _debugMenuTimer.restart();
    }
    Timer { id: _debugMenuTimer; interval: 50; onTriggered: root._openMenu(root._debugMenuIndex) }

    Connections {
        target: Services.apps
        function onLaunchFailed(appId, message) { root.showLaunchError(appId, message); }
    }

    // ---- layout bookkeeping (rebuilt when the model changes) ----------------
    // _pinned[i]: is tile i pinned. _centers[i]: tile i's centre x in the
    // un-magnified list, so magnify never feeds back on its own layout.
    property var _pinned: []
    property var _centers: []
    property real _baseListWidth: 0
    Connections {
        target: root._model
        function onCountChanged() { root._rebuild(); }
        function onDataChanged() { root._rebuild(); }
        function onRowsMoved() { root._rebuild(); }
    }
    onIconSizeChanged: _rebuild()

    function _rebuild() {
        const n = _model.count;
        const pinned = [], centers = [];
        let x = 0;
        for (let i = 0; i < n; ++i) {
            const p = _model.get(i).pinned;
            pinned.push(p);
            if (i > 0) x += _spacing;
            if (i > 0 && !p && pinned[i - 1]) x += _dividerSlot;
            centers.push(x + iconSize / 2);
            x += iconSize;
        }
        _pinned = pinned;
        _centers = centers;
        _baseListWidth = x;
    }
    function _dividerBefore(i, pinnedFlags) {
        return i > 0 && i < pinnedFlags.length && !pinnedFlags[i] && pinnedFlags[i - 1] === true;
    }

    // ---- reveal (auto-hide) -------------------------------------------------
    HoverHandler { id: hover }
    readonly property point _pointer: _debugPointerX >= 0 ? Qt.point(_debugPointerX, pill.y + padding + iconSize / 2) : hover.point.position
    // Pointer hit area, from the un-magnified geometry (plus room for the
    // magnified icons) so magnify can't feed back into its own hit test.
    readonly property int _magGrow: magnify ? Math.ceil(iconSize * (_maxMag - 1)) : 0
    readonly property real _basePillWidth: _baseListWidth + _spacing + _dividerSlot + iconSize + 2 * padding
    readonly property rect _pillHitRect: Qt.rect((width - _basePillWidth) / 2 - _magGrow, height - bottomMargin - dockHeight - (magnify ? _magGrow + Theme.space4 : 0),
                                                 _basePillWidth + 2 * _magGrow, dockHeight + bottomMargin + (magnify ? _magGrow + Theme.space4 : 0))
    readonly property bool _pointerInDock: _debugPointerX >= 0 || hover.hovered && (_revealed
        ? _contains(_pillHitRect, _pointer) : _pointer.y >= height - _edgeStrip && _contains(_pillHitRect, Qt.point(_pointer.x, height - 1)))
    property bool _hold: false
    // Deferred: _hold changes _revealed, which changes this hit test.
    on_PointerInDockChanged: Qt.callLater(_syncHold)
    function _syncHold() { if (_pointerInDock) { _hold = true; _hideTimer.stop(); } else _hideTimer.restart(); }
    Component.onDestruction: _hideTimer.stop()
    Timer { id: _hideTimer; interval: 600; onTriggered: root._hold = false }
    // _hold (not _pointerInDock) so the hit test, which depends on whether
    // the dock is revealed, never feeds back into it.
    readonly property bool _revealed: !autohide || !overlapped || _hold || menuOpen
                                      || activeFocus || toast.shown || _debugHoverIndex >= 0 || _debugMenuIndex >= 0

    function _contains(r, p) { return p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height; }
    function _union(a, b) {
        const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
        return Qt.rect(x, y, Math.max(a.x + a.width, b.x + b.width) - x, Math.max(a.y + a.height, b.y + b.height) - y);
    }

    // ---- magnify ------------------------------------------------------------
    readonly property bool _magOn: magnify && _pointerInDock && _revealed && !menuOpen
    property real _magAmount: _magOn ? 1 : 0
    Behavior on _magAmount { NumberAnimation { duration: Theme.dur(Theme.durSmall); easing.type: Easing.OutCubic } }
    // Pointer x in un-magnified list coordinates (the base pill is centred).
    readonly property real _baseListX: (width - _basePillWidth) / 2 + padding
    readonly property real _pointerListX: _pointer.x - _baseListX
    readonly property real _listWidth: {
        let w = _baseListWidth;
        if (_magAmount > 0)
            for (let i = 0; i < _centers.length; ++i)
                w += iconSize * (_magFor(_centers[i], _pointerListX, _magAmount) - 1);
        return w;
    }
    function _magFor(center, px, amount) {
        if (amount <= 0) return 1;
        const range = iconSize * 2.5;
        const d = Math.abs(px - center);
        if (d >= range) return 1;
        return 1 + (_maxMag - 1) * amount * (Math.cos(d / range * Math.PI) + 1) / 2;
    }

    // ---- toast --------------------------------------------------------------
    DockToast {
        id: toast
        x: Math.round((root.width - width) / 2)
        y: pill.y - height - Theme.space40 - Theme.space4 - (root.magnify ? root._magGrow : 0)
    }

    // ---- the pill -----------------------------------------------------------
    GlassPanel {
        id: pill
        radius: Theme.radiusXl
        elevation: "popover"
        width: row.width + 2 * root.padding
        height: root.dockHeight
        x: Math.round((root.width - width) / 2)
        y: root.height - root.bottomMargin - height + (root._revealed || Theme.reduceMotion ? 0 : root.dockHeight + root.bottomMargin + 24)
        opacity: root._revealed ? 1 : (Theme.reduceMotion ? 0 : 1)
        Behavior on width {
            enabled: root._ready && root._magAmount === 0
            NumberAnimation { duration: Theme.dur(Theme.durMedium); easing.type: Easing.OutCubic }
        }
        Behavior on y {
            enabled: root._ready
            NumberAnimation { duration: Theme.durMedium; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
        }
        Behavior on opacity { NumberAnimation { duration: Theme.durReduced } }

        Item {
            id: row
            x: root.padding
            width: list.width + root._spacing + trash.width
            height: root.dockHeight

            ListView {
                id: list
                // Computed, not contentWidth: no layout feedback while magnifying.
                width: root._listWidth
                height: parent.height
                orientation: ListView.Horizontal
                spacing: root._spacing
                interactive: false
                cacheBuffer: 100000
                model: root._model
                keyNavigationEnabled: false
                boundsBehavior: Flickable.StopAtBounds

                delegate: DockItem {
                    id: app
                    required property int index
                    required property var model
                    readonly property string appId: model.appId

                    iconName: model.icon
                    label: model.name
                    running: model.running
                    windows: model.windows
                    launching: model.launching
                    attention: model.attention
                    iconSize: root.iconSize
                    padding: root.padding
                    artScale: root.magnify ? root._maxMag : 1
                    magnifying: root._magAmount > 0
                    mag: root._magFor(root._centers[index] ?? 0, root._pointerListX, root._magAmount)
                    leadingDivider: root._dividerBefore(index, root._pinned)
                    focusedApp: Services.wm.focusedAppId === appId
                    forceHover: root._debugHoverIndex === index
                    tooltipAllowed: !root.menuOpen
                    accessibleName: root._describe(label, running, windows, launching, attention)

                    onActivated: Services.apps.activate(appId)
                    onMiddleClicked: Services.apps.launch(appId)
                    onContextRequested: root._openMenu(index)
                    Keys.onPressed: event => root._tileKey(event, index)
                }

                add: Transition {
                    ParallelAnimation {
                        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.dur(Theme.durMedium); easing.type: Easing.OutCubic }
                        NumberAnimation { property: "scale"; from: Theme.reduceMotion ? 1 : 0.4; to: 1; duration: Theme.durMedium; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
                    }
                }
                remove: Transition {
                    ParallelAnimation {
                        NumberAnimation { property: "opacity"; to: 0; duration: Theme.dur(Theme.durSmall); easing.type: Easing.InCubic }
                        NumberAnimation { property: "scale"; to: Theme.reduceMotion ? 1 : 0.4; duration: Theme.durSmall; easing.type: Easing.InCubic }
                    }
                }
                displaced: Transition {
                    NumberAnimation { properties: "x"; duration: Theme.dur(Theme.durMedium); easing.type: Easing.OutCubic }
                    NumberAnimation { properties: "opacity,scale"; to: 1; duration: Theme.durMicro }
                }
            }

            DockItem {
                id: trash
                readonly property bool full: Services.trash !== undefined && Services.trash.full === true
                x: list.width + root._spacing
                iconName: full ? "user-trash-full" : "user-trash"
                label: qsTr("Trash")
                iconSize: root.iconSize
                padding: root.padding
                artScale: root.magnify ? root._maxMag : 1
                magnifying: root._magAmount > 0
                mag: root._magFor(root._baseListWidth + root._spacing + root._dividerSlot + root.iconSize / 2, root._pointerListX, root._magAmount)
                leadingDivider: true
                forceHover: root._debugHoverIndex === list.count
                tooltipAllowed: !root.menuOpen
                accessibleName: full ? qsTr("Trash, has items") : qsTr("Trash")

                onActivated: root._openTrash()
                onContextRequested: root._openMenu(list.count)
                Keys.onPressed: event => root._tileKey(event, list.count)
            }
        }
    }

    // ---- keyboard -------------------------------------------------------------
    function _tileAt(i) { return i === list.count ? trash : list.itemAtIndex(i); }
    function _focusAt(i) {
        const n = list.count + 1;
        const t = _tileAt(Math.max(0, Math.min(n - 1, i)));
        if (t) t.forceActiveFocus(Qt.TabFocusReason);
    }
    function _tileKey(event, i) {
        const k = event.key;
        if (k === Qt.Key_Left) _focusAt(i - 1);
        else if (k === Qt.Key_Right) _focusAt(i + 1);
        else if (k === Qt.Key_Home) _focusAt(0);
        else if (k === Qt.Key_End) _focusAt(list.count);
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) _tileAt(i).activated();
        else if (k === Qt.Key_Menu || (k === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) _openMenu(i);
        else return;
        event.accepted = true;
    }

    function _describe(name, running, windows, launching, attention) {
        const parts = [name];
        if (launching) parts.push(qsTr("starting"));
        else if (running) parts.push(qsTr("running"), windows === 1 ? qsTr("1 window") : qsTr("%1 windows").arg(windows));
        if (attention) parts.push(qsTr("needs attention"));
        return parts.join(", ");
    }

    function _openTrash() {
        if (Services.trash !== undefined) Services.trash.open();
        else console.info("[dock] Services.trash missing; open Trash");
    }

    // ---- context menu -----------------------------------------------------------
    // Rebuilt on every open: the window list and Quit depend on the app's state.
    property int _menuIndex: -1
    property bool _menuRestoreFocus: false
    Component { id: itemComp; MenuItem {} }
    Component { id: sepComp; MenuSeparator {} }

    function _addItem(text, iconName, action, extra) {
        const props = Object.assign({ text: text, iconName: iconName }, extra || {});
        const it = itemComp.createObject(null, props);
        it.triggered.connect(action);
        menu.addItem(it);
    }
    function _elide(s, n) { return s.length > n ? s.slice(0, n - 1).replace(/\s+$/, "") + "…" : s; }

    function _openMenu(i) {
        const tile = _tileAt(i);
        if (!tile) return;
        menu.close();
        while (menu.count > 0) menu.removeItem(menu.itemAt(0));
        _menuIndex = i;
        _menuRestoreFocus = tile.activeFocus;

        if (i === list.count) {
            _addItem(qsTr("Open Trash"), "folder-open", root._openTrash);
            _addItem(qsTr("Empty Trash…"), "trash-2", function () {
                if (Services.trash !== undefined) Services.trash.empty();
                else console.info("[dock] Services.trash missing; empty Trash");
            }, { enabled: trash.full || Services.trash === undefined });
        } else {
            const d = _model.get(i);
            const appId = d.appId, pinned = d.pinned, running = d.running;
            const tl = Services.wm.toplevels;
            let wins = 0;
            for (let j = 0; j < tl.count; ++j) {
                const t = tl.get(j);
                if (t.appId !== appId) continue;
                const winId = t.winId;
                _addItem(_elide(t.title || d.name, 44), t.focused ? "check" : "app-window", () => Services.wm.activate(winId));
                ++wins;
            }
            if (wins > 0) menu.addItem(sepComp.createObject(null));
            _addItem(qsTr("New Window"), "plus", () => Services.apps.launch(appId));
            if (pinned) _addItem(qsTr("Remove from Dock"), "pin-off", () => Services.apps.unpin(appId));
            else _addItem(qsTr("Keep in Dock"), "pin", () => Services.apps.pin(appId));
            if (running) {
                menu.addItem(sepComp.createObject(null));
                _addItem(qsTr("Quit"), "x", () => Services.apps.quit(appId));
            }
        }

        menu.parent = tile.iconBox;
        menu.x = Qt.binding(() => Math.round((menu.parent ? menu.parent.width - menu.width : 0) / 2));
        menu.y = Qt.binding(() => -menu.height - Theme.space12);
        menu.open();
    }

    Menu {
        id: menu
        transformOrigin: T.Popup.Bottom
        onClosed: {
            const t = root._tileAt(root._menuIndex);
            if (t && root._menuRestoreFocus) t.forceActiveFocus(Qt.TabFocusReason);
            root._menuIndex = -1;
        }
    }
}

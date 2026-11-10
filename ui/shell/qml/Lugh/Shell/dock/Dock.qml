// Lugh-mode dock (docs/design/lugh-mode.md §1–3): a floating glass capsule at
// the bottom centre with pinned apps, a hairline, running unpinned apps, a
// hairline and the Trash.
//
// Surface contract: the frame anchors this item to the bottom edge, full
// screen width, `implicitHeight` tall. Everything above the pill is
// transparent headroom for the hover label, the context menu and the
// launch-failure toast. The frame reads:
//   exclusiveZone  px to reserve at the bottom (0 when autohide). Follows the
//                  configured `iconSize`, never the shrunk size or magnify.
//   inputRect      the part of the surface that takes pointer input, in this
//                  item's coordinates: the pill down to the screen edge (plus
//                  the few px magnify can grow into), united with the toast
//                  when it shows; a 4 px strip at the edge while auto-hidden;
//                  the whole surface while the context menu is open. It is
//                  built from resting geometry, so it does not change while
//                  the pointer moves.
//   menuOpen       a context menu is open (grab the keyboard while true)
// and may call focusDock() from a keyboard shortcut.
//
// Input: click activates (focus or launch), middle click opens a new window,
// right click (or Menu / Shift+F10 on a focused tile) opens the context menu.
// Keyboard: Left/Right/Home/End move between tiles, Enter/Space activate.
//
// Size: icons are `iconSize` (40–80, default 48). When the apps do not fit the
// screen the icons shrink down to 40, then the app list scrolls sideways with
// faded edges; the Trash always stays.
//
// Magnify is a lens, not a layout: tiles keep their slots (so hit areas never
// move) and each one binds its scale and its sideways displacement to one
// pointer x through two closed-form functions. The point under the cursor
// stays put, neighbours part, the capsule's ends follow. Entering and leaving
// eases one `_magAmount` spring. Nothing is evaluated while the pointer is
// elsewhere; there is no timer and no per-frame loop over the model.
import QtQuick
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: root

    // ---- public -------------------------------------------------------------
    property bool autohide: false
    property bool magnify: true
    property int iconSize: 48
    // True while a window overlaps the dock area (auto-hide only hides then).
    property bool overlapped: Services.wm.dockOverlapped !== undefined ? Services.wm.dockOverlapped : true

    readonly property int padding: 6          // above the icons
    readonly property int bottomMargin: 10    // pill to the screen edge
    readonly property int headroom: 260
    // The resting pill: 6 above the icons, 10 below (the ember lives there).
    readonly property int dockHeight: _cfgSize + padding + _bottomPad
    readonly property int exclusiveZone: autohide ? 0 : dockHeight + bottomMargin
    readonly property bool menuOpen: menu.opened
    readonly property rect inputRect: {
        if (menuOpen) return Qt.rect(0, 0, width, height);
        let r = _revealed ? Qt.rect(_pillHitRect.x, _pillHitRect.y, _pillHitRect.width, height - _pillHitRect.y)
                          : Qt.rect(_pillXTarget, height - _edgeStrip, _baseWTarget, _edgeStrip);
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
    // Force a tile's hover label or open a tile's menu, for demos and
    // screenshots. Index = position in the dock; dock count = the Trash.
    property int _debugHoverIndex: -1
    property int _debugMenuIndex: -1
    // Pretend the pointer rests over the dock at this x (root coords). -1 = off.
    property real _debugPointerX: -1

    readonly property var _model: Services.apps.dock
    readonly property real _maxMag: 1.18
    readonly property int _spacing: Theme.space4
    readonly property int _dividerSlot: 9
    readonly property int _sidePad: Theme.space12   // capsule ends
    readonly property int _bottomPad: 10
    readonly property int _edgeStrip: 4
    readonly property int _labelHeight: 24

    readonly property int _cfgSize: Math.max(40, Math.min(80, iconSize))
    readonly property int _n: _model.count
    // Icons shrink (to 40) before the list starts to scroll.
    readonly property real _avail: Math.max(240, width - 2 * Theme.space24)
    readonly property int _size: Math.max(40, Math.min(_cfgSize,
        Math.floor((_avail - _n * _spacing - (_dividers + 1) * _dividerSlot - 2 * _sidePad) / (_n + 1))))
    readonly property int _pillH: _size + padding + _bottomPad
    readonly property real _pillRestY: height - bottomMargin - _pillH
    readonly property bool _magnify: magnify && !Theme.reduceMotion
    // Room the magnified icons can grow into: above the pill, and sideways.
    readonly property int _topRoom: Math.ceil(_cfgSize * (_maxMag - 1)) + 2
    readonly property int _topGrow: _magnify ? _topRoom : 0
    readonly property int _sideGrow: _magnify ? Math.ceil((_maxMag - 1) * _size / (_size + _spacing) * _range / 2) : 0

    readonly property real _listContentW: _n * _size + Math.max(0, _n - 1) * _spacing + _dividers * _dividerSlot
    readonly property real _listMaxW: _avail - 2 * _sidePad - _spacing - _dividerSlot - _size
    readonly property bool _overflow: _listContentW > _listMaxW
    readonly property real _listWTarget: Math.min(_listContentW, _listMaxW)
    readonly property real _tailW: (_n > 0 ? _spacing + _dividerSlot : 0) + _size + 2 * _sidePad
    readonly property real _baseWTarget: _listWTarget + _tailW
    readonly property real _pillXTarget: Math.round((width - _baseWTarget) / 2)
    // The pill width follows the app list through the liquid spring.
    property real _listW: _listWTarget
    Behavior on _listW {
        enabled: root._ready && !Theme.reduceMotion
        Liquid { epsilon: Theme.springEpsilon }
    }

    implicitHeight: headroom + dockHeight + bottomMargin

    Accessible.role: Accessible.ToolBar
    Accessible.name: qsTr("Dock")

    component Liquid: SpringAnimation {
        spring: Theme.liquidSpring; damping: Theme.liquidDamping; mass: Theme.liquidMass
    }

    on_DebugMenuIndexChanged: if (_debugMenuIndex >= 0) _debugMenuTimer.restart()
    // Animations start after the first layout, so the dock does not grow in
    // from nothing when the shell starts.
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

    // ---- model bookkeeping (only when the model changes) --------------------
    // _pinned[i]: is tile i pinned (for the pinned | running hairline).
    property var _pinned: []
    property int _dividers: 0
    Connections {
        target: root._model
        function onCountChanged() { root._rebuild(); }
        function onDataChanged() { root._rebuild(); }
        function onRowsMoved() { root._rebuild(); }
    }
    function _rebuild() {
        const n = _model.count;
        const pinned = [];
        let dividers = 0, menuAt = -1;
        for (let i = 0; i < n; ++i) {
            const d = _model.get(i);
            pinned.push(d.pinned);
            if (i > 0 && !d.pinned && pinned[i - 1]) ++dividers;
            if (d.appId === _menuAppId) menuAt = i;
        }
        _pinned = pinned;
        _dividers = dividers;
        // The model changed under an open menu: follow the app, or close when
        // it left the dock.
        if (menu.opened) {
            if (_menuAppId === "") _menuIndex = n;
            else if (menuAt < 0) menu.close();
            else _menuIndex = menuAt;
        }
    }
    function _dividerBefore(i, pinnedFlags) {
        return i > 0 && i < pinnedFlags.length && !pinnedFlags[i] && pinnedFlags[i - 1] === true;
    }

    // ---- pointer / reveal (auto-hide) ---------------------------------------
    HoverHandler { id: hover }
    readonly property point _pointer: _debugPointerX >= 0 ? Qt.point(_debugPointerX, _pillRestY + padding + _size / 2) : hover.point.position
    // Hit area from the resting geometry (plus the room magnify grows into),
    // so neither magnify nor the width spring feeds back into the hit test.
    readonly property rect _pillHitRect: Qt.rect(_pillXTarget - _sideGrow, _pillRestY - _topGrow,
                                                 _baseWTarget + 2 * _sideGrow, _pillH + bottomMargin + _topGrow)
    readonly property bool _pointerInDock: _debugPointerX >= 0 || hover.hovered && (_revealed
        ? _contains(_pillHitRect, _pointer) : _pointer.y >= height - _edgeStrip && _contains(_pillHitRect, Qt.point(_pointer.x, height - 1)))
    property bool _hold: false
    // Deferred: _hold changes _revealed, which changes this hit test.
    on_PointerInDockChanged: {
        Qt.callLater(_syncHold);
        // The Trash state is only looked at when the user comes to the dock.
        if (_pointerInDock) Services._call("trash.refresh", []);
    }
    function _syncHold() { if (_pointerInDock) { _hold = true; _hideTimer.stop(); } else _hideTimer.restart(); }
    Component.onDestruction: _hideTimer.stop()
    Timer { id: _hideTimer; interval: 600; onTriggered: root._hold = false }
    // _hold (not _pointerInDock) so the hit test, which depends on whether
    // the dock is revealed, never feeds back into it.
    readonly property bool _revealed: !autohide || !overlapped || _hold || menuOpen
                                      || activeFocus || toast.shown || _debugHoverIndex >= 0 || _debugMenuIndex >= 0
    // Hidden: the pill slides below the edge (liquid); reduce motion fades.
    property real _slide: _revealed || Theme.reduceMotion ? 0 : _pillH + bottomMargin + 24
    Behavior on _slide {
        enabled: root._ready && !Theme.reduceMotion
        Liquid { epsilon: Theme.springEpsilon }
    }

    function _contains(r, p) { return p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height; }
    function _union(a, b) {
        const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
        return Qt.rect(x, y, Math.max(a.x + a.width, b.x + b.width) - x, Math.max(a.y + a.height, b.y + b.height) - y);
    }

    // ---- magnify (a lens around the pointer) --------------------------------
    readonly property bool _magOn: _magnify && _pointerInDock && _revealed && !menuOpen
    property real _magAmount: _magOn ? 1 : 0
    Behavior on _magAmount { Liquid { epsilon: 0.002 } }
    // The last pointer x over the dock, in pill coordinates. It keeps its
    // value when the pointer leaves, so the wave eases out where it was.
    property real _px: 0
    Binding {
        target: root; property: "_px"; value: root._pointer.x
        when: root._pointerInDock
        restoreMode: Binding.RestoreNone
    }
    readonly property real _ppx: _px - pill.x
    readonly property real _range: 2.2 * _size
    // Scale of an icon whose centre is d px from the pointer: raised cosine.
    function _scaleAt(d) {
        const t = Math.abs(d) / _range;
        return t >= 1 ? 1 : 1 + (_maxMag - 1) * _magAmount * (Math.cos(t * Math.PI) + 1) / 2;
    }
    // Sideways displacement at d px from the pointer: the integral of the
    // growth between the pointer and there, so neighbours part by exactly the
    // room the scaled icons need and the point under the cursor does not move.
    function _shiftAt(d) {
        const k = (_maxMag - 1) * _magAmount * _size / (_size + _spacing) / 2;
        if (d >= _range) return k * _range;
        if (d <= -_range) return -k * _range;
        return k * (d + _range / Math.PI * Math.sin(d * Math.PI / _range));
    }

    // ---- hover label --------------------------------------------------------
    // One glass capsule for the whole dock: it appears 300 ms after the
    // pointer rests on a tile (at once for keyboard focus) and then glides
    // from icon to icon instead of fading out and in.
    property Item _hoverTile: null
    property Item _focusTile: null
    function _hover(t, on) { if (on) _hoverTile = t; else if (_hoverTile === t) _hoverTile = null; }
    function _focus(t, on) { if (on) _focusTile = t; else if (_focusTile === t) _focusTile = null; }
    function _tileGone(t) { _hover(t, false); _focus(t, false); }
    readonly property Item _labelTile: _debugHoverIndex >= 0 ? (_ready && list.count >= 0 ? _tileAt(_debugHoverIndex) : null)
                                                             : (_hoverTile || _focusTile)
    property bool _labelOn: false
    property string _labelText: ""
    property real _labelCx: 0
    on_LabelTileChanged: {
        if (_labelTile) {
            _labelHide.stop();
            _labelText = _labelTile.label;
            if (_labelOn) return;
            if (_labelTile === _hoverTile && _debugHoverIndex < 0) _labelShow.restart();
            else _labelOn = true;
        } else {
            _labelShow.stop();
            _labelHide.restart();
        }
    }
    Timer { id: _labelShow; interval: 300; onTriggered: root._labelOn = root._labelTile !== null }
    Timer { id: _labelHide; interval: 150; onTriggered: root._labelOn = false }
    // Resting centre x of a tile's icon, in root coordinates.
    function _centerOf(t) {
        if (!t) return 0;
        const tx = t === trash ? _sidePad + _listWTarget + (_n > 0 ? _spacing : 0) : list.x + t.x - list.contentX;
        return _pillXTarget + tx + t.centerX;
    }
    Binding {
        target: root; property: "_labelCx"; value: root._centerOf(root._labelTile)
        when: root._labelTile !== null
        restoreMode: Binding.RestoreNone
    }

    GlassPanel {
        id: label
        readonly property bool shown: root._labelOn && !root.menuOpen && root._revealed && root._labelText !== ""
        readonly property bool glide: root._labelOn && visible && !Theme.reduceMotion
        readonly property real targetW: Math.min(240, Math.ceil(labelText.implicitWidth)) + 2 * 10
        property real w: targetW
        property real cx: root._labelCx
        Behavior on w { enabled: label.glide; Liquid { epsilon: 0.1 } }
        Behavior on cx { enabled: label.glide; Liquid { epsilon: 0.1 } }

        x: Math.round(Math.max(Theme.space4, Math.min(root.width - w - Theme.space4, cx - w / 2)))
        y: root._pillRestY - root._topGrow - 6 - height
        width: Math.round(w)
        height: root._labelHeight
        radius: height / 2
        elevation: "menu"
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation { duration: Theme.dur(Theme.durMicro); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
        }
        Accessible.ignored: true

        Item {
            anchors.fill: parent
            clip: label.w !== label.targetW
            Text {
                id: labelText
                anchors.centerIn: parent
                width: Math.min(240, Math.ceil(implicitWidth))
                text: root._labelText
                font: Theme.typeCaption
                color: Theme.text
                elide: Text.ElideRight
                textFormat: Text.PlainText
                Accessible.ignored: true
            }
        }
    }

    // ---- toast --------------------------------------------------------------
    DockToast {
        id: toast
        x: Math.round((root.width - width) / 2)
        y: Math.round(root._pillRestY - root._topGrow - 6 - root._labelHeight - Theme.space8 - height)
    }

    // ---- the pill -----------------------------------------------------------
    // `pill` is the resting box (hit areas, layout); the glass capsule inside
    // it also follows the lens at both ends.
    Item {
        id: pill
        x: Math.round((root.width - width) / 2)
        y: root._pillRestY + root._slide
        width: root._listW + root._tailW
        height: root._pillH
        opacity: root._revealed || !Theme.reduceMotion ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durReduced } }

        GlassPanel {
            readonly property real dl: root._magAmount > 0 ? root._shiftAt(-root._ppx) : 0
            readonly property real dr: root._magAmount > 0 ? root._shiftAt(pill.width - root._ppx) : 0
            x: dl
            width: pill.width + dr - dl
            height: pill.height
            radius: height / 2
            elevation: "menu"
        }

        ListView {
            id: list
            x: root._sidePad
            y: -root._topRoom
            width: root._listWTarget
            height: root._topRoom + root._pillH
            orientation: ListView.Horizontal
            spacing: root._spacing
            interactive: root._overflow
            clip: root._overflow
            cacheBuffer: 100000
            model: root._model
            keyNavigationEnabled: false
            boundsBehavior: Flickable.StopAtBounds

            WheelHandler {
                enabled: root._overflow
                onWheel: event => {
                    const d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
                    list.contentX = Math.max(0, Math.min(list.contentWidth - list.width, list.contentX - d / 2));
                }
            }

            delegate: DockItem {
                id: app
                required property int index
                required property var model
                readonly property string appId: model.appId
                // Icon centre in pill coordinates, at rest.
                readonly property real _cx: list.x + x - list.contentX + centerX

                iconName: model.icon
                label: model.name
                running: model.running
                windows: model.windows
                launching: model.launching
                attention: model.attention
                iconSize: root._size
                padding: root.padding
                bottomPadding: root._bottomPad
                topRoom: root._topRoom
                artScale: root._magnify ? root._maxMag : 1
                hoverPlate: !root._magnify
                mag: root._magAmount > 0 ? root._scaleAt(_cx - root._ppx) : 1
                shift: root._magAmount > 0 ? root._shiftAt(_cx - root._ppx) : 0
                dividerShift: root._magAmount > 0 && leadingDivider ? root._shiftAt(_cx - centerX + 2.5 - root._ppx) : 0
                leadingDivider: root._dividerBefore(index, root._pinned)
                focusedApp: Services.wm.focusedAppId === appId
                forceHover: root._debugHoverIndex === index
                accessibleName: root._describe(label, running, windows, launching, attention)

                onActivated: Services.apps.activate(appId)
                onMiddleClicked: Services.apps.launch(appId)
                onContextRequested: root._openMenu(index)
                onHoveredChanged: root._hover(app, hovered)
                onActiveFocusChanged: root._focus(app, activeFocus)
                Component.onDestruction: root._tileGone(app)
                Keys.onPressed: event => root._tileKey(event, index)
            }

            add: Transition {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.dur(Theme.durMedium) }
                Liquid { property: "scale"; from: Theme.reduceMotion ? 1 : 0.5; to: 1; epsilon: 0.002 }
            }
            remove: Transition {
                NumberAnimation { property: "opacity"; to: 0; duration: Theme.dur(Theme.durSmall) }
                NumberAnimation { property: "scale"; to: Theme.reduceMotion ? 1 : 0.5; duration: Theme.durSmall; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
            }
            displaced: Transition {
                NumberAnimation { property: "x"; duration: Theme.dur(Theme.durLarge); easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard }
                NumberAnimation { properties: "opacity,scale"; to: 1; duration: Theme.durMicro }
            }
        }

        // Scrolling list: the icons fade out at the clipped edges.
        component EdgeFade: Rectangle {
            property bool leading: true
            y: root.padding + 1
            width: 28
            height: root._size - 2
            opacity: visible ? 1 : 0
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: leading ? 0 : 1; color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, Theme.dark ? 0.9 : 0.95) }
                GradientStop { position: leading ? 1 : 0; color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0) }
            }
        }
        EdgeFade { x: list.x; visible: root._overflow && list.contentX > 0.5 }
        EdgeFade { x: list.x + list.width - width; leading: false; visible: root._overflow && list.contentX < list.contentWidth - list.width - 0.5 }

        DockItem {
            id: trash
            readonly property bool full: Services.trash !== undefined && Services.trash.full === true
            readonly property real _cx: x + centerX
            x: root._sidePad + root._listW + (root._n > 0 ? root._spacing : 0)
            y: -root._topRoom
            iconName: full ? "user-trash-full" : "user-trash"
            label: qsTr("Trash")
            iconSize: root._size
            padding: root.padding
            bottomPadding: root._bottomPad
            topRoom: root._topRoom
            artScale: root._magnify ? root._maxMag : 1
            hoverPlate: !root._magnify
            mag: root._magAmount > 0 ? root._scaleAt(_cx - root._ppx) : 1
            shift: root._magAmount > 0 ? root._shiftAt(_cx - root._ppx) : 0
            dividerShift: root._magAmount > 0 ? root._shiftAt(x + 2.5 - root._ppx) : 0
            leadingDivider: root._n > 0
            forceHover: root._debugHoverIndex === list.count
            accessibleName: full ? qsTr("Trash, has items") : qsTr("Trash")

            onActivated: root._openTrash()
            onContextRequested: root._openMenu(list.count)
            onHoveredChanged: root._hover(trash, hovered)
            onActiveFocusChanged: root._focus(trash, activeFocus)
            Keys.onPressed: event => root._tileKey(event, list.count)
        }
    }

    // ---- keyboard -----------------------------------------------------------
    function _tileAt(i) { return i === list.count ? trash : list.itemAtIndex(i); }
    function _focusAt(i) {
        const n = list.count + 1;
        i = Math.max(0, Math.min(n - 1, i));
        if (_overflow && i < list.count) list.positionViewAtIndex(i, ListView.Contain);
        const t = _tileAt(i);
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

    // ---- context menu -------------------------------------------------------
    // Built on every open: the window list and Quit depend on the app's state.
    // Actions capture the appId / winId, so they stay right when the model
    // changes while the menu is open.
    property int _menuIndex: -1
    property string _menuAppId: ""
    property bool _menuRestoreFocus: false
    readonly property alias _menu: menu

    function _openMenu(i) {
        const tile = _tileAt(i);
        if (!tile) return;
        const entries = [];
        if (i === list.count) {
            _menuAppId = "";
            entries.push({ text: qsTr("Open Trash"), iconName: "folder-open", action: root._openTrash });
            entries.push({ text: qsTr("Empty Trash…"), iconName: "trash-2", danger: true,
                           enabled: trash.full || Services.trash === undefined,
                           confirm: { title: qsTr("Empty the Trash?"),
                                      body: qsTr("Everything in it is deleted for good. This can’t be undone."),
                                      actionText: qsTr("Empty Trash"),
                                      action: function () {
                                          if (Services.trash !== undefined) Services.trash.empty();
                                          else console.info("[dock] Services.trash missing; empty Trash");
                                      } } });
        } else {
            const d = _model.get(i);
            const appId = d.appId, pinned = d.pinned, running = d.running, name = d.name;
            _menuAppId = appId;
            const tl = Services.wm.toplevels;
            let wins = 0;
            for (let j = 0; j < tl.count; ++j) {
                const t = tl.get(j);
                if (t.appId !== appId) continue;
                const winId = t.winId;
                entries.push({ text: t.title || name, iconName: t.focused ? "check" : "app-window",
                               action: () => Services.wm.activate(winId) });
                ++wins;
            }
            if (wins > 0) entries.push({ separator: true });
            entries.push({ text: qsTr("New Window"), iconName: "plus", action: () => Services.apps.launch(appId) });
            if (pinned) entries.push({ text: qsTr("Remove from Dock"), iconName: "pin-off", action: () => Services.apps.unpin(appId) });
            else entries.push({ text: qsTr("Keep in Dock"), iconName: "pin", action: () => Services.apps.pin(appId) });
            if (running) {
                entries.push({ separator: true });
                entries.push({ text: qsTr("Quit"), iconName: "x", action: () => Services.apps.quit(appId) });
            }
        }
        _menuIndex = i;
        _menuRestoreFocus = tile.activeFocus;
        const p = tile.iconBox.mapToItem(root, 0, 0);
        menu.popup(entries, Qt.rect(p.x, p.y, _size, _size), tile.iconBox.radius,
                   p.x - tile.shift + _size / 2, _pillRestY - Theme.space8);
    }

    DockMenu {
        id: menu
        anchors.fill: parent
        onClosed: {
            const t = root._tileAt(root._menuIndex);
            if (t && root._menuRestoreFocus) t.forceActiveFocus(Qt.TabFocusReason);
            root._menuIndex = -1;
            root._menuAppId = "";
        }
    }
}

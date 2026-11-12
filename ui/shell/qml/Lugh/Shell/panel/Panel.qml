// Lugh-mode bottom Panel: the only bar of the desktop. One glass pill
// floating a few px above the bottom edge (ShellSettings.panelFloating), or an
// edge-to-edge strip.
//
//   left    start button (Lugh mark → Lugh menu; right click → Customize),
//           search (→ launcher, optional), workspace grid (→ overview, wheel
//           switches workspace)
//   middle  pinned + running apps (Services.apps.dock) and the Trash, centered
//           on the screen or right after the left group
//           (ShellSettings.panelAlignment); optional dock-style magnify
//   right   the tray: status icons + clock in one button (→ quick panel), the
//           notification dot, and the OSD (Tray.qml)
//
// Surface contract: the frame anchors this item to the bottom edge, full
// screen width, `implicitHeight` tall. Everything above the pill is
// transparent headroom for the hover label, the context menu and the
// launch-failure toast. The frame reads:
//   exclusiveZone  px to reserve at the bottom (0 when autohide)
//   inputRect      the part of the surface that takes pointer input, in this
//                  item's coordinates: the pill down to the screen edge (and
//                  the room magnify grows into), united with the toast; a 4 px
//                  strip at the edge while auto-hidden; the whole surface
//                  while a menu is open. Built from resting geometry, so it
//                  does not change while the pointer moves.
//   inputRects     the same as a list of rects (tighter: the magnify room
//                  only over the apps); the frame prefers it
//   menuOpen       a context menu is open (keyboard on demand while true)
//   keyboardMode   the panel holds the keyboard (Super+B): the frame makes
//                  its window keyboard-exclusive and activates it while true
//   wantsKeyboard  keyboardMode || menuOpen
//   screenHeight   set by the frame to the output's height, so the rects
//                  published to ShellState are in output-local coordinates
//                  (each overlay window covers its own output; default: this
//                  item's window, right for the preview and demos)
//   publish        true only on the active output (Services.wm.activeOutput,
//                  primary when unknown): that panel feeds ShellState and
//                  answers ShellState.focusPanelRequested
// and may call focusPanel() from a keyboard shortcut.
//
// ShellState: logoIsland = start button, centerIsland = clock, statusIsland =
// tray, panelRect = the resting pill, panelReserved = the room the panel
// takes at the bottom when shown (barHeight + bottomMargin, also while
// auto-hidden: overlays reveal the panel, so they must stand above it);
// overlays open just above them.
//
// Input: apps: click activates (focus or launch), middle click opens a new
// window, right click (or Menu / Shift+F10) opens the context menu. Right
// click on the empty panel opens the panel menu. Keyboard (Super+B, or Tab
// in the preview): the start button takes focus; Left/Right/Home/End and
// Tab/Shift+Tab move across every item, Enter/Space activate, Menu /
// Shift+F10 open the context menu, PageUp/PageDown on the workspace grid
// switch workspace, Esc gives the keyboard back to the previous window.
//
// Magnify is a lens, not a layout (ported from the old dock): tiles keep
// their slots and bind scale and sideways shift to one pointer x through two
// closed-form functions; one `_magAmount` spring eases it in and out.
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell
import "../dock"

FocusScope {
    id: root

    // ---- public -------------------------------------------------------------
    property bool autohide: ShellSettings.panelAutohide
    property bool magnify: ShellSettings.panelMagnify
    property bool floating: ShellSettings.panelFloating
    property string alignment: ShellSettings.panelAlignment
    // True while a window overlaps the panel area (auto-hide only hides then).
    property bool overlapped: Services.wm.dockOverlapped !== undefined ? Services.wm.dockOverlapped : true
    property real screenHeight: Window.window ? Window.window.height : height
    property bool publish: true
    // The panel holds the keyboard (focusPanel()); cleared by Esc, by
    // activating an item and when an overlay opens or the window loses focus.
    property bool keyboardMode: false
    readonly property bool wantsKeyboard: keyboardMode || menuOpen

    readonly property int barHeight: Math.max(36, Math.min(72, ShellSettings.panelHeight))
    readonly property int bottomMargin: floating ? Theme.space8 : 0
    readonly property int sideMargin: floating ? Theme.space8 : 0
    readonly property int headroom: 240
    readonly property int exclusiveZone: autohide ? 0 : barHeight + bottomMargin
    readonly property bool menuOpen: menu.opened
    readonly property rect inputRect: {
        if (menuOpen) return Qt.rect(0, 0, width, height);
        let r = _revealed ? Qt.rect(_pillX, _pillRestY - _topGrow, _pillW, height - _pillRestY + _topGrow)
                          : Qt.rect(0, height - _edgeStrip, width, _edgeStrip);
        if (toast.visible) r = _union(r, _toastRect);
        return r;
    }
    readonly property var inputRects: {
        if (menuOpen) return [Qt.rect(0, 0, width, height)];
        if (!_revealed) return [Qt.rect(0, height - _edgeStrip, width, _edgeStrip)];
        const out = [Qt.rect(_pillX, _pillRestY, _pillW, height - _pillRestY)];
        if (_topGrow > 0) out.push(Qt.rect(_pillX + apps.x - _sideGrow, _pillRestY - _topGrow, apps.width + 2 * _sideGrow, _topGrow));
        if (toast.visible) out.push(_toastRect);
        return out;
    }

    // Keyboard entry point (Super+B → ShellState.focusPanelRequested): take
    // the keyboard and focus the first item (the start button).
    function focusPanel() {
        keyboardMode = true;
        _hadFocus = false;
        _focusNav(0);
    }
    // Esc / activation: give the keyboard back (the compositor refocuses the
    // previous window once the frame drops keyboard interactivity).
    function releaseKeyboard() {
        keyboardMode = false;
        _hadFocus = false;
        if (_focusTile || activeFocus) focusSink.forceActiveFocus();
    }
    // Shows the inline "<App> couldn't start" toast (also wired to
    // Services.apps.launchFailed).
    function showLaunchError(appId, message) {
        toast.show(Services.apps.nameFor(appId), message);
    }

    // ---- private / debug ----------------------------------------------------
    // Force a tile's hover label or open a tile's menu, for demos and
    // screenshots. Index = position in the app list; app count = the Trash.
    property int _debugHoverIndex: -1
    property int _debugMenuIndex: -1
    // Pretend the pointer rests over the panel at this x (root coords). -1 = off.
    property real _debugPointerX: -1

    readonly property var _model: Services.apps.dock
    readonly property real _magCap: 1.45
    readonly property int _pad: floating ? Theme.space8 : Theme.space8 - 2   // pill ends
    readonly property int _gap: Theme.space12                                // between groups
    readonly property int _spacing: Theme.space8 - 2                         // between tiles
    readonly property int _dividerSlot: 9
    readonly property int _edgeStrip: 4
    readonly property int _labelHeight: 24
    readonly property int _btnH: barHeight - 2 * Math.max(Theme.space4, Math.round(barHeight * 0.125))

    readonly property real _pillX: sideMargin
    readonly property real _pillW: Math.max(0, width - 2 * sideMargin)
    readonly property real _pillRestY: height - bottomMargin - barHeight

    // App list geometry. Icons shrink (to 20) before the list scrolls.
    readonly property int _cfgSize: Math.max(16, Math.min(barHeight - 12, ShellSettings.panelIconSize))
    readonly property int _n: _model.count
    readonly property real _appsAvail: Math.max(0, _pillW - 2 * _pad - leftRow.width - tray.restingWidth - 2 * _gap)
    readonly property int _size: Math.max(20, Math.min(_cfgSize,
        Math.floor((_appsAvail - _n * _spacing - (_dividers + 1) * _dividerSlot) / (_n + 1))))
    readonly property int _tilePad: Math.max(2, Math.min(Math.floor((barHeight - _size) / 2), barHeight - _size - 8))
    readonly property bool _magnify: magnify && !Theme.reduceMotion
    // The lens pushes the outer tiles out by up to _sideGrow on each side.
    // Bounded by the free room between the app group and its neighbours
    // (start/workspaces on the left, the tray on the right), so with many
    // apps the magnification shrinks instead of covering them:
    //   _sideGrow = (m − 1) · size / (size + spacing) / 2 · range  ≤  room
    readonly property real _sideRoom: {
        const leftEdge = leftRow.width > 0 ? _pad + leftRow.width + Theme.space4 : 0;
        const rightEdge = _pillW - _pad - tray.restingWidth - Theme.space4;
        return Math.max(0, Math.min(_appsXTarget - leftEdge, rightEdge - _appsXTarget - _appsWTarget));
    }
    readonly property real _maxMag: !_magnify ? 1
        : Math.max(1, Math.min(_magCap, 1 + 2 * _sideRoom * (_size + _spacing) / (_size * 2.2 * _size)))
    readonly property int _topRoom: _magnify ? Math.ceil(_cfgSize * (_maxMag - 1)) + 2 : 0
    readonly property int _topGrow: _topRoom
    readonly property int _sideGrow: _magnify ? Math.ceil((_maxMag - 1) * _size / (_size + _spacing) * _range / 2) : 0
    readonly property real _listContentW: _n * _size + Math.max(0, _n - 1) * _spacing + _dividers * _dividerSlot
    readonly property real _tailW: (_n > 0 ? _spacing + _dividerSlot : 0) + _size
    readonly property real _listMaxW: Math.max(0, _appsAvail - _tailW)
    readonly property bool _overflow: _listContentW > _listMaxW + 0.5
    readonly property real _listWTarget: Math.min(_listContentW, _listMaxW)
    readonly property real _appsWTarget: _listWTarget + _tailW
    // Where the app group sits in the pill: centered on the screen, kept
    // clear of the left group and the tray.
    readonly property real _appsMinX: _pad + leftRow.width + (leftRow.width > 0 ? _gap : 0)
    readonly property real _appsMaxX: _pillW - _pad - tray.restingWidth - _gap - _appsWTarget
    readonly property real _appsXTarget: alignment === "left" ? _appsMinX
        : Math.round(Math.max(_appsMinX, Math.min(_appsMaxX, width / 2 - _pillX - _appsWTarget / 2)))
    // The app group's width follows the list through the liquid spring.
    property real _listW: _listWTarget
    Behavior on _listW {
        enabled: root._ready && !Theme.reduceMotion
        Liquid { epsilon: Theme.springEpsilon }
    }

    implicitHeight: headroom + barHeight + bottomMargin

    Accessible.role: Accessible.ToolBar
    Accessible.name: qsTr("Panel")

    component Liquid: SpringAnimation {
        spring: Theme.liquidSpring; damping: Theme.liquidDamping; mass: Theme.liquidMass
    }

    on_DebugMenuIndexChanged: if (_debugMenuIndex >= 0) _debugMenuTimer.restart()
    // Animations start after the first layout, so nothing grows in from
    // nothing when the shell starts.
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
    Connections {
        target: ShellState
        function onFocusPanelRequested() { if (root.publish) root.focusPanel(); }
        // An overlay takes the keyboard itself.
        function onAnyOverlayOpenChanged() { if (ShellState.anyOverlayOpen && root.keyboardMode) root.releaseKeyboard(); }
    }
    // Keyboard mode ends when the panel loses focus after having had it
    // (the user clicked a window, another surface took the keyboard).
    property bool _hadFocus: false
    onActiveFocusChanged: {
        if (!keyboardMode) return;
        if (activeFocus) _hadFocus = true;
        else if (_hadFocus) Qt.callLater(() => { if (!root.activeFocus && root._hadFocus) root.releaseKeyboard(); });
    }
    // Takes focus from the items when the keyboard is given back.
    Item { id: focusSink; objectName: "focusSink"; Accessible.ignored: true }
    // On Hyprland the window is activated only after keyboard mode asked
    // for it: focus the item again then, as a Tab focus (focus ring shows).
    Connections {
        target: root.Window.window
        ignoreUnknownSignals: true
        function onActiveChanged() {
            if (!root.keyboardMode || !root.Window.window.active) return;
            const i = root._navItems().indexOf(root._focusTile);
            root._focusNav(i >= 0 ? i : 0);
        }
    }

    // ---- ShellState: geometry in screen coordinates ---------------------------
    // Item rect in the resting pill → screen rect. The panel window is
    // anchored to the bottom edge, so its top sits at screenHeight − height.
    function _toScreen(item) {
        if (!item || !item.visible) return Qt.rect(0, 0, 0, 0);
        const p = item.mapToItem(pill, 0, 0);
        return Qt.rect(Math.round(_pillX + p.x), Math.round(screenHeight - height + _pillRestY + p.y),
                       Math.round(item.width), Math.round(item.height));
    }
    // Everything the rects depend on (mapToItem itself is not a binding).
    readonly property var _geom: [width, height, screenHeight, barHeight, _pillW, leftRow.x, leftRow.width,
                                  startBtn.x, startBtn.width, tray.x, tray.width, tray.clockItem.width]
    readonly property rect _startRect: {
        _geom;
        return startBtn.visible ? _toScreen(startBtn)
            : Qt.rect(_pillX + _pad, screenHeight - height + _pillRestY + (barHeight - _btnH) / 2, _btnH, _btnH);
    }
    readonly property rect _clockRect: { _geom; return _toScreen(tray.clockItem); }
    readonly property rect _trayRect: { _geom; return _toScreen(tray); }
    readonly property rect _panelRect: Qt.rect(_pillX, screenHeight - height + _pillRestY, _pillW, barHeight)
    // RestoreNone: when the active output changes, the panel that stops
    // publishing must not write its old values back over the new one's.
    Binding { target: ShellState; property: "logoIsland"; value: root._startRect; when: root.publish; restoreMode: Binding.RestoreNone }
    Binding { target: ShellState; property: "centerIsland"; value: root._clockRect; when: root.publish; restoreMode: Binding.RestoreNone }
    Binding { target: ShellState; property: "statusIsland"; value: root._trayRect; when: root.publish; restoreMode: Binding.RestoreNone }
    Binding { target: ShellState; property: "panelRect"; value: root._panelRect; when: root.publish; restoreMode: Binding.RestoreNone }
    // Not exclusiveZone: auto-hidden, the panel reserves nothing for windows
    // but is revealed under every open overlay, which must stand above it.
    Binding { target: ShellState; property: "panelReserved"; value: root.barHeight + root.bottomMargin; when: root.publish; restoreMode: Binding.RestoreNone }

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
        // The model changed under an open app menu: follow the app, or close
        // when it left the panel.
        if (menu.opened && _menuIndex >= 0) {
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
    readonly property point _pointer: _debugPointerX >= 0 ? Qt.point(_debugPointerX, _pillRestY + barHeight / 2) : hover.point.position
    readonly property rect _pillHitRect: Qt.rect(_pillX, _pillRestY - _topGrow, _pillW, height - _pillRestY + _topGrow)
    readonly property bool _pointerInPanel: _debugPointerX >= 0 || hover.hovered && (_revealed
        ? _contains(_pillHitRect, _pointer) : _pointer.y >= height - _edgeStrip)
    property bool _hold: false
    // Deferred: _hold changes _revealed, which changes this hit test.
    on_PointerInPanelChanged: {
        Qt.callLater(_syncHold);
        // The Trash state is only looked at when the user comes to the panel.
        if (_pointerInPanel) Services._call("trash.refresh", []);
    }
    function _syncHold() { if (_pointerInPanel) { _hold = true; _hideTimer.stop(); } else _hideTimer.restart(); }
    Component.onDestruction: _hideTimer.stop()
    Timer { id: _hideTimer; interval: 600; onTriggered: root._hold = false }
    readonly property bool _revealed: !autohide || !overlapped || _hold || menuOpen || keyboardMode || _focusTile !== null
                                      || toast.shown || ShellState.anyOverlayOpen
                                      || _debugHoverIndex >= 0 || _debugMenuIndex >= 0
    // Hidden: the pill slides below the edge (liquid); reduce motion fades.
    property real _slide: _revealed || Theme.reduceMotion ? 0 : barHeight + bottomMargin + 24
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
    readonly property bool _magOn: _magnify && _pointerInPanel && _revealed && !menuOpen
    property real _magAmount: _magOn ? 1 : 0
    Behavior on _magAmount { Liquid { epsilon: 0.002 } }
    // The last pointer x over the panel, in pill coordinates; kept when the
    // pointer leaves, so the wave eases out where it was.
    property real _px: 0
    Binding {
        target: root; property: "_px"; value: root._pointer.x
        when: root._pointerInPanel
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
    // room the scaled icons need.
    function _shiftAt(d) {
        const k = (_maxMag - 1) * _magAmount * _size / (_size + _spacing) / 2;
        if (d >= _range) return k * _range;
        if (d <= -_range) return -k * _range;
        return k * (d + _range / Math.PI * Math.sin(d * Math.PI / _range));
    }

    // ---- hover label --------------------------------------------------------
    // One glass capsule for the whole panel: it appears 300 ms after the
    // pointer rests on an item (at once for keyboard focus) and then glides
    // from item to item instead of fading out and in.
    property Item _hoverTile: null
    property Item _focusTile: null
    function _hover(t, on) { if (on) _hoverTile = t; else if (_hoverTile === t) _hoverTile = null; }
    function _focus(t, on) { if (on) _focusTile = t; else if (_focusTile === t) _focusTile = null; }
    function _tileGone(t) { _hover(t, false); _focus(t, false); }
    readonly property Item _labelTile: _debugHoverIndex >= 0 ? (_ready && list.count >= 0 && list.contentWidth >= 0 ? _tileAt(_debugHoverIndex) : null)
                                                             : (_hoverTile || _focusTile)
    readonly property string _liveLabel: _labelTile ? _labelTile.label : ""
    on_LiveLabelChanged: if (_liveLabel !== "") _labelText = _liveLabel
    property bool _labelOn: false
    property string _labelText: ""
    property real _labelCx: 0
    on_LabelTileChanged: {
        if (_labelTile) {
            _labelHide.stop();
            if (_liveLabel !== "") _labelText = _liveLabel;
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
    // Resting centre x of an item, in root coordinates.
    function _centerOf(t) {
        if (!t) return 0;
        return t.mapToItem(pill, t.centerX, 0).x + _pillX;
    }
    Binding {
        target: root; property: "_labelCx"
        value: { list.contentX; apps.x; root._listW; root.width; return root._centerOf(root._labelTile); }
        when: root._labelTile !== null
        restoreMode: Binding.RestoreNone
    }

    GlassPanel {
        id: label
        readonly property bool shown: root._labelOn && !root.menuOpen && root._revealed && root._labelText !== ""
                                      && (root._labelTile === null || root._liveLabel !== "")
        readonly property bool glide: root._labelOn && visible && !Theme.reduceMotion
        readonly property real targetW: Math.min(260, Math.ceil(labelText.implicitWidth)) + 2 * 10
        property real w: targetW
        property real cx: root._labelCx
        Behavior on w { enabled: label.glide; Liquid { epsilon: 0.1 } }
        Behavior on cx { enabled: label.glide; Liquid { epsilon: 0.1 } }

        x: Math.round(Math.max(Theme.space4, Math.min(root.width - w - Theme.space4, cx - w / 2)))
        y: root._pillRestY - root._topGrow - Theme.space8 - height
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
                width: Math.min(260, Math.ceil(implicitWidth))
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
    readonly property rect _toastRect: Qt.rect(toast.x, toast.y, toast.width, toast.height)
    DockToast {
        id: toast
        x: Math.round((root.width - width) / 2)
        y: Math.round(root._pillRestY - root._topGrow - Theme.space8 - root._labelHeight - Theme.space8 - height)
    }

    // ---- the pill -----------------------------------------------------------
    Item {
        id: pill
        x: root._pillX
        y: root._pillRestY + root._slide
        width: root._pillW
        height: root.barHeight
        opacity: root._revealed || !Theme.reduceMotion ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durReduced } }

        GlassPanel {
            anchors.fill: parent
            radius: root.floating ? height / 2 : 0
            elevation: root.floating ? "menu" : "none"
        }

        // Right click on the empty panel: the panel menu. Under every item,
        // so the items' own clicks win.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: event => root._openPanelMenu(event.x)
        }

        // ---- left: start · search · workspaces --------------------------------
        Row {
            id: leftRow
            x: root._pad
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space2

            PanelButton {
                id: startBtn
                objectName: "start"
                visible: ShellSettings.panelShowStart
                height: root._btnH
                width: Math.max(height, implicitWidth)
                radius: root.floating ? height / 2 : Theme.radiusMd
                label: qsTr("Lugh menu")
                active: ShellState.lughMenuOpen
                Accessible.description: qsTr("About Lugh, settings, lock, log out, restart and shut down; right click to customize the panel")
                onClicked: ShellState.toggleLughMenu()
                onContextRequested: ShellState.openCustomize("panel")
                onHoveredChanged: root._hover(startBtn, hovered)
                onActiveFocusChanged: root._focus(startBtn, activeFocus)
                Keys.onPressed: event => root._navKey(event, startBtn)

                contentItem: Item {
                    implicitWidth: 18
                    implicitHeight: 18
                    Image {
                        // The mark fills ~60% of the SVG box.
                        readonly property int box: root._btnH >= 34 ? 30 : 26
                        x: Math.round((parent.width - width) / 2)
                        y: Math.round((parent.height - height) / 2)
                        width: box
                        height: box
                        source: Theme.dark ? "../bar/assets/lugh-logo-dark.svg" : "../bar/assets/lugh-logo.svg"
                        sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
                        smooth: true
                    }
                }
            }
            PanelButton {
                id: searchBtn
                objectName: "search"
                visible: ShellSettings.panelShowSearch
                height: root._btnH
                width: Math.max(height, implicitWidth)
                radius: root.floating ? height / 2 : Theme.radiusMd
                label: qsTr("Search")
                active: ShellState.launcherOpen
                Accessible.description: qsTr("Search apps, files and settings")
                onClicked: ShellState.toggleLauncher(true)
                onContextRequested: root._openPanelMenu(leftRow.x + x + width / 2)
                onHoveredChanged: root._hover(searchBtn, hovered)
                onActiveFocusChanged: root._focus(searchBtn, activeFocus)
                Keys.onPressed: event => root._navKey(event, searchBtn)
                contentItem: Item {
                    implicitWidth: 18
                    implicitHeight: 18
                    Icon { anchors.centerIn: parent; name: "search"; size: 18; color: Theme.text }
                }
            }
            WorkspaceGrid {
                id: wsGrid
                objectName: "workspaces"
                visible: ShellSettings.panelShowWorkspaces
                height: root._btnH
                radius: root.floating ? height / 2 : Theme.radiusMd
                onContextRequested: ShellState.openCustomize("workspaces")
                onHoveredChanged: root._hover(wsGrid, hovered)
                onActiveFocusChanged: root._focus(wsGrid, activeFocus)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
                        wsGrid.step(event.key === Qt.Key_PageUp ? -1 : 1);
                        event.accepted = true;
                    } else root._navKey(event, wsGrid);
                }
            }
        }

        // ---- middle: apps + Trash ------------------------------------------------
        Item {
            id: apps
            x: root._appsXTarget
            width: root._listW + root._tailW
            height: parent.height
            Behavior on x {
                enabled: root._ready && !Theme.reduceMotion
                Liquid { epsilon: Theme.springEpsilon }
            }

            ListView {
                id: list
                y: -root._topRoom
                width: root._listWTarget
                height: root._topRoom + root.barHeight
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
                    readonly property real _cx: apps.x + list.x + x - list.contentX + centerX

                    iconName: model.icon
                    label: model.name
                    running: model.running && ShellSettings.panelShowRunningIndicator
                    windows: model.windows
                    launching: model.launching
                    attention: model.attention
                    iconSize: root._size
                    padding: root._tilePad
                    bottomPadding: root.barHeight - root._tilePad - root._size
                    topRoom: root._topRoom
                    artScale: root._magnify ? root._maxMag : 1
                    hoverPlate: !root._magnify
                    mag: root._magAmount > 0 ? root._scaleAt(_cx - root._ppx) : 1
                    shift: root._magAmount > 0 ? root._shiftAt(_cx - root._ppx) : 0
                    dividerShift: root._magAmount > 0 && leadingDivider ? root._shiftAt(_cx - centerX + 2.5 - root._ppx) : 0
                    leadingDivider: root._dividerBefore(index, root._pinned)
                    focusedApp: Services.wm.focusedAppId === appId
                    forceHover: root._debugHoverIndex === index
                    accessibleName: root._describe(label, model.running, windows, launching, attention)

                    onActivated: Services.apps.activate(appId)
                    onMiddleClicked: Services.apps.launch(appId)
                    onContextRequested: root._openMenu(index)
                    onHoveredChanged: root._hover(app, hovered)
                    onActiveFocusChanged: root._focus(app, activeFocus)
                    Component.onDestruction: root._tileGone(app)
                    Keys.onPressed: event => root._navKey(event, app)
                }

                // The group opens first (its width springs), then the icon grows in.
                add: Transition {
                    SequentialAnimation {
                        PropertyAction { property: "opacity"; value: 0 }
                        PauseAnimation { duration: Theme.reduceMotion ? 0 : 110 }
                        ParallelAnimation {
                            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.dur(Theme.durSmall) }
                            Liquid { property: "scale"; from: Theme.reduceMotion ? 1 : 0.5; to: 1; epsilon: 0.002 }
                        }
                    }
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
                y: root._tilePad + 1
                width: 24
                height: root._size - 2
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
                readonly property real _cx: apps.x + x + centerX
                x: root._listW + (root._n > 0 ? root._spacing : 0)
                y: -root._topRoom
                iconName: full ? "user-trash-full" : "user-trash"
                label: qsTr("Trash")
                iconSize: root._size
                padding: root._tilePad
                bottomPadding: root.barHeight - root._tilePad - root._size
                topRoom: root._topRoom
                artScale: root._magnify ? root._maxMag : 1
                hoverPlate: !root._magnify
                mag: root._magAmount > 0 ? root._scaleAt(_cx - root._ppx) : 1
                shift: root._magAmount > 0 ? root._shiftAt(_cx - root._ppx) : 0
                dividerShift: root._magAmount > 0 ? root._shiftAt(apps.x + x + 2.5 - root._ppx) : 0
                leadingDivider: root._n > 0
                forceHover: root._debugHoverIndex === list.count
                accessibleName: full ? qsTr("Trash, has items") : qsTr("Trash")

                onActivated: root._openTrash()
                onContextRequested: root._openMenu(list.count)
                onHoveredChanged: root._hover(trash, hovered)
                onActiveFocusChanged: root._focus(trash, activeFocus)
                Keys.onPressed: event => root._navKey(event, trash)
            }
        }

        // ---- right: the tray --------------------------------------------------------
        Tray {
            id: tray
            objectName: "tray"
            x: parent.width - root._pad - width
            anchors.verticalCenter: parent.verticalCenter
            height: root._btnH
            radius: root.floating ? height / 2 : Theme.radiusMd
            onContextRequested: ShellState.openCustomize("clock")
            onHoveredChanged: root._hover(tray, hovered)
            onActiveFocusChanged: root._focus(tray, activeFocus)
            Keys.onPressed: event => root._navKey(event, tray)
        }
    }

    // ---- keyboard -----------------------------------------------------------
    function _tileAt(i) { return i === list.count ? trash : list.itemAtIndex(i); }
    // Every focusable item, left to right.
    function _navItems() {
        const out = [];
        for (const b of [startBtn, searchBtn, wsGrid]) if (b.visible) out.push(b);
        for (let i = 0; i < list.count; ++i) { const t = list.itemAtIndex(i); if (t) out.push(t); }
        out.push(trash, tray);
        return out;
    }
    function _focusNav(i) {
        const items = _navItems();
        i = Math.max(0, Math.min(items.length - 1, i));
        const t = items[i];
        if (!t) return;
        if (_overflow && t.index !== undefined && t !== trash) list.positionViewAtIndex(t.index, ListView.Contain);
        t.forceActiveFocus(Qt.TabFocusReason);
    }
    function _navKey(event, item) {
        const k = event.key;
        const items = _navItems();
        const i = items.indexOf(item);
        const isTile = item === trash || (item.appId !== undefined && item.index !== undefined);
        if (k === Qt.Key_Left) _focusNav(i - 1);
        else if (k === Qt.Key_Right) _focusNav(i + 1);
        else if (k === Qt.Key_Home) _focusNav(0);
        else if (k === Qt.Key_End) _focusNav(items.length - 1);
        // Tab cycles (the panel is its own focus chain).
        else if (k === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)) _focusNav((i + 1) % items.length);
        else if (k === Qt.Key_Backtab || k === Qt.Key_Tab) _focusNav((i - 1 + items.length) % items.length);
        else if (k === Qt.Key_Escape) releaseKeyboard();
        else if (isTile && (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space)) {
            // The app (or the file manager) takes the keyboard.
            releaseKeyboard();
            item.activated();
        } else if (k === Qt.Key_Menu || (k === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            if (item === trash) _openMenu(list.count);
            else if (isTile) _openMenu(item.index);
            else item.contextRequested();
        } else return;
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
        else console.info("[panel] Services.trash missing; open Trash");
    }

    // ---- context menus -------------------------------------------------------
    // Built on every open: the window list and Quit depend on the app's state.
    // Actions capture the appId / winId, so they stay right when the model
    // changes while the menu is open. _menuIndex −1 = the panel menu.
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
                                          else console.info("[panel] Services.trash missing; empty Trash");
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
            if (pinned) entries.push({ text: qsTr("Unpin from Panel"), iconName: "pin-off", action: () => Services.apps.unpin(appId) });
            else entries.push({ text: qsTr("Pin to Panel"), iconName: "pin", action: () => Services.apps.pin(appId) });
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
    // The panel's own menu (right click on empty space), at pill x `px`.
    function _openPanelMenu(px) {
        const entries = [
            { text: qsTr("Customize Panel…"), iconName: "settings", action: () => ShellState.openCustomize("panel") },
            { separator: true },
            { text: qsTr("Auto-hide"), iconName: ShellSettings.panelAutohide ? "check" : "",
              action: () => ShellSettings.panelAutohide = !ShellSettings.panelAutohide },
            { text: qsTr("Floating"), iconName: ShellSettings.panelFloating ? "check" : "",
              action: () => ShellSettings.panelFloating = !ShellSettings.panelFloating },
            { text: qsTr("Magnify Icons"), iconName: ShellSettings.panelMagnify ? "check" : "",
              action: () => ShellSettings.panelMagnify = !ShellSettings.panelMagnify },
            { separator: true },
            { text: ShellSettings.panelAlignment === "left" ? qsTr("Center Apps") : qsTr("Align Apps Left"),
              iconName: ShellSettings.panelAlignment === "left" ? "align-center" : "align-left",
              action: () => ShellSettings.panelAlignment = ShellSettings.panelAlignment === "left" ? "center" : "left" }
        ];
        _menuIndex = -1;
        _menuAppId = "";
        _menuRestoreFocus = false;
        const cx = _pillX + px;
        menu.popup(entries, Qt.rect(cx - 4, _pillRestY + barHeight / 2 - 4, 8, 8), 4, cx, _pillRestY - Theme.space8);
    }

    DockMenu {
        id: menu
        anchors.fill: parent
        onClosed: {
            const t = root._menuIndex >= 0 ? root._tileAt(root._menuIndex) : null;
            if (t && root._menuRestoreFocus) t.forceActiveFocus(Qt.TabFocusReason);
            root._menuIndex = -1;
            root._menuAppId = "";
        }
    }
}

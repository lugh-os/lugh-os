// Launcher (Lugh mode, Super+Space): a compact search panel centered a
// little above the middle of the screen, clear of the bottom panel
// (docs/design/lugh-mode.md §2/§3, shell spec §Launcher).
//
//   Launcher { anchors.fill: parent }   // the frame anchors it to the screen
//
// Fullscreen overlay root. Opens when ShellState.launcherOpen; closes on Esc
// (after clearing a non-empty query), an outside click, or after activating
// a result. The frame maps the layer surface while `shown` and gives it the
// keyboard while `wantsKeyboard`. `query` is the field text; `panelItem` is
// the glass panel (for frames that draw a backdrop under it).
//
// Motion: the panel is laid out at its final rect from the first frame and
// the whole of it (glass, field and body together) scales up and fades in
// (durMedium; closing durSmall). Opened from the start button
// (ShellState.launcherFromPanel, when the shell publishes it) it grows out
// of ShellState.logoIsland's side; otherwise from its own center. Results
// change only the panel's height, which eases (durSmall) and never moves its
// top. Reduce motion: fades only. Geometry follows the screen live; nothing
// animates while the screen is resized.
//
// Open-to-typing (NFR-2, ≤ 100 ms): the panel and its SearchField always
// exist, so the field has focus on the first frame and keys typed during the
// opening land in it; only the views under the field live in an asynchronous
// Loader created at startup (finished synchronously if it is opened first).
//
// Results are asynchronous with a live backend: search() returns at once and
// the model is patched a moment later. `resultsCurrent` says whether the
// model belongs to the text in the field; until it does, Enter is remembered
// and fires on the top result once the answer arrives, and clicks on the old
// rows are ignored. A stale row is never activated.
//
// Keys: ↑/↓ move (wrap) · PageUp/PageDown · Tab/Shift+Tab jump groups ·
// Enter activates · Ctrl+Enter secondary action · Esc clears, then closes.
// With an empty query, the arrows/Tab move across the recent apps.
import QtQuick
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: root

    readonly property bool open: ShellState.launcherOpen
    // Open, or still animating out.
    readonly property bool shown: open || _t > 0
    readonly property bool wantsKeyboard: open
    // The query text (ShowLauncher(query) arrives through Services.shell.pendingQuery).
    property alias query: field.text
    readonly property Item panelItem: panel

    property int panelWidth: 600
    property int maxResultsHeight: 396

    // True when Services.launcher.results answers the text in the field.
    readonly property bool resultsCurrent: _hasResultsQuery ? Services.launcher.resultsQuery === field.text
                                                            : _arrived

    focus: true
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Search")

    readonly property int _headerHeight: 48

    // ---- geometry -----------------------------------------------------------
    // Everything follows the screen size live. The panel's top stays put
    // while results change its height: it is placed for its tallest size, a
    // little above the middle of the space over the bottom panel.
    readonly property int _availBottom: Math.max(0, height - ShellState.panelReserved - Theme.space16)
    readonly property int _panelW: Math.max(0, Math.min(panelWidth, width - 2 * Theme.space24))
    readonly property int _maxBodyHeight: Math.max(136, Math.min(maxResultsHeight,
        _availBottom - Theme.space24 - _headerHeight - 1))
    readonly property int _panelY: Math.max(Theme.space16,
        Math.round((_availBottom - (_headerHeight + 1 + _maxBodyHeight)) * 0.42))
    readonly property real _bodyHeight: body.item ? body.item.targetHeight : 0
    readonly property real _panelHeight: _headerHeight + (_bodyHeight > 0 ? _bodyHeight + 1 : 0)

    // No Behavior runs while the screen changes size (resolution, rotation,
    // scale): the layout snaps to the new geometry.
    property bool _resizing: false
    onWidthChanged: _geometryChanged()
    onHeightChanged: _geometryChanged()
    function _geometryChanged() { _resizing = true; resizeSettle.restart(); }
    Timer { id: resizeSettle; interval: 200; onTriggered: root._resizing = false }

    // ---- open / close ------------------------------------------------------
    // _t: 0 = gone, 1 = open. Scale, offset and opacity of the whole panel
    // derive from it, so the shape and its content always move as one.
    property real _t: 0
    // Where this opening came from (latched, so closing returns the same way).
    property bool _fromLogo: false
    property bool _ready: false

    onOpenChanged: if (_ready) { if (open) _show(); else _hide(); }
    Component.onCompleted: {
        _ready = true;
        if (open) { _prepare(); _t = 1; }
    }

    function _show() {
        _prepare();
        tAnim.stop();
        tAnim.to = 1;
        tAnim.duration = Theme.dur(Theme.durMedium);
        tAnim.easing.bezierCurve = Theme.easeStandard;
        tAnim.start();
    }
    function _hide() {
        _enterPending = false;
        tAnim.stop();
        tAnim.to = 0;
        tAnim.duration = Theme.dur(Theme.durSmall);
        tAnim.easing.bezierCurve = Theme.easeStandard;
        tAnim.start();
    }
    NumberAnimation {
        id: tAnim
        target: root
        property: "_t"
        easing.type: Easing.BezierSpline
    }

    function _prepare() {
        _enterPending = false;
        // Opening: never half-built. A body still loading finishes now.
        if (body.status === Loader.Loading) body.asynchronous = false;
        if (_t === 0) {
            const lg = ShellState.logoIsland;
            _fromLogo = ("launcherFromPanel" in ShellState) && ShellState.launcherFromPanel === true
                        && lg.width > 0 && lg.height > 0;
        }
        const q = Services.shell.pendingQuery;
        if (q !== "") Services.shell.pendingQuery = "";
        if (field.text !== q) field.text = q;      // searches via onTextChanged
        else Services.launcher.search(q);
        field.cursorPosition = field.length;
        if (body.item) body.item.reset();
        field.forceActiveFocus(Qt.OtherFocusReason);
        // The frame may make the surface visible after this handler runs;
        // invisible items can't take focus, so retry before the next frame.
        Qt.callLater(() => { if (root.open && !field.activeFocus) field.forceActiveFocus(Qt.OtherFocusReason); });
    }
    function close() { ShellState.launcherOpen = false; }

    // ---- activation ----------------------------------------------------------
    function _activateResult(index, secondary) {
        if (!open || !resultsCurrent) return;      // never a stale row
        if (index < 0 || index >= Services.launcher.results.count) return;
        if (secondary) Services.launcher.activateSecondary(index);
        else Services.launcher.activate(index);
        close();
    }
    function _activateRecent(appId) {
        Services.apps.activate(appId);
        close();
    }

    // Enter pressed before the answer for the current text arrived.
    property bool _enterPending: false
    property bool _enterSecondary: false
    function _firePending() {
        if (!_enterPending || !open || !resultsCurrent) return;
        _enterPending = false;
        if (Services.launcher.results.count > 0) _activateResult(0, _enterSecondary);
    }
    // The model may still be mid-patch when this flips: act after the turn.
    onResultsCurrentChanged: if (resultsCurrent && _enterPending) Qt.callLater(_firePending)

    // Fallback while Services.launcher has no `resultsQuery`: Services drops
    // patches for older queries, so any model change after a live search is
    // the answer; an identical answer changes nothing, so silence counts too.
    readonly property bool _hasResultsQuery: "resultsQuery" in Services.launcher
    property bool _arrived: true
    Timer { id: arriveTimer; interval: 150; onTriggered: root._arrived = true }
    Connections {
        target: Services.launcher.results
        enabled: !root._arrived
        function onCountChanged() { root._arrived = true; }
        function onDataChanged() { root._arrived = true; }
        function onRowsMoved() { root._arrived = true; }
    }

    // ---- scene ---------------------------------------------------------------
    // A breath of scrim: the panel's glass and shadow do the separating.
    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        opacity: root._t * (Theme.dark ? 0.12 : 0.14)
        visible: opacity > 0
    }

    // Outside click closes (the panel swallows its own clicks).
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: ShellState.closeAll()
    }

    GlassPanel {
        id: panel
        x: Math.round((root.width - width) / 2)
        y: root._panelY
        width: root._panelW
        height: root._panelHeight
        radius: Theme.radiusXl
        elevation: "window"
        // Visible while shown even at _t = 0, so the field can take focus on
        // the opening turn; opacity keeps it unseen until the first frame.
        visible: root.shown
        // Opening reaches full opacity early; closing fades evenly.
        opacity: Math.min(1, root._t * (root.open ? 1.5 : 1))

        // Results reshape the panel by easing its height only (top fixed).
        // Not while opening from nothing, resizing, or under reduce motion.
        Behavior on height {
            enabled: root.open && root._t > 0 && !root._resizing && !Theme.reduceMotion
            NumberAnimation {
                duration: Theme.dur(Theme.durSmall)
                easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
            }
        }

        // Grows out of the start button's side (scale pinned to the panel
        // point nearest the button, drifting from it) or out of its center.
        readonly property bool _move: !Theme.reduceMotion && !root._resizing
        readonly property point _pivot: {
            if (!root._fromLogo) return Qt.point(width / 2, height / 2);
            const lg = ShellState.logoIsland;
            const gx = lg.x + lg.width / 2 - x, gy = lg.y + lg.height / 2 - y;
            return Qt.point(Math.max(0, Math.min(width, gx)), Math.max(0, Math.min(height, gy)));
        }
        readonly property real _s: !_move ? 1 : 1 - (1 - root._t) * (root._fromLogo ? 0.12 : 0.05)
        readonly property real _shiftY: !_move ? 0 : (1 - root._t) * (root._fromLogo ? 28 : 10)
        transform: [
            Scale {
                origin.x: panel._pivot.x
                origin.y: panel._pivot.y
                xScale: panel._s
                yScale: panel._s
            },
            Translate { y: panel._shiftY }
        ]

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => { wheel.accepted = true }
        }

        SearchField {
            id: field
            // The search glyph sits on the result icons' axis.
            x: 1
            width: parent.width - 2
            height: root._headerHeight
            large: true
            focus: true
            font: Qt.font({ family: Theme.fontUi, pixelSize: 18, weight: Theme.typeBody.weight })
            placeholderText: qsTr("Search apps, files and settings")
            busy: busyDelay.elapsed && Services.launcher.searching

            onTextChanged: {
                root._enterPending = false;
                if (Services.live && !root._hasResultsQuery) {
                    root._arrived = false;
                    arriveTimer.restart();
                }
                Services.launcher.search(text);
            }

            // Esc with text: the field clears it (SearchField), and a
            // frame-level Esc shortcut must not steal the key.
            Keys.onShortcutOverride: event => {
                event.accepted = event.key === Qt.Key_Escape && field.length > 0;
            }
            Keys.onPressed: event => {
                const enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter;
                if (event.key === Qt.Key_Escape) {   // only reached when empty
                    root.close();
                    event.accepted = true;
                } else if (enter && field.text.trim() !== "" && !root.resultsCurrent) {
                    root._enterSecondary = (event.modifiers & Qt.ControlModifier) !== 0;
                    root._enterPending = true;
                    event.accepted = true;
                } else if (body.item && body.item.handleKey(event)) {
                    event.accepted = true;
                }
            }
        }

        // Spinner only after 300 ms of searching (spec §States).
        Timer {
            id: busyDelay
            property bool elapsed: false
            interval: 300
            running: Services.launcher.searching
            onRunningChanged: if (running) elapsed = false
            onTriggered: elapsed = true
        }

        Rectangle {
            y: root._headerHeight
            width: parent.width
            height: 1
            color: Theme.glassBorder
            visible: root._bodyHeight > 0
        }

        // The body is laid out at its own height at once; the panel's height
        // eases after it and this clip reveals or trims it.
        Item {
            y: root._headerHeight + 1
            width: parent.width
            height: Math.max(0, parent.height - y)
            clip: true

            Loader {
                id: body
                width: parent.width
                asynchronous: true
                onLoaded: if (root.open) item.reset()
                sourceComponent: LauncherBody {
                    query: field.text
                    results: Services.launcher.results
                    recent: Services.launcher.recent
                    searching: Services.launcher.searching
                    current: root.resultsCurrent
                    maxResultsHeight: root._maxBodyHeight
                    onActivateResult: (index, secondary) => root._activateResult(index, secondary)
                    onActivateRecent: appId => root._activateRecent(appId)
                }
            }
        }
    }
}

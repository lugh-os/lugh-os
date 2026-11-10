// Launcher (Lugh mode, Super+Space): a compact search panel that drops out
// of the center island (docs/design/lugh-mode.md §2/§3, shell spec §Launcher).
//
//   Launcher { anchors.fill: parent }   // the frame anchors it to the screen
//
// Fullscreen overlay root. Opens when ShellState.launcherOpen; closes on Esc
// (after clearing a non-empty query), an outside click, or after activating
// a result. The frame maps the layer surface while `shown` and gives it the
// keyboard while `wantsKeyboard`. `query` is the field text; `panelItem` is
// the glass panel (for frames that draw a backdrop under it).
//
// Open-to-typing (NFR-2, ≤ 100 ms): the MorphPanel and its SearchField always
// exist, so the field has focus on the first frame and keys typed during the
// morph land in it; only the views under the field live in an asynchronous
// Loader created at startup.
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
    // Open, or still morphing back into the island.
    readonly property bool shown: open || morph.shown
    readonly property bool wantsKeyboard: open
    // The query text (ShowLauncher(query) arrives through Services.shell.pendingQuery).
    property alias query: field.text
    readonly property Item panelItem: morph._panel

    property int panelWidth: 600
    property real topFraction: 0.18
    property int maxResultsHeight: 396

    // True when Services.launcher.results answers the text in the field.
    readonly property bool resultsCurrent: _hasResultsQuery ? Services.launcher.resultsQuery === field.text
                                                            : _arrived

    focus: true
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Search")

    readonly property int _headerHeight: 48

    // ---- geometry -----------------------------------------------------------
    // The island the panel drops out of (centered when the bar has not
    // published one yet).
    readonly property rect _origin: {
        const c = ShellState.centerIsland;
        return c.x > 0 ? c : Qt.rect(Math.round((width - c.width) / 2), c.y, c.width, c.height);
    }
    readonly property int _panelY: Math.max(Math.round(height * topFraction), _origin.y + _origin.height + Theme.space12)
    readonly property real _bodyHeight: body.item ? body.item.targetHeight : 0
    readonly property rect _wantRect: {
        const w = Math.max(0, Math.min(panelWidth, width - 2 * Theme.space24));
        return Qt.rect(Math.round((width - w) / 2), _panelY, w,
                       _headerHeight + (_bodyHeight > 0 ? _bodyHeight + 1 : 0));
    }
    // MorphPanel springs to a new rect, but follows one that changes again
    // within 100 ms directly (it would snap mid-morph). Changes are therefore
    // coalesced per event-loop turn (a search rebuilds the model row by row)
    // and spaced at least 120 ms apart; each one retargets the liquid spring.
    property double _lastApply: 0
    function _applyRect(force) {
        const r = _wantRect, t = morph.targetRect;
        if (r.x === t.x && r.y === t.y && r.width === t.width && r.height === t.height) return;
        const wait = 120 - (Date.now() - _lastApply);
        if (force !== true && morph.shown && wait > 0) {
            if (!rectTimer.running) { rectTimer.interval = wait; rectTimer.start(); }
            return;
        }
        rectTimer.stop();
        _lastApply = Date.now();
        morph.targetRect = r;
    }
    on_WantRectChanged: Qt.callLater(_applyRect)
    Timer { id: rectTimer; onTriggered: root._applyRect() }

    // ---- open / close ------------------------------------------------------
    property bool _morphOpen: false
    onOpenChanged: {
        if (open) _prepare();
        else { _enterPending = false; _morphOpen = false; }
    }
    Component.onCompleted: {
        _applyRect(true);
        if (open) _prepare();
    }

    function _prepare() {
        _enterPending = false;
        const q = Services.shell.pendingQuery;
        if (q !== "") Services.shell.pendingQuery = "";
        if (field.text !== q) field.text = q;      // searches via onTextChanged
        else Services.launcher.search(q);
        field.cursorPosition = field.length;
        if (body.item) body.item.reset();
        _applyRect(true);
        _morphOpen = true;
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
        opacity: root.open ? (Theme.dark ? 0.12 : 0.14) : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation { duration: Theme.reduceMotion ? Theme.durReduced : Theme.durSmall }
        }
    }

    // Outside click closes (the panel swallows its own clicks).
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: ShellState.closeAll()
    }

    MorphPanel {
        id: morph
        anchors.fill: parent
        open: root._morphOpen
        originRect: root._origin
        radius: Theme.radiusXl
        elevation: "window"

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

        // The body is laid out at its own height at once; the panel (which
        // clips while it moves) springs after it.
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
                    // Never past the bottom of a short screen.
                    maxResultsHeight: Math.max(136, Math.min(root.maxResultsHeight,
                        root.height - root._panelY - root._headerHeight - Theme.space48))
                    onActivateResult: (index, secondary) => root._activateResult(index, secondary)
                    onActivateRecent: appId => root._activateRecent(appId)
                }
            }
        }
    }
}

// Workspace overview (Super+Tab), in the spirit of KDE Plasma's overview: the
// desktop dims and blurs, and the workspace grid (ShellSettings.workspaceRows
// × workspaceCols, row by row: 1 2 / 3 4) appears as miniature screens with
// their windows drawn as tiles.
//
//   Overview { anchors.fill: parent }   // frame maps it while `shown`
//
// Surface contract: `shown` (open, or its close animation still running) and
// `wantsKeyboard` (open). Opens on ShellState.overviewOpen
// (Services.shell.showOverview() toggles it: the compositor's Super+Tab).
//
// Interaction:
//   arrows / Tab      move the selection in the grid (wraps with
//                     ShellSettings.workspaceWrap)
//   Enter / Space     switch to the selected workspace and close
//   1–9               switch to that workspace and close (when not searching)
//   typing            filters windows by title / app; Enter then activates
//                     the first match; Esc clears the search, then closes
//   click a card      switch to it; click a window: activate it
//   drag a window     onto another card: Services.wm.moveToWorkspace
//   hover a window    shows its close button
//   click outside     close
//
// Workspaces: the backend (Services.wm.workspaces) does not know the grid
// size, so the grid's workspaces are synthesised here (1 … rows × cols), with
// names from Services.wm.workspaces when it has them. With
// ShellSettings.overviewShowEmpty off, only occupied workspaces and the active
// one are shown, flowed into at most `workspaceCols` columns.
// Workspaces past the grid that hold windows or are active (opened by an app
// or a script, or left over after the grid shrank) get smaller cards in an
// "Other workspaces" strip under the grid, with the same interactions: no
// window is ever left out. Arrows move between the grid and the strip.
//
// Window tiles use the toplevel geometry roles (x, y, width, height relative
// to their monitor; monitorWidth / monitorHeight); windows without geometry
// are auto-arranged in a grid inside the card.
//
// Motion: the backdrop fades; cards fade and scale from 0.96, the active card
// zooms out of the screen (220 ms in, 180 ms out). Theme.reduceMotion: fade
// only. Everything is laid out before the first frame: the window list is
// rebuilt synchronously on open, and the card lists (gridIds, otherIds) are
// only reassigned when their contents change, so opening never re-creates the
// cards (whose wallpapers load asynchronously). Nothing animates at rest.
//
// Glass: the compositor blurs behind the layer (layer rule for
// `lugh-overview`); in previews Theme.backdrop (the pre-blurred wallpaper) is
// drawn under the tint instead.
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: root

    // ---- surface contract -------------------------------------------------------
    readonly property bool open: ShellState.overviewOpen
    readonly property bool shown: open || reveal > 0
    readonly property bool wantsKeyboard: open

    // Previews: load the wallpaper art from the repo (no lugh-branding).
    property bool previewArt: false

    // ---- state ------------------------------------------------------------------------
    // 0 = closed, 1 = open; drives every enter/exit property.
    property real reveal: 0
    // Workspace id under the keyboard selection.
    property int selected: Services.wm.activeWorkspace
    // Filter text (lower-cased for matching in `_matches`).
    property alias query: field.text
    readonly property string _q: query.trim().toLowerCase()
    // Rebuilt from Services.wm.toplevels: { wsId: [window, …] }.
    property var windowsByWs: ({})
    // Drag of a window tile.
    property var dragWin: null          // the window row being dragged
    property int dropWs: 0              // card under the pointer while dragging

    // ---- grid ---------------------------------------------------------------------------
    readonly property int gridRows: Math.max(1, ShellSettings.workspaceRows)
    readonly property int gridCols: Math.max(1, ShellSettings.workspaceCols)
    readonly property int gridCount: gridRows * gridCols
    // Workspace ids of the grid's cards, in grid order, and of the strip's
    // (past the grid), ascending. Assigned from the wanted lists below only
    // when they differ, so the Repeaters keep their cards.
    property var gridIds: []
    property var otherIds: []
    readonly property var _gridWanted: {
        const out = [];
        const by = windowsByWs, act = Services.wm.activeWorkspace;
        for (let id = 1; id <= gridCount; ++id)
            if (ShellSettings.overviewShowEmpty || id === act || (by[id] && by[id].length > 0))
                out.push(id);
        return out;
    }
    readonly property var _otherWanted: {
        const out = [];
        const by = windowsByWs, act = Services.wm.activeWorkspace;
        for (const k in by) {
            const id = Number(k);
            if (id > gridCount && by[k].length > 0) out.push(id);
        }
        if (act > gridCount && out.indexOf(act) < 0) out.push(act);
        return out.sort((a, b) => a - b);
    }
    function _syncCells() {
        if (_gridWanted.join() !== gridIds.join()) gridIds = _gridWanted;
        if (_otherWanted.join() !== otherIds.join()) otherIds = _otherWanted;
    }
    on_GridWantedChanged: _syncCells()
    on_OtherWantedChanged: _syncCells()
    // Every card's workspace id: the grid's, then the strip's (index order of
    // cellRect()).
    readonly property var cells: gridIds.concat(otherIds)
    readonly property int gridN: gridIds.length
    readonly property int cols: ShellSettings.overviewShowEmpty ? gridCols : Math.max(1, Math.min(gridCols, gridN))
    readonly property int rows: gridN > 0 ? Math.ceil(gridN / cols) : 0

    // Layout (px).
    readonly property int sideMargin: width < 1000 ? Theme.space32 : Theme.space64
    readonly property int headerHeight: Theme.space24 + 40 + Theme.space24
    readonly property int footerHeight: ShellState.panelReserved + Theme.space16 + 20 + Theme.space16
    readonly property int gapX: Theme.space32
    readonly property int gapY: Theme.space16
    readonly property int labelHeight: 36
    readonly property real screenAspect: width > 0 && height > 0 ? width / height : 16 / 9
    readonly property real availHeight: height - headerHeight - footerHeight

    // "Other workspaces" strip: one row of small cards, shrunk to fit the width.
    readonly property int stripTitleHeight: 28
    readonly property int stripGap: Theme.space16
    readonly property real stripCardWidth: {
        const n = otherIds.length;
        if (n === 0) return 0;
        const want = Math.round(Math.max(54, Math.min(120, height * 0.1))) * screenAspect;
        return Math.max(48, Math.min(want, (width - 2 * sideMargin - (n - 1) * stripGap) / n));
    }
    readonly property real stripCardHeight: stripCardWidth / screenAspect
    readonly property real stripHeight: otherIds.length === 0 ? 0
        : (gridN > 0 ? Theme.space24 : 0) + stripTitleHeight + stripCardHeight + labelHeight

    readonly property real cardWidth: {
        const r = Math.max(1, rows);
        const availW = width - 2 * sideMargin - (cols - 1) * gapX;
        const availH = availHeight - stripHeight - (r - 1) * gapY - r * labelHeight;
        return Math.max(64, Math.min(availW / cols, (availH / r) * screenAspect));
    }
    readonly property real cardHeight: cardWidth / screenAspect
    readonly property real gridWidth: rows > 0 ? cols * cardWidth + (cols - 1) * gapX : 0
    readonly property real gridHeight: rows > 0 ? rows * (cardHeight + labelHeight) + (rows - 1) * gapY : 0
    readonly property real gridX: Math.round((width - gridWidth) / 2)
    // Grid and strip are centred together in the space between header and footer.
    readonly property real gridY: Math.round(headerHeight + Math.max(0, (availHeight - gridHeight - stripHeight) / 2))
    readonly property real stripY: gridY + gridHeight + (gridN > 0 ? Theme.space24 : 0)
    readonly property real stripCardsY: stripY + stripTitleHeight
    readonly property real stripX: {
        const n = otherIds.length;
        return Math.round((width - (n * stripCardWidth + Math.max(0, n - 1) * stripGap)) / 2);
    }

    // The miniature screen of card `index` in `cells` order.
    function cellRect(index) {
        if (index >= gridN) {
            const j = index - gridN;
            return Qt.rect(stripX + j * (stripCardWidth + stripGap), stripCardsY, stripCardWidth, stripCardHeight);
        }
        const r = Math.floor(index / cols), c = index % cols;
        return Qt.rect(gridX + c * (cardWidth + gapX), gridY + r * (cardHeight + labelHeight + gapY),
                       cardWidth, cardHeight);
    }

    // ---- workspace helpers ---------------------------------------------------------------
    function wsName(id) {
        const m = Services.wm.workspaces;
        for (let i = 0; i < m.count; ++i) {
            const w = m.get(i);
            if (w.wsId === id && w.name !== "" && w.name !== String(id)) return w.name;
        }
        return qsTr("Desktop %1").arg(id);
    }
    function _matches(w) {
        if (_q === "") return true;
        return w.title.toLowerCase().indexOf(_q) >= 0 || w.appName.toLowerCase().indexOf(_q) >= 0
            || w.appId.toLowerCase().indexOf(_q) >= 0;
    }
    function matchCount(id) {
        const l = windowsByWs[id] || [];
        let n = 0;
        for (const w of l) if (_matches(w)) ++n;
        return n;
    }

    function rebuild() {
        const by = {};
        const m = Services.wm.toplevels;
        for (let i = 0; i < m.count; ++i) {
            const t = m.get(i);
            if (t.workspace < 1) continue;   // special workspaces (minimized)
            const w = {
                winId: t.winId, appId: t.appId, title: t.title, focused: t.focused,
                appName: Services.apps.nameFor(t.appId), icon: Services.apps.iconFor(t.appId),
                x: t.x || 0, y: t.y || 0, width: t.width || 0, height: t.height || 0,
                monitorWidth: t.monitorWidth || 0, monitorHeight: t.monitorHeight || 0,
                order: i,
            };
            (by[t.workspace] = by[t.workspace] || []).push(w);
        }
        // Focused window last, so it is drawn on top.
        for (const k in by) by[k].sort((a, b) => (a.focused - b.focused) || (a.order - b.order));
        windowsByWs = by;
        _syncCells();
    }
    // Tracked while closed too (debounced), so the cards for occupied
    // workspaces (strip, hidden-empty grid) already exist, wallpapers loaded,
    // when the overview opens.
    Timer { id: rebuildLater; interval: root.shown ? 0 : 250; onTriggered: root.rebuild() }
    Connections {
        target: Services.wm.toplevels
        function onCountChanged() { rebuildLater.restart(); }
        function onDataChanged() { rebuildLater.restart(); }
        function onRowsMoved() { rebuildLater.restart(); }
        function onModelReset() { rebuildLater.restart(); }
    }

    // ---- actions -------------------------------------------------------------------------
    function close() { ShellState.overviewOpen = false; }
    function switchTo(id) {
        if (id < 1) return;
        if (id !== Services.wm.activeWorkspace) Services.wm.switchWorkspace(id);
        close();
    }
    function activateWindow(winId) {
        Services.wm.activate(winId);
        close();
    }
    function closeWindow(winId) { Services.wm.close(winId); }
    function moveWindow(winId, id) {
        Services.wm.moveToWorkspace(winId, id);
        rebuild();
    }

    // Rows of card indices as laid out: the grid's rows (the last may be
    // short), then the strip.
    function _layoutRows() {
        const out = [];
        for (let i = 0; i < gridN; i += cols) {
            const row = [];
            for (let j = i; j < Math.min(gridN, i + cols); ++j) row.push(j);
            out.push(row);
        }
        if (otherIds.length > 0) {
            const row = [];
            for (let j = gridN; j < cells.length; ++j) row.push(j);
            out.push(row);
        }
        return out;
    }
    // Arrow keys: within a row by position, between rows to the card whose
    // centre is nearest (rows differ in length and card size). Wraps with
    // ShellSettings.workspaceWrap, else stops at the edges.
    function move(dc, dr) {
        const all = cells;
        if (all.length === 0) return;
        const lines = _layoutRows();
        let i = Math.max(0, all.indexOf(selected));
        let r = lines.findIndex(l => l.indexOf(i) >= 0);
        const wrap = ShellSettings.workspaceWrap;
        if (dc !== 0) {
            const l = lines[r], len = l.length;
            let c = l.indexOf(i) + dc;
            c = wrap ? (c + len) % len : Math.max(0, Math.min(len - 1, c));
            i = l[c];
        }
        if (dr !== 0) {
            const n = lines.length;
            let r2 = r + dr;
            r2 = wrap ? (r2 + n) % n : Math.max(0, Math.min(n - 1, r2));
            if (r2 !== r) {
                const from = cellRect(i), cx = from.x + from.width / 2;
                let best = lines[r2][0], bestD = Infinity;
                for (const j of lines[r2]) {
                    const rc = cellRect(j), d = Math.abs(rc.x + rc.width / 2 - cx);
                    if (d < bestD) { bestD = d; best = j; }
                }
                i = best;
            }
        }
        selected = all[i];
    }
    function step(d) {
        const n = cells.length;
        if (n === 0) return;
        const i = Math.max(0, cells.indexOf(selected));
        selected = cells[(i + d + n) % n];
    }
    function firstMatch() {
        for (const id of cells)
            for (const w of (windowsByWs[id] || []).slice().reverse())
                if (_matches(w)) return w;
        return null;
    }

    function handleKey(event) {
        const k = event.key, mods = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
        if (k === Qt.Key_Escape) {
            if (query !== "") query = "";
            else close();
        } else if (k === Qt.Key_Tab && (event.modifiers & Qt.MetaModifier)) {
            close();                                   // Super+Tab again
        } else if (k === Qt.Key_Left) move(-1, 0);
        else if (k === Qt.Key_Right) move(1, 0);
        else if (k === Qt.Key_Up) move(0, -1);
        else if (k === Qt.Key_Down) move(0, 1);
        else if (k === Qt.Key_Tab) step(1);
        else if (k === Qt.Key_Backtab) step(-1);
        else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            const w = _q !== "" ? firstMatch() : null;
            if (w) activateWindow(w.winId);
            else switchTo(selected);
        } else if (k === Qt.Key_Space && query === "") switchTo(selected);
        else if (k >= Qt.Key_1 && k <= Qt.Key_9 && query === "" && mods === 0) {
            const id = k - Qt.Key_0;
            if (id <= gridCount) switchTo(id);
        } else if (k === Qt.Key_Backspace && !field.activeFocus) {
            query = query.slice(0, -1);
        } else if (!field.activeFocus && mods === 0 && event.text.length > 0 && event.text.charCodeAt(0) >= 32) {
            query += event.text;
        } else {
            return;
        }
        event.accepted = true;
    }
    Keys.onPressed: event => root.handleKey(event)

    // ---- open / close ----------------------------------------------------------------------
    NumberAnimation {
        id: revealAnim
        target: root
        property: "reveal"
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Theme.easeStandard
    }
    function _enter() {
        rebuild();
        query = "";
        dragWin = null;
        selected = Services.wm.activeWorkspace;
        revealAnim.stop();
        root.forceActiveFocus();
        // Cards' wallpapers decode asynchronously; normally they are long
        // loaded (the surface is preloaded closed), but on a first open right
        // after loading, hold the reveal at 0 until they are up (at most
        // ~160 ms) so no card appears blank and fills in afterwards.
        if (reveal > 0 || _wallsReady()) _startReveal();
        else wallGate.restart();
    }
    function _startReveal() {
        wallGate.stop();
        revealAnim.duration = Theme.dur(220);
        revealAnim.to = 1;
        revealAnim.start();
    }
    function _wallsReady() {
        for (const rep of [cards, others])
            for (let i = 0; i < rep.count; ++i) {
                const c = rep.itemAt(i);
                if (c && !c.wallReady) return false;
            }
        return true;
    }
    Timer {
        id: wallGate
        interval: 16
        repeat: true
        property int ticks: 0
        onRunningChanged: if (running) ticks = 0
        onTriggered: if (++ticks >= 10 || root._wallsReady()) root._startReveal()
    }
    function _leave() {
        wallGate.stop();
        revealAnim.stop();
        revealAnim.duration = Theme.dur(180);
        revealAnim.to = 0;
        revealAnim.start();
    }
    onOpenChanged: open ? _enter() : _leave()
    Component.onCompleted: open ? _enter() : rebuild()

    // ---- backdrop --------------------------------------------------------------------------
    Item {
        id: backdrop
        anchors.fill: parent
        opacity: root.reveal
        visible: opacity > 0

        // Preview only: the compositor's blur, simulated.
        ShaderEffectSource {
            anchors.fill: parent
            visible: Theme.backdrop !== null && Theme.transparency
            sourceItem: visible ? Theme.backdrop : null
            hideSource: false
            live: false
        }
        Rectangle {
            anchors.fill: parent
            color: !Theme.transparency ? Theme.bg
                 : Theme.dark ? Qt.rgba(20 / 255, 19 / 255, 17 / 255, 0.64)
                 : Qt.rgba(247 / 255, 246 / 255, 243 / 255, 0.58)
        }
    }
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.close()
    }

    // ---- header: search --------------------------------------------------------------------
    SearchField {
        id: field
        width: Math.min(420, root.width - 2 * root.sideMargin)
        x: Math.round((root.width - width) / 2)
        y: Theme.space24 - (1 - root.reveal) * (Theme.reduceMotion ? 0 : 8)
        opacity: root.reveal
        visible: opacity > 0
        placeholderText: qsTr("Search windows")
        Accessible.name: qsTr("Search windows")
        Keys.onPressed: event => {
            const k = event.key;
            if (k === Qt.Key_Up || k === Qt.Key_Down || k === Qt.Key_Return || k === Qt.Key_Enter
                || k === Qt.Key_Tab || k === Qt.Key_Backtab || (k === Qt.Key_Escape && text === "")) {
                root.handleKey(event);
            }
        }
    }

    // ---- the grid ----------------------------------------------------------------------------
    Repeater {
        id: cards
        model: root.gridIds
        delegate: WorkspaceCard {}
    }

    // Workspaces past the grid.
    Text {
        x: root.stripX
        y: root.stripY + (root.stripTitleHeight - height) / 2 - Theme.space4
        width: Math.max(implicitWidth, root.width - 2 * root.stripX)
        visible: root.otherIds.length > 0 && root.reveal > 0
        opacity: root.reveal
        text: qsTr("Other workspaces")
        elide: Text.ElideRight
        font: Theme.typeBodyStrong
        color: Theme.textMuted
        Accessible.role: Accessible.Heading
    }
    Repeater {
        id: others
        model: root.otherIds
        delegate: WorkspaceCard { offset: root.gridN }
    }

    // Nothing matches the search.
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.min(root.height - root.footerHeight, root.gridY + root.gridHeight + root.stripHeight + Theme.space8)
        visible: root._q !== "" && root.firstMatch() === null && root.reveal > 0
        text: qsTr("No windows match “%1”").arg(root.query.trim())
        font: Theme.typeBody
        color: Theme.textMuted
    }

    // Keyboard hints.
    Row {
        id: hints
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height - root.footerHeight + Theme.space16
        spacing: Theme.space24
        opacity: root.reveal
        visible: opacity > 0 && root.width >= 720
        Repeater {
            model: [
                { k: "← ↑ ↓ →", t: qsTr("Choose") },
                { k: "Enter", t: qsTr("Switch") },
                { k: qsTr("Drag"), t: qsTr("Move a window") },
                { k: "Esc", t: qsTr("Close") },
            ]
            delegate: Row {
                required property var modelData
                spacing: Theme.space8
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: keyText.implicitWidth + 2 * Theme.space8
                    height: 20
                    radius: Theme.radiusSm
                    color: Theme.dark ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.06)
                    border.width: 1
                    border.color: Theme.glassBorder
                    Text {
                        id: keyText
                        anchors.centerIn: parent
                        text: modelData.k
                        font: Theme.typeCaptionTnum
                        color: Theme.text
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.t
                    font: Theme.typeCaption
                    color: Theme.textMuted
                }
            }
        }
    }

    // Window tile following the pointer while dragging.
    Rectangle {
        id: ghost
        visible: root.dragWin !== null
        z: 100
        width: 132
        height: 84
        radius: Theme.radiusMd
        color: Theme.surface
        border.width: 2
        border.color: root.dropWs > 0 ? Theme.accent : Theme.border
        opacity: 0.94
        Column {
            anchors.centerIn: parent
            width: parent.width - 2 * Theme.space8
            spacing: Theme.space4
            AppIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                size: 32
                iconName: root.dragWin ? root.dragWin.icon : ""
                fallbackText: root.dragWin ? root.dragWin.appName : ""
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.dragWin ? (root.dragWin.title || root.dragWin.appName) : ""
                font: Theme.typeCaption
                color: Theme.text
            }
        }
    }
    function cardAt(px, py) {
        for (let i = 0; i < cells.length; ++i) {
            const r = cellRect(i);
            if (px >= r.x && px < r.x + r.width && py >= r.y && py < r.y + r.height + labelHeight)
                return cells[i];
        }
        return 0;
    }

    // ===========================================================================================
    component WorkspaceCard: Item {
        id: card
        required property int modelData
        required property int index
        property int offset: 0          // strip cards: index in `cells` = offset + index
        readonly property bool wallReady: wall.ready
        readonly property int wsId: modelData
        readonly property rect cell: root.cellRect(offset + index)
        readonly property var wins: root.windowsByWs[wsId] || []
        readonly property bool active: wsId === Services.wm.activeWorkspace
        readonly property bool isSelected: wsId === root.selected
        readonly property bool isDrop: root.dragWin !== null && root.dropWs === wsId
        readonly property int matches: root._q === "" ? wins.length : root.matchCount(wsId)
        readonly property bool dimmed: root._q !== "" && matches === 0

        // Enter / exit: the active card zooms out of the screen, the others
        // scale up from 0.96. Reduced motion: fade only.
        readonly property real t: root.reveal
        readonly property real _zoom: active && !Theme.reduceMotion ? 0.45 * (1 - t) : 0
        readonly property real _scale: Theme.reduceMotion ? 1 : active ? 1 : 0.96 + 0.04 * t

        x: cell.x * (1 - _zoom)
        y: cell.y * (1 - _zoom)
        width: cell.width + _zoom * (root.width - cell.width)
        height: cell.height + _zoom * (root.height - cell.height)
        scale: _scale
        // The zooming active card is opaque by a third of the way, so the
        // cards it still overlaps don't show through it.
        opacity: (_zoom > 0 || (active && !Theme.reduceMotion) ? Math.min(1, 3 * t) : t) * (dimmed ? 0.45 : 1)
        visible: root.reveal > 0
        z: active ? 2 : 1

        Accessible.role: Accessible.Button
        Accessible.name: {
            const n = wins.length;
            let s = root.wsName(wsId) + ", " + (n === 0 ? qsTr("empty") : n === 1 ? qsTr("1 window") : qsTr("%1 windows").arg(n));
            if (active) s += ", " + qsTr("current");
            return s;
        }

        // Keyboard selection ring (outside the card).
        Rectangle {
            anchors.fill: screenRect
            anchors.margins: -(Theme.focusRingOffset + 3)
            radius: screenRect.radius + Theme.focusRingOffset + 3
            color: "transparent"
            border.width: 3
            border.color: Theme.focusRing
            visible: card.isSelected && root.dragWin === null
        }

        // The miniature screen.
        Rectangle {
            id: screenRect
            width: card.width
            height: card.height
            radius: Theme.radiusMd
            color: Theme.surface2
            clip: true

            Wallpaper {
                id: wall
                anchors.fill: parent
                _useRepo: root.previewArt
            }
            // Hover / drop feedback.
            Rectangle {
                anchors.fill: parent
                color: card.isDrop ? Theme.selectedBg
                     : cardMouse.containsMouse && root.dragWin === null ? Qt.rgba(1, 1, 1, Theme.dark ? 0.06 : 0.12)
                     : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durMicro) } }
            }

            MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.open
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchTo(card.wsId)
            }

            // Windows.
            Repeater {
                model: card.wins
                delegate: WindowTile {
                    cardWidth: screenRect.width
                    cardHeight: screenRect.height
                    count: card.wins.length
                }
            }

            // Empty.
            Rectangle {
                anchors.centerIn: parent
                visible: card.wins.length === 0 && screenRect.height > 60
                width: emptyText.implicitWidth + 2 * Theme.space12
                height: 24
                radius: 12
                color: Qt.rgba(0, 0, 0, 0.42)
                Text {
                    id: emptyText
                    anchors.centerIn: parent
                    text: qsTr("No windows")
                    font: Theme.typeCaption
                    color: "#FFFFFF"
                }
            }

            // Active: accent ring inside the card edge.
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "transparent"
                border.width: card.active ? 2 : 1
                border.color: card.active ? Theme.accent : card.isDrop ? Theme.accent : Theme.glassBorder
            }
        }

        // Label: number badge, name, window count.
        Item {
            y: screenRect.height
            width: screenRect.width
            height: root.labelHeight
            opacity: card._zoom > 0 ? Math.max(0, 1 - card._zoom * 4) : 1

            Rectangle {
                id: badge
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 2
                width: 22
                height: 22
                radius: 6
                color: card.active ? Theme.accent : Theme.dark ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(0, 0, 0, 0.07)
                Text {
                    anchors.centerIn: parent
                    text: card.wsId
                    font: Theme.typeCaptionTnum
                    color: card.active ? Theme.onAccent : Theme.text
                }
            }
            Text {
                anchors.left: badge.right
                anchors.leftMargin: Theme.space8
                anchors.right: count.visible ? count.left : parent.right
                anchors.rightMargin: count.visible ? Theme.space8 : 0
                anchors.verticalCenter: badge.verticalCenter
                text: root.wsName(card.wsId)
                elide: Text.ElideRight
                maximumLineCount: 1
                font: card.active || card.isSelected ? Theme.typeBodyStrong : Theme.typeBody
                color: Theme.text
            }
            Text {
                id: count
                anchors.right: parent.right
                anchors.verticalCenter: badge.verticalCenter
                // Narrow cards (4 × 4 on a small screen, the strip): the name
                // gets the room; the count stays in the accessible name.
                visible: screenRect.width >= 200
                text: {
                    const n = card.wins.length;
                    if (root._q !== "") return qsTr("%1 of %2").arg(card.matches).arg(n);
                    return n === 0 ? qsTr("Empty") : n === 1 ? qsTr("1 window") : qsTr("%1 windows").arg(n);
                }
                font: Theme.typeCaption
                color: Theme.textMuted
            }
        }
    }

    // A window drawn inside a card.
    component WindowTile: Rectangle {
        id: tile
        required property var modelData
        required property int index
        property real cardWidth
        property real cardHeight
        property int count
        readonly property var w: modelData
        readonly property bool known: w.width > 0 && w.height > 0 && w.monitorWidth > 0 && w.monitorHeight > 0
        readonly property bool match: root._matches(w)

        // Auto-arrangement when the geometry is unknown.
        readonly property int _cols: Math.ceil(Math.sqrt(count))
        readonly property int _rows: Math.ceil(count / _cols)
        readonly property real _cw: cardWidth / _cols
        readonly property real _ch: cardHeight / _rows
        readonly property real sx: cardWidth / Math.max(1, w.monitorWidth)
        readonly property real sy: cardHeight / Math.max(1, w.monitorHeight)

        x: known ? Math.max(0, Math.min(cardWidth - width, w.x * sx)) : (index % _cols) * _cw + _cw * 0.08
        y: known ? Math.max(0, Math.min(cardHeight - height, w.y * sy)) : Math.floor(index / _cols) * _ch + _ch * 0.08
        width: known ? Math.max(24, Math.min(cardWidth, w.width * sx)) : _cw * 0.84
        height: known ? Math.max(18, Math.min(cardHeight, w.height * sy)) : _ch * 0.84
        radius: Math.max(3, Math.min(8, width * 0.04))
        color: Theme.dark ? "#2A2926" : "#FBFAF8"
        border.width: 1
        border.color: tileMouse.containsMouse ? Theme.accent : (w.focused ? Theme.border : Theme.glassBorder)
        opacity: (root.dragWin && root.dragWin.winId === w.winId ? 0.3 : 1) * (match ? 1 : 0.28)
        z: index

        Accessible.role: Accessible.Button
        Accessible.name: (w.title || w.appName) + " — " + w.appName

        // Title strip.
        Rectangle {
            width: parent.width
            height: Math.min(14, parent.height * 0.14)
            radius: parent.radius
            color: Theme.dark ? "#34322E" : "#ECEAE5"
            visible: parent.height > 40
            Rectangle {   // square the bottom corners of the strip
                anchors.bottom: parent.bottom
                width: parent.width
                height: parent.radius
                color: parent.color
            }
        }
        Column {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: parent.height > 40 ? 4 : 0
            width: parent.width - 2 * Theme.space8
            spacing: Theme.space4
            AppIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                size: Math.round(Math.max(14, Math.min(44, Math.min(tile.width, tile.height) * 0.36)))
                iconName: tile.w.icon
                fallbackText: tile.w.appName
            }
            Text {
                width: parent.width
                visible: tile.height >= 64 && tile.width >= 72
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: tile.w.title || tile.w.appName
                font: Theme.typeCaption
                color: Theme.text
            }
        }

        MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.open
            cursorShape: pressed && root.dragWin ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            property point _start
            onPressed: mouse => _start = Qt.point(mouse.x, mouse.y)
            onPositionChanged: mouse => {
                if (!pressed) return;
                if (root.dragWin === null && Math.hypot(mouse.x - _start.x, mouse.y - _start.y) < 8) return;
                if (root.dragWin === null) root.dragWin = tile.w;
                const p = mapToItem(root, mouse.x, mouse.y);
                ghost.x = p.x - ghost.width / 2;
                ghost.y = p.y - ghost.height / 2;
                root.dropWs = root.cardAt(p.x, p.y);
            }
            onReleased: mouse => {
                if (root.dragWin === null) return;
                const win = root.dragWin.winId, ws = root.dropWs;
                root.dragWin = null;
                root.dropWs = 0;
                if (ws > 0 && !(root.windowsByWs[ws] || []).some(x => x.winId === win))
                    root.moveWindow(win, ws);
            }
            onCanceled: { root.dragWin = null; root.dropWs = 0; }
            onClicked: if (root.dragWin === null) root.activateWindow(tile.w.winId)
        }

        // Close button on hover.
        Rectangle {
            id: closeBtn
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: -6
            width: 22
            height: 22
            radius: 11
            visible: (tileMouse.containsMouse || closeMouse.containsMouse) && root.dragWin === null && tile.width >= 40
            color: closeMouse.containsMouse ? Theme.danger : (Theme.dark ? "#3A3834" : "#FFFFFF")
            border.width: 1
            border.color: closeMouse.containsMouse ? Theme.danger : Theme.border
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Close %1").arg(tile.w.title || tile.w.appName)
            Icon {
                anchors.centerIn: parent
                name: "x"
                size: 12
                color: closeMouse.containsMouse ? Theme.onDanger : Theme.text
            }
            MouseArea {
                id: closeMouse
                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                onClicked: root.closeWindow(tile.w.winId)
            }
        }
    }
}

// Everything under the launcher's search field: the empty state (one row of
// recent apps + key hints), the grouped result list, and the no-results
// message. Loaded asynchronously by Launcher.qml so the field is typeable on
// the first frame.
//
// Keyboard input arrives from the field through handleKey(event); the field
// keeps focus the whole time.
//
// The highlight is one pill that glides between rows with the snappy spring
// (and between the recent tiles); it carries the "Open ↵" hint, so rows stay
// light. `current` says whether `results` answers `query`: while it does not
// (live backend, answer on its way) the last view and height are held, so
// nothing flashes between two keystrokes.
import QtQuick
import Lugh.UI

Item {
    id: body

    property string query: ""
    property var results: null      // ListModel: kind, group, title, subtitle, icon, target
    property var recent: null       // ListModel: appId, name, icon
    property bool searching: false
    property bool current: true
    property int maxResultsHeight: 396

    signal activateResult(int index, bool secondary)
    signal activateRecent(string appId)

    readonly property string trimmed: query.trim()
    readonly property int resultCount: results ? results.count : 0
    readonly property int recentCount: recent ? Math.min(recent.count, 6) : 0
    // "empty" (no query) | "results" | "none" (no results) | "pending"
    readonly property string mode: trimmed === "" ? "empty"
        : resultCount > 0 ? "results"
        : (!current || searching) ? "pending" : "none"
    // What is on screen: the mode, held while it is "pending".
    property string view: "empty"
    property string _noneQuery: ""

    // The height the panel springs to (held while pending).
    property real targetHeight: 0
    readonly property real _viewHeight: view === "empty" ? emptyView.implicitHeight
        : view === "results" ? list.targetHeight
        : noResults.implicitHeight
    function _latch() {
        if (mode === "pending") return;
        // Rows left from an earlier query may replace each other, but never
        // come up over the empty state or the no-results message.
        if (mode === "results" && !current && view !== "results") return;
        if (mode === "none") _noneQuery = trimmed;
        view = mode;
        targetHeight = _viewHeight;
    }
    onModeChanged: _latch()
    onCurrentChanged: _latch()
    on_ViewHeightChanged: _latch()
    Component.onCompleted: _latch()

    property int recentIndex: -1
    // Set once the user moves the highlight; until then streamed-in results
    // keep it on the first row.
    property bool _userMoved: false
    // Last pointer position seen over a row (null until the first event after
    // reset(), which only records it: hover events also fire when rows move
    // under a still cursor).
    property var _lastPointer: null
    // The pill glides only when the user moved it, never on new results.
    property bool _glide: false
    property bool _tileGlide: false
    property int _pressIndex: -1

    readonly property int rowHeight: 44
    readonly property int inset: 6

    // ---- API for Launcher.qml ---------------------------------------------
    function reset() {
        _tileGlide = false;
        recentIndex = -1;
        _userMoved = false;
        _lastPointer = null;
        _glide = false;
        _pressIndex = -1;
        list.currentIndex = resultCount > 0 ? 0 : -1;
        list.positionViewAtBeginning();
    }

    // Returns true when the key was used.
    function handleKey(event) {
        const k = event.key;
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        if (mode === "empty") return _emptyKey(k, event.modifiers);
        if (mode !== "results") return false;
        switch (k) {
        case Qt.Key_Down: _move(1, true); return true;
        case Qt.Key_Up: _move(-1, true); return true;
        case Qt.Key_PageDown: _move(_pageStep(), false); return true;
        case Qt.Key_PageUp: _move(-_pageStep(), false); return true;
        case Qt.Key_Tab: _jumpGroup(1); return true;
        case Qt.Key_Backtab: _jumpGroup(-1); return true;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (list.currentIndex >= 0) activateResult(list.currentIndex, ctrl);
            return true;
        }
        return false;
    }

    function _emptyKey(k, mods) {
        const n = recentCount;
        if (n === 0) return false;
        switch (k) {
        case Qt.Key_Right: case Qt.Key_Down: case Qt.Key_Tab:
            _tileGlide = recentIndex >= 0;
            recentIndex = (recentIndex + 1) % n; return true;
        case Qt.Key_Left: case Qt.Key_Up: case Qt.Key_Backtab:
            _tileGlide = recentIndex >= 0;
            recentIndex = recentIndex <= 0 ? n - 1 : recentIndex - 1; return true;
        case Qt.Key_Return: case Qt.Key_Enter:
            if (recentIndex >= 0) activateRecent(recent.get(recentIndex).appId);
            return true;
        }
        return false;
    }

    function _move(delta, wrap) {
        const n = resultCount;
        if (n === 0) return;
        let i = list.currentIndex + delta;
        if (wrap) i = ((i % n) + n) % n;
        else i = Math.max(0, Math.min(n - 1, i));
        _setCurrent(i);
    }
    function _setCurrent(i) {
        _userMoved = true;
        _glide = true;
        list.currentIndex = i;
        if (i === 0) list.positionViewAtBeginning();
        else if (i === resultCount - 1) list.positionViewAtEnd();
        else { list.positionViewAtIndex(i, ListView.Contain); _reveal(); }
    }
    // Keeps the pill clear of the list's edges: its group header stays in
    // view above it, the bottom inset below it.
    function _reveal() {
        const it = list.currentItem;
        if (!it) return;
        const top = it.y - 24, bottom = it.y + it.height + inset;
        if (top < list.contentY) list.contentY = Math.max(list.originY, top);
        else if (bottom > list.contentY + list.height) list.contentY = bottom - list.height;
    }
    function _pointerMoved(idx, pos) {
        const last = _lastPointer;
        _lastPointer = pos;
        if (last === null || (last.x === pos.x && last.y === pos.y)) return;
        if (list.currentIndex !== idx) { _userMoved = true; _glide = true; list.currentIndex = idx; }
    }
    function _pressChanged(idx, down) {
        if (down && list.currentIndex !== idx) { _userMoved = true; _glide = true; list.currentIndex = idx; }
        _pressIndex = down ? idx : -1;
    }
    function _pageStep() { return Math.max(1, Math.floor(list.height / rowHeight) - 1); }
    function _groupAt(i) { return results.get(i).group; }
    function _jumpGroup(dir) {
        const n = resultCount;
        if (n === 0) return;
        const cur = Math.max(0, list.currentIndex);
        const g = _groupAt(cur);
        let i = cur;
        if (dir > 0) {
            while (i < n && _groupAt(i) === g) ++i;
            if (i >= n) i = 0;           // wrap to the first group
        } else {
            // Start of this group; if already there, start of the previous one.
            while (i > 0 && _groupAt(i - 1) === g) --i;
            if (i === cur) {
                i = cur === 0 ? n - 1 : cur - 1;
                const pg = _groupAt(i);
                while (i > 0 && _groupAt(i - 1) === pg) --i;
            }
        }
        _setCurrent(i);
    }

    Connections {
        target: body.results
        // Results stream in (slow providers): keep row 0 highlighted until
        // the user moves.
        function onCountChanged() {
            if (!body._userMoved) {
                body._glide = false;
                list.currentIndex = body.resultCount > 0 ? 0 : -1;
            }
        }
    }
    onTrimmedChanged: { reset(); _latch(); }

    component Caption: Text {
        font.family: Theme.fontUi
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.7
        color: Theme.textMuted
    }

    component Hint: Row {
        property alias keys: rep.model
        property alias label: lbl.text
        spacing: Theme.space4
        Repeater {
            id: rep
            delegate: Keycap {
                required property string modelData
                text: modelData
            }
        }
        Text {
            id: lbl
            leftPadding: Theme.space2
            anchors.verticalCenter: parent.verticalCenter
            font: Theme.typeCaption
            color: Theme.textMuted
        }
    }

    component Snappy: SpringAnimation {
        spring: Theme.snappySpring; damping: Theme.snappyDamping
        mass: Theme.snappyMass; epsilon: Theme.springEpsilon
    }

    // ---- empty query: recent apps + hints -----------------------------------
    Item {
        id: emptyView
        readonly property bool hasRecent: body.recentCount > 0
        width: parent.width
        implicitHeight: footer.y + footer.height
        opacity: body.view === "empty" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }

        Caption {
            id: recentHeader
            x: Theme.space16
            height: 24
            verticalAlignment: Text.AlignBottom
            bottomPadding: Theme.space2
            text: qsTr("Recent")
            visible: emptyView.hasRecent
        }

        Item {
            id: tiles
            readonly property int tileWidth: Math.floor((parent.width - 2 * x) / Math.max(5, body.recentCount))
            x: body.inset
            y: emptyView.hasRecent ? 24 + Theme.space4 : 0
            width: parent.width - 2 * x
            height: emptyView.hasRecent ? 78 : 0
            visible: emptyView.hasRecent
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Recent apps")

            // Keyboard-current tile: the same pill, gliding sideways.
            Rectangle {
                visible: body.recentIndex >= 0
                x: Math.max(0, body.recentIndex) * tiles.tileWidth + 1
                width: tiles.tileWidth - 2
                height: parent.height
                radius: Theme.radiusLg
                color: Theme.selectedBg
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                Behavior on x { enabled: body._tileGlide && !Theme.reduceMotion; Snappy {} }
            }

            Row {
                Repeater {
                    model: body.recent
                    delegate: RecentTile {
                        visible: index < 6
                        width: tiles.tileWidth
                        height: tiles.height
                        current: index === body.recentIndex
                        onClicked: idx => body.activateRecent(body.recent.get(idx).appId)
                    }
                }
            }
        }

        // The keys, once.
        Item {
            id: footer
            y: tiles.y + tiles.height + (emptyView.hasRecent ? Theme.space8 : 0)
            width: parent.width
            height: 36

            Rectangle {
                visible: emptyView.hasRecent
                x: Theme.space16
                width: parent.width - 2 * x
                height: 1
                color: Theme.glassBorder
            }
            Row {
                x: Theme.space16
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space16

                Hint { keys: ["↑", "↓"]; label: qsTr("move") }
                Hint { keys: ["↵"]; label: qsTr("open") }
            }
            Hint {
                anchors.right: parent.right
                anchors.rightMargin: Theme.space16
                anchors.verticalCenter: parent.verticalCenter
                keys: ["esc"]; label: qsTr("close")
            }
        }
    }

    // ---- results -------------------------------------------------------------
    ListView {
        id: list
        readonly property real targetHeight: Math.min(contentHeight + topMargin + bottomMargin, body.maxResultsHeight)
        width: parent.width
        height: targetHeight
        opacity: body.view === "results" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }

        model: body.results
        clip: true
        reuseItems: true
        cacheBuffer: 264
        bottomMargin: body.inset
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationEnabled: false
        currentIndex: -1
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Search results")

        section.property: "group"
        section.criteria: ViewSection.FullString
        section.delegate: Item {
            required property string section
            width: ListView.view.width
            height: 24
            Caption {
                x: Theme.space16
                height: parent.height
                verticalAlignment: Text.AlignBottom
                bottomPadding: Theme.space2
                text: parent.section
            }
        }

        // One pill for the whole list. It moves itself (spring), so the view
        // does not move it.
        highlightFollowsCurrentItem: false
        highlight: Item {
            id: pill
            readonly property Item row: list.currentItem
            width: list.width
            y: row ? row.y : 0
            height: row ? row.height : body.rowHeight
            visible: row !== null && list.currentIndex >= 0
            Behavior on y { enabled: body._glide && !Theme.reduceMotion; Snappy {} }
            Behavior on height { enabled: body._glide && !Theme.reduceMotion; Snappy {} }

            Rectangle {
                x: body.inset
                y: 1
                width: parent.width - 2 * body.inset
                height: parent.height - 2
                radius: height / 2
                antialiasing: true
                color: Theme.selectedBg
                border.width: 1
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)

                Rectangle {     // pressed
                    anchors.fill: parent
                    radius: parent.radius
                    color: Theme.pressedOverlay
                    visible: body._pressIndex >= 0 && body._pressIndex === list.currentIndex
                }

                // What Enter does to this row.
                Row {
                    id: hint
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: pill.row ? pill.row.actionText : ""
                        font: Theme.typeCaption
                        color: Theme.accentText
                    }
                    Keycap { text: "↵"; anchors.verticalCenter: parent.verticalCenter }
                }
            }
            readonly property real hintWidth: hint.width + Theme.space12
        }

        delegate: ResultRow {
            width: ListView.view.width
            height: implicitHeight
            query: body.trimmed
            current: ListView.isCurrentItem
            inset: body.inset
            hintWidth: list.highlightItem ? list.highlightItem.hintWidth : 0
            onHoverMoved: (idx, pos) => body._pointerMoved(idx, pos)
            onPressChanged: (idx, down) => body._pressChanged(idx, down)
            onClicked: idx => body.activateResult(idx, false)
        }
    }

    // ---- no results ----------------------------------------------------------
    Column {
        id: noResults
        width: parent.width
        topPadding: Theme.space20
        bottomPadding: Theme.space20
        spacing: Theme.space2
        opacity: body.view === "none" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
        Accessible.role: Accessible.StaticText
        Accessible.name: noTitle.text + ". " + noBody.text

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 32
            height: 32
            radius: 16
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
            Icon {
                anchors.centerIn: parent
                name: "search-x"
                size: 16
                color: Theme.textMuted
            }
        }
        Item { width: 1; height: Theme.space8 }
        Text {
            id: noTitle
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, parent.width - 2 * Theme.space32)
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("No results for “%1”").arg(body._noneQuery)
            font: Theme.typeBodyStrong
            color: Theme.text
            elide: Text.ElideMiddle
        }
        Text {
            id: noBody
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, parent.width - 2 * Theme.space32)
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Check the spelling, or try an app’s generic name, like “browser”.")
            font: Theme.typeCaption
            color: Theme.textMuted
            wrapMode: Text.Wrap
        }
    }
}

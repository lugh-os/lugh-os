// Everything under the launcher's search field: the empty state (recent apps
// + hints), the grouped result list, and the no-results message. Loaded
// asynchronously by Launcher.qml so the field is typeable on the first frame.
//
// Keyboard input arrives from the field through handleKey(event); the field
// keeps focus the whole time.
import QtQuick
import Lugh.UI

Item {
    id: body

    property string query: ""
    property var results: null      // ListModel: kind, group, title, subtitle, icon, target
    property var recent: null       // ListModel: appId, name, icon
    property bool searching: false
    property int maxResultsHeight: 440

    signal activateResult(int index, bool secondary)
    signal activateRecent(string appId)

    readonly property string trimmed: query.trim()
    readonly property int resultCount: results ? results.count : 0
    // "empty" (no query) | "results" | "none" (no results) | "pending"
    readonly property string mode: trimmed === "" ? "empty"
        : resultCount > 0 ? "results"
        : searching ? "pending" : "none"

    // The height the panel animates to.
    readonly property real targetHeight: mode === "empty" ? emptyView.implicitHeight
        : mode === "results" ? list.targetHeight
        : mode === "none" ? noResults.implicitHeight
        : 0

    property int recentIndex: -1
    // Set once the user moves the highlight; until then streamed-in results
    // keep it on the first row.
    property bool _userMoved: false
    // Last pointer position seen over a row (null until the first event after
    // reset(), which only records it: hover events also fire when rows move
    // under a still cursor).
    property var _lastPointer: null

    // ---- API for Launcher.qml ---------------------------------------------
    function reset() {
        recentIndex = -1;
        _userMoved = false;
        _lastPointer = null;
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
        const n = recent ? recent.count : 0;
        if (n === 0) return false;
        switch (k) {
        case Qt.Key_Right: case Qt.Key_Down: case Qt.Key_Tab:
            recentIndex = (recentIndex + 1) % n; return true;
        case Qt.Key_Left: case Qt.Key_Up: case Qt.Key_Backtab:
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
        list.currentIndex = i;
        if (i === 0) list.positionViewAtBeginning();
        else if (i === resultCount - 1) list.positionViewAtEnd();
    }
    function _pointerMoved(idx, pos) {
        const last = _lastPointer;
        _lastPointer = pos;
        if (last === null || (last.x === pos.x && last.y === pos.y)) return;
        if (list.currentIndex !== idx) { _userMoved = true; list.currentIndex = idx; }
    }
    function _pageStep() { return Math.max(1, Math.floor(list.height / 52) - 1); }
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
            if (!body._userMoved) list.currentIndex = body.resultCount > 0 ? 0 : -1;
        }
    }
    onTrimmedChanged: reset()

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

    // ---- empty query: recent apps + hints -----------------------------------
    Item {
        id: emptyView
        width: parent.width
        implicitHeight: footer.y + footer.height
        opacity: body.mode === "empty" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }

        Caption {
            id: recentHeader
            x: Theme.space20
            height: 36
            verticalAlignment: Text.AlignBottom
            bottomPadding: Theme.space4
            text: qsTr("Recent")
            visible: body.recent && body.recent.count > 0
        }

        Row {
            id: tiles
            anchors.top: recentHeader.bottom
            anchors.topMargin: Theme.space4
            x: Theme.space8
            spacing: Theme.space4
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Recent apps")

            Repeater {
                model: body.recent
                delegate: RecentTile {
                    current: index === body.recentIndex
                    onClicked: idx => body.activateRecent(body.recent.get(idx).appId)
                }
            }
        }

        // Hints: what to type, and the keys.
        Item {
            id: footer
            anchors.top: tiles.bottom
            anchors.topMargin: Theme.space12
            width: parent.width
            height: 44

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.glassBorder
            }
            Text {
                x: Theme.space20
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 1
                text: qsTr("Type to search apps, files and settings")
                font: Theme.typeCaption
                color: Theme.textMuted
            }
            Row {
                anchors.right: parent.right
                anchors.rightMargin: Theme.space20
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 1
                spacing: Theme.space16

                Hint { keys: ["↑", "↓"]; label: qsTr("to move") }
                Hint { keys: ["↵"]; label: qsTr("to open") }
                Hint { keys: ["esc"]; label: qsTr("to close") }
            }
        }
    }

    // ---- results -------------------------------------------------------------
    ListView {
        id: list
        readonly property real targetHeight: Math.min(contentHeight + topMargin + bottomMargin, body.maxResultsHeight)
        width: parent.width
        height: targetHeight
        opacity: body.mode === "results" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }

        model: body.results
        clip: true
        reuseItems: true
        cacheBuffer: 320
        topMargin: Theme.space4
        bottomMargin: Theme.space8
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
            height: 30
            Caption {
                x: Theme.space20
                height: parent.height
                verticalAlignment: Text.AlignBottom
                bottomPadding: 6
                text: parent.section
            }
        }

        highlightFollowsCurrentItem: true
        highlightMoveDuration: Theme.reduceMotion ? 0 : Theme.durMicro
        highlightMoveVelocity: -1
        highlightResizeDuration: Theme.reduceMotion ? 0 : Theme.durMicro
        highlightResizeVelocity: -1
        highlight: Item {
            z: 0
            Rectangle {
                x: Theme.space8
                y: 1
                width: parent.width - 2 * Theme.space8
                height: parent.height - 2
                radius: Theme.radiusMd
                color: Theme.selectedBg
                // Keyboard-current marker: a shape cue next to the tint.
                Rectangle {
                    x: 0
                    width: 3
                    height: Math.max(12, parent.height - 2 * Theme.radiusMd)
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 1.5
                    color: Theme.accent
                }
            }
        }

        delegate: ResultRow {
            width: ListView.view.width
            height: implicitHeight
            query: body.trimmed
            current: ListView.isCurrentItem
            onHoverMoved: (idx, pos) => body._pointerMoved(idx, pos)
            onClicked: idx => body.activateResult(idx, false)
        }
    }

    // ---- no results ----------------------------------------------------------
    Column {
        id: noResults
        width: parent.width
        topPadding: Theme.space24
        bottomPadding: Theme.space24 + Theme.space4
        spacing: Theme.space4
        opacity: body.mode === "none" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
        Accessible.role: Accessible.StaticText
        Accessible.name: noTitle.text + ". " + noBody.text

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 40
            height: 40
            radius: 20
            color: Theme.dark ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(0, 0, 0, 0.045)
            Icon {
                anchors.centerIn: parent
                name: "search-x"
                size: 20
                color: Theme.textMuted
            }
        }
        Item { width: 1; height: Theme.space8 }
        Text {
            id: noTitle
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, parent.width - 2 * Theme.space32)
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("No results for “%1”").arg(body.trimmed)
            font: Theme.typeTitle3
            color: Theme.text
            elide: Text.ElideMiddle
        }
        Text {
            id: noBody
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, parent.width - 2 * Theme.space32)
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Check the spelling, or try an app’s generic name, like “browser”.")
            font: Theme.typeBody
            color: Theme.textMuted
            wrapMode: Text.Wrap
        }
    }
}

// Customize panel: advanced settings for the shell itself (the bottom panel,
// the quick panel, workspaces, appearance, motion). Every control edits
// ShellSettings, which persists and applies live.
//
//   Customize { anchors.fill: parent }   // the frame anchors it to the screen
//
// Full-screen overlay root: a scrim and a centered glass sheet (≤ 880 × 600)
// with a sidebar of sections and a search field that filters settings across
// every section (matching rows show in place, with their controls). Opens
// when ShellState.customizeOpen, on ShellState.customizePage ("" = first);
// closes on Esc (after clearing the search / cancelling a reset), a click on
// the scrim, or the close button. The frame maps the layer surface while
// `shown` and gives it the keyboard while `wantsKeyboard`.
//
// Everything is built at startup, so the sheet is complete on its first
// frame; opening only fades and settles it (scale 0.97 → 1, none under
// reduce motion).
//
// Keys: ↑/↓ Home/End move between sections in the sidebar · typing there
// starts a search · Ctrl+F search · ↓/Enter in the search field jump to the
// results · Tab walks the controls · Esc clears, then closes.
// Below 720 px of sheet width the sidebar collapses to icons and the search
// field moves into the content header.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell

FocusScope {
    id: root

    readonly property bool open: ShellState.customizeOpen
    // Open, or still fading out.
    readonly property bool shown: open || _progress > 0
    readonly property bool wantsKeyboard: open

    // The current section key, and the search text.
    property string page: sections[0].key
    property alias query: field.text
    readonly property bool searching: query.trim() !== ""
    readonly property bool compact: sheet.width < 720

    readonly property var sections: [
        { key: "appearance", title: qsTr("Appearance"), icon: "palette",
          desc: qsTr("Style, accent color, glass and wallpaper") },
        { key: "panel", title: qsTr("Panel"), icon: "panel-bottom",
          desc: qsTr("The taskbar along the bottom of the screen") },
        { key: "clock", title: qsTr("Clock & tray"), icon: "clock",
          desc: qsTr("Time format and the status icons beside it") },
        { key: "quick", title: qsTr("Quick panel"), icon: "toggle-right",
          desc: qsTr("Calendar, sliders and toggles behind the clock") },
        { key: "workspaces", title: qsTr("Workspaces"), icon: "layout-grid",
          desc: qsTr("The workspace grid and moving around it") },
        { key: "windows", title: qsTr("Windows"), icon: "app-window",
          desc: qsTr("Title bar buttons and density") },
        { key: "motion", title: qsTr("Motion"), icon: "zap",
          desc: qsTr("Animation speed and reduced motion") }
    ]
    readonly property var _pages: [pAppearance, pPanel, pClock, pQuick, pWorkspaces, pWindows, pMotion]
    readonly property int _index: _indexOf(page)
    readonly property int _total: {
        let n = 0;
        for (const p of _pages) n += p.count;
        return n;
    }

    function _indexOf(key) {
        for (let i = 0; i < sections.length; ++i)
            if (sections[i].key === key) return i;
        return -1;
    }
    function goTo(key) {
        if (_indexOf(key) < 0) key = sections[0].key;
        if (searching) query = "";
        if (key === page) return;
        page = key;
        flick.contentY = 0;
        enter.restart();
    }
    function _onOpen() {
        footer.confirming = false;
        query = "";
        page = _indexOf(ShellState.customizePage) >= 0 ? ShellState.customizePage : sections[0].key;
        flick.contentY = 0;
        _navKbd = false;            // the ring shows once the keyboard is used
        nav.forceActiveFocus();
    }
    // Focuses the first control of the content (the first result while
    // searching). The close button precedes the content in the focus chain in
    // both layouts (the compact search field sits before it in the header).
    function _focusContent() {
        closeBtn.nextItemInFocusChain(true).forceActiveFocus(Qt.TabFocusReason);
    }
    // Keeps the keyboard-focused control in view while tabbing through content.
    function _reveal(item) {
        if (!item) return;
        let p = item;
        while (p && p !== flick.contentItem) p = p.parent;
        if (!p) return;
        const y = item.mapToItem(flick.contentItem, 0, 0).y;
        const top = y - Theme.space16, bottom = y + item.height + Theme.space16;
        const maxY = Math.max(0, flick.contentHeight - flick.height);
        if (top < flick.contentY) flick.contentY = Math.max(0, top);
        else if (bottom > flick.contentY + flick.height) flick.contentY = Math.min(maxY, bottom - flick.height);
    }

    property real _progress: open ? 1 : 0
    Behavior on _progress {
        NumberAnimation {
            duration: Theme.dur(Theme.durMedium) - 40
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.easeStandard
        }
    }
    property bool _navKbd: true      // the sidebar's focus came from the keyboard

    focus: true
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Customize")

    onOpenChanged: if (open) _onOpen()
    Component.onCompleted: if (open) _onOpen()
    Connections {
        target: ShellState
        function onCustomizePageChanged() { if (root.open && ShellState.customizePage !== "") root.goTo(ShellState.customizePage); }
    }
    Connections {
        target: root.Window.window
        function onActiveFocusItemChanged() { root._reveal(root.Window.activeFocusItem); }
    }

    Keys.onPressed: event => {
        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) {
            field.forceActiveFocus(Qt.ShortcutFocusReason);
            field.selectAll();
            event.accepted = true;
        }
    }
    Keys.onEscapePressed: {
        if (footer.confirming) footer.confirming = false;
        else if (query !== "") {
            query = "";
            // a result row that just hid can't keep the keyboard
            const f = root.Window.activeFocusItem;
            if (f && f !== field && !f.visible) nav.forceActiveFocus(Qt.TabFocusReason);
        } else ShellState.closeAll();
    }

    // ---- scrim ------------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        opacity: root._progress
    }
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: ShellState.closeAll()
        onWheel: wheel => wheel.accepted = true
    }

    // ---- sheet ------------------------------------------------------------------
    Item {
        id: sheet
        readonly property int availH: root.height - ShellState.panelReserved
        width: Math.max(320, Math.min(880, root.width - 2 * Theme.space16))
        height: Math.max(300, Math.min(600, availH - 2 * Theme.space16))
        x: Math.round((root.width - width) / 2)
        y: Math.max(Theme.space8, Math.round((availH - height) / 2))
        opacity: root._progress
        scale: Theme.reduceMotion ? 1 : 0.97 + 0.03 * root._progress
        enabled: root.open

        MouseArea { anchors.fill: parent; onWheel: wheel => wheel.accepted = true }   // keep clicks off the scrim

        GlassPanel {
            anchors.fill: parent
            radius: ShellSettings.cornerRadius + 6
            elevation: "window"
        }

        // ---- sidebar ----------------------------------------------------------------
        Item {
            id: sidebar
            width: root.compact ? 68 : 236
            height: parent.height

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.space12
                anchors.topMargin: Theme.space16
                spacing: Theme.space12

                RowLayout {
                    spacing: Theme.space12
                    Layout.fillWidth: true
                    Layout.leftMargin: root.compact ? 0 : Theme.space4
                    Layout.bottomMargin: Theme.space4

                    Rectangle {
                        implicitWidth: 36; implicitHeight: 36
                        radius: 11
                        color: Theme.selectedBg
                        border.width: 1
                        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)
                        Layout.alignment: root.compact ? Qt.AlignHCenter : Qt.AlignLeft
                        Icon { anchors.centerIn: parent; name: "sliders-horizontal"; size: 18; color: Theme.accentText }
                    }
                    ColumnLayout {
                        visible: !root.compact
                        spacing: 0
                        Layout.fillWidth: true
                        Text {
                            text: qsTr("Customize")
                            font: Theme.typeTitle3
                            color: Theme.text
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            Accessible.role: Accessible.Heading
                        }
                        Text {
                            text: qsTr("Make the desktop yours")
                            font: Theme.typeCaption
                            color: Theme.textMuted
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }

                Item {
                    id: wideSearchSlot
                    visible: !root.compact
                    Layout.fillWidth: true
                    implicitHeight: 36

                    SearchField {
                        id: field
                        parent: root.compact ? compactSearchSlot : wideSearchSlot
                        anchors.fill: parent
                        placeholderText: qsTr("Search settings")
                        Keys.onDownPressed: event => {
                            if (root.searching) root._focusContent();
                            else nav.forceActiveFocus(Qt.TabFocusReason);
                        }
                        onAccepted: if (root.searching) root._focusContent()
                    }
                }

                FocusScope {
                    id: nav
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    activeFocusOnTab: true
                    Accessible.role: Accessible.PageTabList
                    Accessible.name: qsTr("Sections")

                    onActiveFocusChanged: if (!activeFocus) root._navKbd = true
                    Keys.onReleased: root._navKbd = true
                    Keys.onPressed: event => {
                        const n = root.sections.length;
                        let i = -1;
                        if (event.key === Qt.Key_Up) i = Math.max(0, root._index - 1);
                        else if (event.key === Qt.Key_Down) i = Math.min(n - 1, root._index + 1);
                        else if (event.key === Qt.Key_Home) i = 0;
                        else if (event.key === Qt.Key_End) i = n - 1;
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
                            root._focusContent();
                            event.accepted = true;
                            return;
                        } else if (event.text.length === 1 && event.text > " "
                                   && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
                            field.forceActiveFocus(Qt.ShortcutFocusReason);
                            field.insert(field.cursorPosition, event.text);
                            event.accepted = true;
                            return;
                        }
                        if (i < 0) return;
                        event.accepted = true;
                        root._navKbd = true;
                        root.goTo(root.sections[i].key);
                    }

                    Flickable {
                        anchors.fill: parent
                        contentHeight: navCol.height
                        clip: contentHeight > height
                        interactive: contentHeight > height
                        boundsBehavior: Flickable.StopAtBounds

                        Column {
                            id: navCol
                            width: parent.width
                            spacing: 2

                            Repeater {
                                model: root.sections
                                NavButton {
                                    required property var modelData
                                    required property int index
                                    width: navCol.width
                                    text: modelData.title
                                    iconName: modelData.icon
                                    compact: root.compact
                                    current: !root.searching && index === root._index
                                    matchCount: root.searching ? root._pages[index].count : -1
                                    focusShown: nav.activeFocus && root._navKbd
                                                && (root.searching ? index === 0 : current)
                                    onClicked: {
                                        root._navKbd = false;
                                        nav.forceActiveFocus(Qt.MouseFocusReason);
                                        root.goTo(modelData.key);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        Rectangle {
            x: sidebar.width
            width: 1
            height: parent.height
            color: Theme.glassBorder
        }

        // ---- content -------------------------------------------------------------------
        Item {
            id: content
            x: sidebar.width + 1
            width: parent.width - x
            height: parent.height
            readonly property int pad: root.compact ? Theme.space16 : Theme.space24

            RowLayout {
                id: header
                x: content.pad
                y: Theme.space16
                width: content.width - content.pad - Theme.space12
                height: 48
                spacing: Theme.space12

                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Text {
                        text: root.searching ? qsTr("Search") : root.sections[Math.max(0, root._index)].title
                        font: Theme.typeTitle2
                        color: Theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        Accessible.role: Accessible.Heading
                    }
                    Text {
                        text: root.searching
                              ? (root._total === 1 ? qsTr("1 setting matches “%1”").arg(root.query.trim())
                                 : root._total > 1 ? qsTr("%1 settings match “%2”").arg(root._total).arg(root.query.trim())
                                                 : qsTr("Nothing matches “%1”").arg(root.query.trim()))
                              : root.sections[Math.max(0, root._index)].desc
                        font: Theme.typeCaption
                        color: Theme.textMuted
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
                Item {
                    id: compactSearchSlot
                    visible: root.compact
                    implicitWidth: Math.min(220, content.width * 0.42)
                    implicitHeight: 36
                }
                IconButton {
                    id: closeBtn
                    iconName: "x"
                    tooltip: qsTr("Close")
                    size: 36
                    Layout.alignment: Qt.AlignTop
                    onClicked: ShellState.closeAll()
                }
            }

            Flickable {
                id: flick
                anchors.top: header.bottom
                anchors.topMargin: Theme.space12
                anchors.bottom: footer.top
                width: parent.width
                contentWidth: width
                contentHeight: col.implicitHeight + Theme.space8 + Theme.space24
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Accessible.role: Accessible.Pane

                ColumnLayout {
                    id: col
                    // Rows look this up to filter themselves (SettingRow, util.js).
                    property string customizeQuery: root.searching ? root.query : ""
                    property real shift: 0
                    x: content.pad
                    y: Theme.space8 + shift
                    width: flick.width - 2 * content.pad
                    spacing: Theme.space24

                    AppearancePage { id: pAppearance; current: root.page === key; searching: root.searching }
                    PanelPage { id: pPanel; current: root.page === key; searching: root.searching }
                    ClockPage { id: pClock; current: root.page === key; searching: root.searching }
                    QuickPage { id: pQuick; current: root.page === key; searching: root.searching }
                    WorkspacesPage { id: pWorkspaces; current: root.page === key; searching: root.searching }
                    WindowsPage { id: pWindows; current: root.page === key; searching: root.searching }
                    MotionPage { id: pMotion; current: root.page === key; searching: root.searching }

                    EmptyState {
                        visible: root.searching && root._total === 0
                        iconName: "search"
                        title: qsTr("No settings found")
                        body: qsTr("Try a shorter word, like “clock”, “dark” or “icons”.")
                        actionText: qsTr("Clear search")
                        onAction: { root.query = ""; field.forceActiveFocus(); }
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.space48
                        Layout.preferredHeight: implicitHeight
                    }
                }

                // Section switch: the new page settles in (fade only under reduce motion).
                ParallelAnimation {
                    id: enter
                    NumberAnimation { target: col; property: "opacity"; from: 0.4; to: 1; duration: Theme.dur(Theme.durSmall) }
                    NumberAnimation {
                        target: col; property: "shift"; from: Theme.reduceMotion ? 0 : 8; to: 0
                        duration: Theme.dur(Theme.durSmall)
                        easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
                    }
                }
            }

            // scroll indicator
            Rectangle {
                visible: flick.contentHeight > flick.height + 1
                x: content.width - width - 4
                y: flick.y + flick.visibleArea.yPosition * flick.height
                width: 4
                height: Math.max(24, flick.visibleArea.heightRatio * flick.height)
                radius: 2
                color: Theme.textMuted
                opacity: flick.moving ? 0.55 : 0.22
                Behavior on opacity { NumberAnimation { duration: Theme.durSmall } }
            }

            // ---- footer: reset with a confirm step ------------------------------------------
            Item {
                id: footer
                property bool confirming: false
                property bool restored: false
                anchors.bottom: parent.bottom
                width: parent.width
                height: 60

                onConfirmingChanged: {
                    if (confirming) {
                        restored = false;
                        cancelBtn.forceActiveFocus(Qt.TabFocusReason);
                    } else if (cancelBtn.activeFocus || confirmBtn.activeFocus) {
                        resetBtn.forceActiveFocus(Qt.TabFocusReason);
                    }
                }
                Timer { id: restoredTimer; interval: 2500; onTriggered: footer.restored = false }

                Rectangle { width: parent.width; height: 1; color: Theme.glassBorder }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: content.pad
                    anchors.rightMargin: Theme.space16
                    spacing: Theme.space8

                    Icon {
                        name: footer.confirming ? "rotate-ccw" : footer.restored ? "circle-check" : "check"
                        size: 16
                        color: footer.confirming ? Theme.danger : footer.restored ? Theme.success : Theme.textMuted
                    }
                    Text {
                        text: footer.confirming ? qsTr("Reset every customization to its default?")
                            : footer.restored ? qsTr("Defaults restored")
                            : qsTr("Changes apply right away and are kept")
                        font: footer.confirming ? Theme.typeBodyStrong : Theme.typeCaption
                        color: footer.confirming ? Theme.text : Theme.textMuted
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        Accessible.role: Accessible.StaticText
                        Accessible.name: text
                    }
                    Button {
                        id: resetBtn
                        visible: !footer.confirming
                        text: root.compact ? qsTr("Reset all") : qsTr("Reset all to defaults")
                        iconName: "rotate-ccw"
                        variant: "ghost"
                        size: "sm"
                        onClicked: footer.confirming = true
                    }
                    Button {
                        id: cancelBtn
                        visible: footer.confirming
                        text: qsTr("Cancel")
                        variant: "ghost"
                        size: "sm"
                        onClicked: footer.confirming = false
                    }
                    Button {
                        id: confirmBtn
                        visible: footer.confirming
                        text: qsTr("Reset")
                        variant: "danger"
                        size: "sm"
                        onClicked: {
                            ShellSettings.reset();
                            footer.confirming = false;
                            footer.restored = true;
                            restoredTimer.restart();
                            resetBtn.forceActiveFocus(Qt.TabFocusReason);
                        }
                    }
                }
            }
        }
    }
}

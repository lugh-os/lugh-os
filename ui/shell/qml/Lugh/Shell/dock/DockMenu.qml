// The dock's context menu: a glass panel that grows out of the icon that was
// right-clicked (MorphPanel) inside the dock surface's headroom. Rows are
// plain items (not a T.Menu popup, which would need its own surface).
//
//   DockMenu { id: menu; anchors.fill: parent }
//   menu.popup(entries, originRect, originRadius, centerX, bottomY)
//
// entries: [{ text, iconName, action: function, enabled = true,
//             danger = false, separator = false,
//             confirm: { title, body, actionText, action } }]
// An entry with `confirm` swaps the menu for a confirmation (the panel glides
// to the new size) instead of running at once.
// Keyboard: Up/Down/Home/End move, Enter/Space run, Esc closes (or leaves the
// confirmation). A click outside closes. Coordinates are this item's.
import QtQuick
import Lugh.UI

FocusScope {
    id: menu

    property int maxWidth: 300
    property int minWidth: 184
    readonly property bool opened: _open
    readonly property bool shown: morph.shown
    signal closed()

    property bool _open: false
    property var _entries: []
    property var _confirm: null
    property Item _prevFocus: null
    property int _current: -1
    property real _cx: 0
    property real _bottom: 0
    property real _rowsWidth: 0
    readonly property int _pad: 6
    readonly property real _w: _confirm ? 264 : Math.max(minWidth, Math.min(maxWidth, _rowsWidth + 2 * _pad))
    readonly property real _maxH: Math.max(60, _bottom - Theme.space4)
    readonly property real _h: Math.min(_maxH, (_confirm ? confirmCol.implicitHeight + 2 * Theme.space12 : col.height + 2 * _pad))

    function popup(entries, originRect, originRadius, centerX, bottomY) {
        _confirm = null;
        _entries = entries;
        _cx = centerX;
        _bottom = bottomY;
        let w = 0;
        for (let i = 0; i < rows.count; ++i) {
            const it = rows.itemAt(i);
            if (it) w = Math.max(w, it.implicitWidth);
        }
        _rowsWidth = w;
        _current = -1;
        flick.contentY = 0;
        morph.originRect = originRect;
        morph.originRadius = originRadius;
        _prevFocus = Window.activeFocusItem;
        _open = true;
        forceActiveFocus();
    }
    function close() {
        if (!_open) return;
        _open = false;
        // Hand the keyboard back to whoever had it (the Dock refocuses a tile).
        const prev = _prevFocus;
        _prevFocus = null;
        if (prev && prev !== menu) prev.forceActiveFocus();
        else menu.focus = false;
        closed();
    }
    function _run(i) {
        const e = _entries[i];
        if (!e || e.separator || e.enabled === false) return;
        if (e.confirm) {
            _confirm = e.confirm;
            cancelButton.forceActiveFocus(Qt.TabFocusReason);
            return;
        }
        close();
        if (e.action) e.action();
    }
    function _step(from, dir) {
        const n = _entries.length;
        for (let k = 1; k <= n; ++k) {
            const i = ((from + dir * k) % n + n) % n;
            const e = _entries[i];
            if (!e.separator && e.enabled !== false) { _current = i; _reveal(i); return; }
        }
    }
    function _reveal(i) {
        const it = rows.itemAt(i);
        if (!it) return;
        if (it.y < flick.contentY) flick.contentY = it.y;
        else if (it.y + it.height > flick.contentY + flick.height) flick.contentY = it.y + it.height - flick.height;
    }

    Keys.onPressed: event => {
        const k = event.key;
        if (k === Qt.Key_Escape) { if (_confirm) { _confirm = null; menu.forceActiveFocus(); } else close(); }
        else if (_confirm) return;
        else if (k === Qt.Key_Down) _step(_current, 1);
        else if (k === Qt.Key_Up) _step(_current < 0 ? 0 : _current, -1);
        else if (k === Qt.Key_Home) _step(-1, 1);
        else if (k === Qt.Key_End) _step(0, -1);
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) _run(_current);
        else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) close();
        else return;
        event.accepted = true;
    }

    // Outside click closes.
    MouseArea {
        anchors.fill: parent
        enabled: menu._open
        acceptedButtons: Qt.AllButtons
        onPressed: menu.close()
    }

    MorphPanel {
        id: morph
        anchors.fill: parent
        open: menu._open
        radius: Theme.radiusLg
        elevation: "popover"
        targetRect: Qt.rect(Math.round(Math.max(Theme.space8, Math.min(menu.width - menu._w - Theme.space8, menu._cx - menu._w / 2))),
                            Math.round(menu._bottom - menu._h), menu._w, menu._h)

        Flickable {
            id: flick
            x: menu._pad
            y: menu._pad
            width: parent.width - 2 * menu._pad
            height: parent.height - 2 * menu._pad
            contentHeight: col.height
            clip: contentHeight > height
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            visible: !menu._confirm
            Accessible.role: Accessible.PopupMenu

            Column {
                id: col
                width: flick.width

                Repeater {
                    id: rows
                    model: menu._entries

                    Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool sep: modelData.separator === true
                        readonly property bool on: modelData.enabled !== false
                        readonly property bool current: menu._current === index
                        readonly property color fg: modelData.danger ? Theme.danger : Theme.text

                        implicitWidth: sep ? 0 : Theme.space8 + 16 + Theme.space8 + Math.ceil(text.implicitWidth) + Theme.space12
                        width: col.width
                        height: sep ? 9 : 30
                        opacity: on ? 1 : Theme.disabledOpacity

                        Accessible.role: sep ? Accessible.Separator : Accessible.MenuItem
                        Accessible.name: sep ? "" : modelData.text
                        Accessible.onPressAction: menu._run(index)

                        Rectangle {
                            visible: row.sep
                            x: Theme.space8
                            y: 4
                            width: parent.width - 2 * Theme.space8
                            height: 1
                            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12)
                        }
                        Rectangle {
                            anchors.fill: parent
                            visible: !row.sep && row.on && (row.current || area.pressed)
                            radius: Theme.radiusMd - 2
                            color: area.pressed ? Theme.pressedOverlay : Theme.hoverOverlay
                            border.width: row.current && menu.activeFocus && !area.containsMouse ? 1 : 0
                            border.color: Theme.focusRing
                        }
                        Icon {
                            visible: !row.sep
                            x: Theme.space8
                            anchors.verticalCenter: parent.verticalCenter
                            name: row.sep ? "" : (row.modelData.iconName || "")
                            size: 16
                            color: row.modelData.danger ? Theme.danger : Theme.textMuted
                        }
                        Text {
                            id: text
                            visible: !row.sep
                            x: Theme.space8 + 16 + Theme.space8
                            width: parent.width - x - Theme.space8
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.sep ? "" : row.modelData.text
                            font: Theme.typeLabel
                            color: row.fg
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            Accessible.ignored: true
                        }
                        MouseArea {
                            id: area
                            anchors.fill: parent
                            enabled: !row.sep && row.on
                            hoverEnabled: true
                            onContainsMouseChanged: if (containsMouse) menu._current = row.index
                            onClicked: menu._run(row.index)
                        }
                    }
                }
            }
        }

        Column {
            id: confirmCol
            x: Theme.space12
            y: Theme.space12
            width: parent.width - 2 * Theme.space12
            spacing: Theme.space4
            visible: menu._confirm !== null

            Text {
                width: parent.width
                text: menu._confirm ? menu._confirm.title : ""
                font: Theme.typeBodyStrong
                color: Theme.text
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
            Text {
                width: parent.width
                text: menu._confirm ? menu._confirm.body : ""
                font: Theme.typeCaption
                color: Theme.textMuted
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
            Item { width: 1; height: Theme.space8 }
            Row {
                anchors.right: parent.right
                spacing: Theme.space8
                Button {
                    id: cancelButton
                    text: qsTr("Cancel")
                    size: "sm"
                    variant: "ghost"
                    KeyNavigation.right: confirmButton
                    KeyNavigation.tab: confirmButton
                    onClicked: menu.close()
                }
                Button {
                    id: confirmButton
                    text: menu._confirm ? menu._confirm.actionText : ""
                    size: "sm"
                    variant: "danger"
                    KeyNavigation.left: cancelButton
                    KeyNavigation.tab: cancelButton
                    onClicked: {
                        const c = menu._confirm;
                        menu.close();
                        if (c && c.action) c.action();
                    }
                }
            }
        }
    }
}

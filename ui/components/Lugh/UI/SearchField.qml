// Search input (API.md): leading search icon, clear button when not empty.
//
//   SearchField { placeholderText: qsTr("Search settings") }
//   SearchField { large: true; busy: results.loading }   // launcher
//
// large: the launcher's field: 52 px tall, 20 px text, transparent with no
// border (it sits on the launcher's glass), 22 px icon, accent caret.
// busy: a Spinner replaces the search icon.
// Esc clears the text first; when already empty the key is left unhandled so
// the surrounding surface (launcher, popover) can close.
import QtQuick
import QtQuick.Templates as T

T.TextField {
    id: control

    property bool large: false
    property bool busy: false

    readonly property int _fieldHeight: large ? 52 : 36
    readonly property int _iconSize: large ? 22 : 16
    readonly property font _largeFont: Qt.font({ family: Theme.typeTitle2.family,
                                                 pixelSize: Theme.typeTitle2.pixelSize,
                                                 weight: Theme.typeBody.weight })
    readonly property bool _keyboardFocus: activeFocus
        && (focusReason === Qt.TabFocusReason || focusReason === Qt.BacktabFocusReason
            || focusReason === Qt.ShortcutFocusReason)
    readonly property bool _showClear: length > 0 && enabled && !readOnly

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            contentWidth + leftPadding + rightPadding)
    implicitHeight: _fieldHeight

    leftPadding: (large ? Theme.space16 : Theme.space12) + _iconSize + (large ? Theme.space12 : Theme.space8)
    rightPadding: _showClear ? clearButton.width + (large ? Theme.space12 : Theme.space4) + Theme.space4
                             : (large ? Theme.space16 : Theme.space12)
    topPadding: 0
    bottomPadding: 0

    verticalAlignment: TextInput.AlignVCenter
    font: large ? _largeFont : Theme.typeBody
    color: Theme.text
    placeholderText: qsTr("Search")
    placeholderTextColor: Theme.textMuted
    selectionColor: Theme.selectedBg
    selectedTextColor: Theme.accentText
    selectByMouse: true
    inputMethodHints: Qt.ImhNoPredictiveText
    opacity: enabled ? 1 : Theme.disabledOpacity

    Accessible.role: Accessible.EditableText
    Accessible.name: placeholderText
    Accessible.description: busy ? qsTr("Searching") : ""

    Keys.onEscapePressed: event => {
        if (control.length > 0) control.clear();
        else event.accepted = false;
    }

    // Accent caret, 2 px in the large field, blinking on the render thread.
    cursorDelegate: Rectangle {
        id: caret
        width: control.large ? 2 : 1
        color: control.large ? Theme.accent : Theme.text
        visible: control.activeFocus && !control.readOnly && control.selectionStart === control.selectionEnd
        onXChanged: if (visible) blink.restart()
        SequentialAnimation on opacity {
            id: blink
            running: caret.visible
            loops: Animation.Infinite
            PropertyAction { value: 1 }
            PauseAnimation { duration: 530 }
            PropertyAction { value: 0 }
            PauseAnimation { duration: 530 }
        }
    }

    Text {
        x: control.leftPadding
        width: control.width - control.leftPadding - control.rightPadding
        height: control.height
        text: control.placeholderText
        font: control.font
        color: control.placeholderTextColor
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        renderType: control.renderType
        visible: control.length === 0 && control.preeditText === ""
        Accessible.ignored: true
    }

    Icon {
        x: control.large ? Theme.space16 : Theme.space12
        y: (control.height - height) / 2
        visible: !control.busy
        name: "search"
        size: control._iconSize
        color: control.large && control.activeFocus ? Theme.text : Theme.textMuted
    }
    Spinner {
        x: (control.large ? Theme.space16 : Theme.space12) + (control._iconSize - width) / 2
        y: (control.height - height) / 2
        visible: control.busy
        running: control.busy
        size: control.large ? 20 : 16
    }

    IconButton {
        id: clearButton
        x: control.width - width - (control.large ? Theme.space12 : Theme.space4)
        y: (control.height - height) / 2
        visible: control._showClear
        iconName: "x"
        tooltip: qsTr("Clear search")
        size: control.large ? 32 : 28
        iconSize: control.large ? 18 : 16
        focusPolicy: Qt.NoFocus
        onClicked: { control.clear(); control.forceActiveFocus(Qt.MouseFocusReason); }
    }

    background: Rectangle {
        implicitWidth: control.large ? 560 : 240
        radius: Theme.radiusSm
        color: control.large ? "transparent"
            : control.hovered && control.enabled && !control.activeFocus
                ? Qt.tint(Theme.surface2, Theme.hoverOverlay) : Theme.surface2
        border.width: control.large ? 0 : 1
        border.color: control.activeFocus ? Theme.accent : Theme.border

        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
        Behavior on border.color { ColorAnimation { duration: Theme.durMicro } }

        FocusRing {
            show: !control.large && control._keyboardFocus
        }
    }
}

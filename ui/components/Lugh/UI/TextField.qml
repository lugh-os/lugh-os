// Single-line text input (DESIGN-SYSTEM §7, API.md).
//
//   TextField { placeholderText: "Hostname"; iconName: "server" }
//   TextField { placeholderText: "Password"; password: true }
//   TextField { text: host; errorText: valid ? "" : "Use letters, digits and hyphens." }
//
// 36 px field on surface2 with a 1 px border. Focus turns the border accent
// and, for keyboard focus, adds the FocusRing. errorText adds a danger border
// and a message with an icon below the field (the control grows by its
// height, so layouts reflow instead of overlapping).
import QtQuick
import QtQuick.Templates as T

T.TextField {
    id: control

    // Screen-reader name; empty = derived from the visible label.
    property string accessibleName: ""
    property string iconName: ""
    property string errorText: ""
    property bool password: false
    property bool clearable: false

    property bool _revealed: false
    readonly property bool _hasError: errorText.length > 0
    readonly property int _fieldHeight: 36
    readonly property real _errorHeight: _hasError ? errorRow.implicitHeight + Theme.space4 : 0
    readonly property bool _keyboardFocus: activeFocus
        && (focusReason === Qt.TabFocusReason || focusReason === Qt.BacktabFocusReason
            || focusReason === Qt.ShortcutFocusReason)
    readonly property bool _showClear: clearable && length > 0 && enabled && !readOnly
    readonly property real _trailingWidth: (_showClear ? clearButton.width + Theme.space2 : 0)
        + (password ? revealButton.width + Theme.space2 : 0)

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            contentWidth + leftPadding + rightPadding)
    implicitHeight: _fieldHeight + _errorHeight

    leftPadding: iconName !== "" ? Theme.space12 + 16 + Theme.space8 : Theme.space12
    rightPadding: _trailingWidth > 0 ? Theme.space4 + _trailingWidth : Theme.space12
    topPadding: 0
    bottomPadding: _errorHeight

    verticalAlignment: TextInput.AlignVCenter
    font: Theme.typeBody
    color: Theme.text
    placeholderTextColor: Theme.textMuted
    selectionColor: Theme.selectedBg
    selectedTextColor: Theme.accentText
    selectByMouse: true
    echoMode: password && !_revealed ? TextInput.Password : TextInput.Normal
    passwordCharacter: "•"
    opacity: enabled ? 1 : Theme.disabledOpacity

    Accessible.role: Accessible.EditableText
    Accessible.name: accessibleName !== "" ? accessibleName : placeholderText
    // Qt blanks Accessible.name on password edits, so repeat the label in the
    // description (which it keeps) for password fields.
    Accessible.description: password ? [Accessible.name || placeholderText, errorText].filter(t => t).join(". ") : errorText
    Accessible.passwordEdit: password && !_revealed

    // Template TextField draws no placeholder; this one sits in the field box.
    Text {
        x: control.leftPadding
        y: 0
        width: control.width - control.leftPadding - control.rightPadding
        height: control._fieldHeight
        text: control.placeholderText
        font: control.font
        color: control.placeholderTextColor
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        renderType: control.renderType
        visible: control.length === 0 && control.preeditText === "" && control.placeholderText !== ""
        Accessible.ignored: true
    }

    Icon {
        x: Theme.space12
        y: (control._fieldHeight - height) / 2
        visible: control.iconName !== ""
        name: control.iconName
        size: 16
        color: control._hasError ? Theme.danger : Theme.textMuted
    }

    Row {
        x: control.width - width - Theme.space4
        y: (control._fieldHeight - height) / 2
        spacing: Theme.space2

        IconButton {
            id: clearButton
            visible: control._showClear
            iconName: "x"
            tooltip: qsTr("Clear")
            size: 28
            iconSize: 16
            focusPolicy: Qt.NoFocus
            onClicked: { control.clear(); control.forceActiveFocus(Qt.MouseFocusReason); }
        }
        IconButton {
            id: revealButton
            visible: control.password
            iconName: control._revealed ? "eye-off" : "eye"
            tooltip: control._revealed ? qsTr("Hide password") : qsTr("Show password")
            size: 28
            iconSize: 16
            enabled: control.enabled
            // Tab reaches it after the field; a click keeps focus in the field.
            focusPolicy: Qt.TabFocus
            checkable: true
            checked: control._revealed
            onClicked: control._revealed = !control._revealed
        }
    }

    Row {
        id: errorRow
        x: Theme.space2
        y: control._fieldHeight + Theme.space4
        width: control.width - Theme.space2
        spacing: Theme.space4
        visible: control._hasError

        Icon {
            id: errorIcon
            name: "circle-alert"
            size: 14
            color: Theme.danger
            // Centered on the first line of the (possibly wrapped) message.
            y: Math.round((errorLabel.implicitHeight / Math.max(1, errorLabel.lineCount) - height) / 2)
        }
        Text {
            id: errorLabel
            width: parent.width - errorIcon.width - parent.spacing
            text: control.errorText
            font: Theme.typeCaption
            color: Theme.danger
            wrapMode: Text.Wrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
    }

    background: Rectangle {
        implicitWidth: 240
        height: control._fieldHeight
        radius: Theme.radiusSm
        color: control.hovered && control.enabled && !control.activeFocus
            ? Qt.tint(Theme.surface2, Theme.hoverOverlay) : Theme.surface2
        border.width: 1
        border.color: control._hasError ? Theme.danger
            : control.activeFocus ? Theme.accent : Theme.border

        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
        Behavior on border.color { ColorAnimation { duration: Theme.durMicro } }

        FocusRing {
            show: control._keyboardFocus
        }
    }
}

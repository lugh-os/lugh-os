// Menu entry (API.md). Use inside Menu.
//
//   MenuItem { text: qsTr("Copy"); iconName: "copy"; shortcutText: "Ctrl+C" }
//   MenuItem { text: qsTr("Show hidden files"); checkable: true; checked: true }
//   MenuItem { text: qsTr("Delete"); iconName: "trash-2"; danger: true }
//
// 32 px tall. Highlight (hover or arrow keys) = surface2, pressed = surface3
// (one step stronger in dark, where surface2 on surface is too faint).
// A checked item shows a check glyph in the leading column (not color alone).
// shortcutText sits right-aligned and muted; submenus get a chevron.
import QtQuick
import QtQuick.Templates as T

T.MenuItem {
    id: control

    property string iconName: ""
    property string shortcutText: ""
    property bool danger: false

    readonly property bool _leading: (menu && menu._reserveIcon === true) || iconName !== "" || checkable
    readonly property color _fg: danger ? Theme.danger : Theme.text

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             implicitContentHeight + topPadding + bottomPadding)

    leftPadding: Theme.space8
    rightPadding: Theme.space8
    topPadding: 0
    bottomPadding: 0
    spacing: Theme.space8
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.disabledOpacity

    Accessible.role: Accessible.MenuItem
    Accessible.name: text
    Accessible.description: shortcutText
    Accessible.checkable: checkable
    Accessible.checked: checked

    contentItem: Item {
        implicitWidth: (control._leading ? 16 + control.spacing : 0) + label.implicitWidth
            + (control.shortcutText !== "" ? Theme.space24 + shortcut.implicitWidth : 0)
            + (control.subMenu ? control.spacing + 16 : 0)
        implicitHeight: label.implicitHeight

        Icon {
            id: lead
            visible: control._leading
            anchors.verticalCenter: parent.verticalCenter
            name: control.checkable ? (control.checked ? "check" : "") : control.iconName
            size: 16
            color: control.checkable ? Theme.accentText : control.danger ? Theme.danger : Theme.textMuted
        }
        Text {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            x: control._leading ? 16 + control.spacing : 0
            width: Math.min(implicitWidth, (shortcut.visible ? shortcut.x - Theme.space16 : arrow.visible ? arrow.x - control.spacing : parent.width) - x)
            text: control.text
            font: Theme.typeBody
            color: control._fg
            elide: Text.ElideRight
        }
        Text {
            id: shortcut
            visible: control.shortcutText !== ""
            anchors.verticalCenter: parent.verticalCenter
            x: (arrow.visible ? arrow.x - control.spacing : parent.width) - width
            text: control.shortcutText
            font: Theme.typeCaption
            color: Theme.textMuted
        }
        Icon {
            id: arrow
            visible: control.subMenu !== null
            anchors.verticalCenter: parent.verticalCenter
            x: parent.width - width
            name: "chevron-right"
            size: 16
            color: Theme.textMuted
        }
    }

    // Template menus nest arrow/indicator into contentItem above; keep these
    // empty so T.MenuItem adds nothing on its own.
    arrow: null
    indicator: null

    background: Rectangle {
        implicitWidth: 180
        implicitHeight: 32
        radius: Theme.radiusSm
        color: !control.enabled ? "transparent"
            : control.down ? (Theme.dark ? Qt.tint(Theme.surface3, Theme.pressedOverlay) : Theme.surface3)
            : control.highlighted ? (Theme.dark ? Theme.surface3 : Theme.surface2)
            : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }
    }
}

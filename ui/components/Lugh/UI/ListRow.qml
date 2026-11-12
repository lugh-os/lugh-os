// List row for settings lists, launcher results, pickers (API.md).
//
//   ListRow { title: "Wi-Fi"; subtitle: "Home-5G"; iconName: "wifi"; showChevron: true }
//   ListRow { title: app.name; appIcon: app.icon; highlighted: ListView.isCurrentItem }
//   ListRow { title: "Bluetooth"; trailing: Component { Toggle { checked: true } } }
//
// 40 px (title) / 52 px (title + subtitle). Background is inset 4 px with
// radiusMd. hover = surface2, pressed = surface3. highlighted (the keyboard-
// current row) = selectedBg + accent-text title + a 3 px accent bar at the
// left edge; selected = selectedBg + accent-text title + a check glyph. Both
// carry a shape cue, never color alone.
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T

T.ItemDelegate {
    id: control

    // Screen-reader name; empty = derived from the visible label.
    property string accessibleName: ""
    property string title: ""
    property string subtitle: ""
    property string iconName: ""
    property string appIcon: ""
    property int iconSize: appIcon !== "" ? 32 : 20
    property string trailingText: ""
    property bool showChevron: false
    property bool selected: false
    property Component trailing: null
    property bool danger: false

    readonly property bool _marked: highlighted || selected
    readonly property color _titleColor: danger ? Theme.danger : _marked ? Theme.accentText : Theme.text

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: subtitle !== "" ? 52 : 40

    leftInset: Theme.space4
    rightInset: Theme.space4
    topInset: 1
    bottomInset: 1
    leftPadding: Theme.space4 + Theme.space12
    rightPadding: Theme.space4 + Theme.space12
    topPadding: 0
    bottomPadding: 0
    spacing: Theme.space12
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : Theme.disabledOpacity

    Accessible.role: Accessible.ListItem
    Accessible.name: accessibleName !== "" ? accessibleName : title
    Accessible.description: subtitle !== "" ? subtitle : trailingText
    Accessible.selectable: true
    Accessible.selected: selected || highlighted

    contentItem: RowLayout {
        spacing: control.spacing

        Icon {
            visible: control.iconName !== "" && control.appIcon === ""
            name: control.iconName
            size: control.iconSize
            color: control.danger ? Theme.danger : control._marked ? Theme.accentText : Theme.textMuted
            Layout.preferredWidth: control.iconSize
            Layout.preferredHeight: control.iconSize
        }
        AppIcon {
            visible: control.appIcon !== ""
            iconName: control.appIcon
            fallbackText: control.title
            size: control.iconSize
            Layout.preferredWidth: control.iconSize
            Layout.preferredHeight: control.iconSize
        }

        ColumnLayout {
            spacing: 1
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter

            Text {
                text: control.title
                font: Theme.typeBody
                color: control._titleColor
                elide: Text.ElideRight
                maximumLineCount: 1
                Layout.fillWidth: true
                Behavior on color { ColorAnimation { duration: Theme.durMicro } }
            }
            Text {
                visible: control.subtitle !== ""
                text: control.subtitle
                font: Theme.typeCaption
                color: Theme.textMuted
                elide: Text.ElideRight
                maximumLineCount: 1
                Layout.fillWidth: true
            }
        }

        Text {
            visible: control.trailingText !== ""
            text: control.trailingText
            font: Theme.typeCaption
            color: Theme.textMuted
            elide: Text.ElideRight
            Layout.maximumWidth: control.availableWidth * 0.4
        }

        Loader {
            active: control.trailing !== null
            visible: active
            sourceComponent: control.trailing
            Layout.alignment: Qt.AlignVCenter
        }

        Icon {
            visible: control.selected
            name: "check"
            size: 16
            color: Theme.accentText
            Layout.preferredWidth: 16
            Layout.preferredHeight: 16
        }

        Icon {
            visible: control.showChevron
            name: "chevron-right"
            size: 16
            color: Theme.textMuted
            Layout.preferredWidth: 16
            Layout.preferredHeight: 16
        }
    }

    background: Rectangle {
        implicitWidth: 240
        radius: Theme.radiusMd
        color: control._marked ? Theme.selectedBg
            : !control.enabled ? "transparent"
            : control.down ? Theme.surface3
            : control.hovered ? Theme.surface2
            : "transparent"

        Behavior on color { ColorAnimation { duration: Theme.durMicro } }

        // Keyboard-current marker: a shape cue next to the tint.
        Rectangle {
            x: 0
            width: 3
            height: Math.max(12, parent.height - 2 * Theme.radiusMd)
            anchors.verticalCenter: parent.verticalCenter
            radius: width / 2
            color: control.danger ? Theme.danger : Theme.accent
            opacity: control.highlighted ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
        }

        FocusRing { show: control.visualFocus }
    }
}

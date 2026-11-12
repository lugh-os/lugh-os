// Sidebar entry of the Customize panel: icon + label (icon only when
// `compact`, with a tooltip; a cut-off label gets one too). The sidebar owns keyboard focus and moves the
// current entry with the arrows, so the entries themselves never take focus;
// `focusShown` draws the ring on the current one.
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI

T.AbstractButton {
    id: control

    property string iconName: ""
    property bool current: false
    property bool compact: false
    property bool focusShown: false
    property int matchCount: -1     // ≥ 0 while searching: matches in this section

    implicitWidth: compact ? 44 : 200
    implicitHeight: 40
    focusPolicy: Qt.NoFocus
    hoverEnabled: true

    Accessible.role: Accessible.PageTab
    Accessible.name: text
    Accessible.checkable: true
    Accessible.checked: current
    Accessible.description: matchCount >= 0 ? (matchCount === 1 ? qsTr("1 matching setting") : qsTr("%1 matching settings").arg(matchCount)) : ""

    background: Rectangle {
        radius: Theme.radiusMd
        color: control.current ? Theme.selectedBg
             : control.down ? Theme.pressedOverlay
             : control.hovered ? Theme.hoverOverlay : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.durMicro } }

        // current marker: a shape cue next to the tint
        Rectangle {
            x: 0
            width: 3
            height: 16
            radius: 1.5
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.accent
            opacity: control.current ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
        }

        FocusRing { show: control.focusShown }
    }

    contentItem: RowLayout {
        spacing: Theme.space12
        opacity: control.matchCount === 0 ? 0.5 : 1

        Icon {
            name: control.iconName
            size: 18
            color: control.current ? Theme.accentText : Theme.textMuted
            Layout.leftMargin: control.compact ? (control.width - 18) / 2 : Theme.space12
            Layout.preferredWidth: 18
        }
        Text {
            id: label
            visible: !control.compact
            text: control.text
            font: control.current ? Theme.typeBodyStrong : Theme.typeBody
            color: control.current ? Theme.accentText : Theme.text
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        Text {
            visible: !control.compact && control.matchCount > 0
            text: control.matchCount
            font: Theme.typeCaptionTnum
            color: Theme.textMuted
            Layout.rightMargin: Theme.space12
        }
    }

    Tooltip {
        text: control.text
        visible: (control.compact || label.truncated) && control.hovered
    }
}

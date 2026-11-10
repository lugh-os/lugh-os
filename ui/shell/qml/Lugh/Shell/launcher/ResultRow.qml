// One launcher result (delegate of LauncherBody's ListView). Kept flat and
// light (no Loader, no Layouts) because rows are recycled on every keystroke.
//
// Kinds: app / window → AppIcon 32; setting / file / command → symbolic Icon
// on a soft plate; calc → a big answer row (typeTitle2, tabular figures).
// The keyboard-current tint is the ListView's single moving highlight; this
// row only adds the trailing "Open ↵" hint when current.
import QtQuick
import Lugh.UI
import "match.js" as Match

Item {
    id: row

    required property int index
    required property string kind
    required property string title
    required property string subtitle
    required property string icon

    property string query: ""
    property bool current: false

    signal hoverMoved(int index, point globalPos)
    signal clicked(int index)

    readonly property bool isCalc: kind === "calc"
    readonly property bool isApp: kind === "app" || kind === "window"
    readonly property string actionText: kind === "window" ? qsTr("Switch")
        : kind === "calc" ? qsTr("Copy")
        : kind === "command" ? qsTr("Run")
        : qsTr("Open")

    // Inset of the row shape (and of the list highlight) from the panel edge.
    readonly property int inset: Theme.space8

    implicitHeight: isCalc ? 72 : 52

    Accessible.role: Accessible.ListItem
    Accessible.name: isCalc ? qsTr("%1 equals %2").arg(row.query).arg(row.title) : row.title
    Accessible.description: row.subtitle
    Accessible.selectable: true
    Accessible.selected: row.current

    // Pressed feedback (hover/current tint is the list highlight).
    Rectangle {
        x: row.inset
        width: row.width - 2 * row.inset
        height: row.height - 2
        y: 1
        radius: Theme.radiusMd
        color: Theme.pressedOverlay
        opacity: mouse.pressed ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }
    }

    // ---- leading: app art or symbolic plate ------------------------------
    Item {
        id: lead
        x: row.inset + Theme.space12
        width: row.isCalc ? 40 : 32
        height: width
        anchors.verticalCenter: parent.verticalCenter

        AppIcon {
            anchors.fill: parent
            visible: row.isApp
            iconName: row.isApp ? row.icon : ""
            fallbackText: row.title
            size: 32
        }
        Rectangle {
            anchors.fill: parent
            visible: !row.isApp
            radius: row.isCalc ? 10 : 8
            color: row.current ? Theme.surface : Theme.dark ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(0, 0, 0, 0.045)
            border.width: 1
            border.color: row.current ? Theme.border : "transparent"

            Icon {
                anchors.centerIn: parent
                name: row.isApp ? "" : row.icon
                size: row.isCalc ? 20 : 18
                color: row.current ? Theme.accentText : Theme.textMuted
            }
        }
    }

    // ---- texts -------------------------------------------------------------
    Column {
        anchors.left: lead.right
        anchors.leftMargin: Theme.space12
        anchors.right: hint.visible ? hint.left : parent.right
        anchors.rightMargin: hint.visible ? Theme.space12 : row.inset + Theme.space12
        anchors.verticalCenter: parent.verticalCenter
        spacing: row.isCalc ? 0 : 1

        // calc: the expression on top, small and muted ("12*7+3 =").
        Text {
            width: parent.width
            visible: row.isCalc
            text: row.query.trim().replace(/^=/, "") + " ="
            font: Theme.typeCaptionTnum
            color: Theme.textMuted
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: row.isCalc ? Match.escapeHtml(row.title)
                             : Match.emphasize(row.title, row.query, Theme.accentText)
            textFormat: Text.StyledText
            font: row.isCalc ? row._answerFont : Theme.typeBody
            color: Theme.text
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Text {
            width: parent.width
            visible: row.subtitle !== "" && !row.isCalc
            text: Match.emphasize(row.subtitle, row.query, "")
            textFormat: Text.StyledText
            font: Theme.typeCaption
            color: Theme.textMuted
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }
    readonly property font _answerFont: Qt.font({ family: Theme.fontUi, pixelSize: Theme.typeTitle2.pixelSize,
                                                  weight: Theme.typeTitle2.weight, features: { "tnum": 1 } })

    // ---- trailing hint (current row only) ---------------------------------
    Row {
        id: hint
        anchors.right: parent.right
        anchors.rightMargin: row.inset + Theme.space12
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space8
        visible: opacity > 0
        opacity: row.current ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durMicro } }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: row.actionText
            font: Theme.typeCaption
            color: Theme.textMuted
        }
        Keycap { text: "↵"; anchors.verticalCenter: parent.verticalCenter }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.leftMargin: row.inset
        anchors.rightMargin: row.inset
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // LauncherBody only lets a real pointer move (a new global position)
        // take the highlight, so results appearing under a resting cursor
        // don't steal it from the keyboard.
        onPositionChanged: mouse => row.hoverMoved(row.index, mapToGlobal(mouse.x, mouse.y))
        onClicked: row.clicked(row.index)
    }
}

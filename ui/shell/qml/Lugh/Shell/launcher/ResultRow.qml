// One launcher result (delegate of LauncherBody's ListView). Flat and light
// (no Loader, no Layouts, no background of its own): rows are recycled on
// every keystroke. The highlight pill and its "Open ↵" hint belong to the
// list; the current row only keeps `hintWidth` free on its right.
//
// 44 px: icon 28 (app / window → AppIcon; others → a symbolic Icon on a soft
// round plate), then title and, on the same line, the muted subtitle.
// calc → 56 px: "12*7+3 =" and the answer large, in tabular figures.
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
    // Inset of the highlight pill from the panel edge.
    property int inset: 6
    property real hintWidth: 0

    signal hoverMoved(int index, point globalPos)
    signal pressChanged(int index, bool down)
    signal clicked(int index)

    readonly property bool isCalc: kind === "calc"
    readonly property bool isApp: kind === "app" || kind === "window"
    readonly property string actionText: kind === "window" ? qsTr("Switch")
        : kind === "calc" ? qsTr("Copy")
        : kind === "command" ? qsTr("Run")
        : qsTr("Open")
    // Backends may send names the icon font does not have.
    readonly property string _glyph: isApp ? ""
        : IconNames.has(icon) ? icon
        : kind === "setting" ? "settings"
        : kind === "calc" ? "calculator"
        : kind === "command" ? "terminal"
        : kind === "file" ? "file" : "search"

    readonly property real _textLeft: inset + Theme.space8 + 28 + 10
    readonly property real _avail: Math.max(0, width - _textLeft
        - (current && hintWidth > 0 ? inset + hintWidth + Theme.space12 : inset + Theme.space16))

    implicitHeight: isCalc ? 56 : 44

    Accessible.role: Accessible.ListItem
    Accessible.name: isCalc ? qsTr("%1 equals %2").arg(row.query).arg(row.title) : row.title
    Accessible.description: row.subtitle
    Accessible.selectable: true
    Accessible.selected: row.current

    // ---- leading: app art or symbolic plate ------------------------------
    AppIcon {
        x: row.inset + Theme.space8
        anchors.verticalCenter: parent.verticalCenter
        visible: row.isApp
        iconName: row.isApp ? row.icon : ""
        fallbackText: row.title
        size: 28
    }
    Rectangle {
        x: row.inset + Theme.space8
        anchors.verticalCenter: parent.verticalCenter
        width: 28
        height: 28
        radius: 14
        visible: !row.isApp
        color: row.current ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.22)
                           : Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)

        Icon {
            anchors.centerIn: parent
            name: row._glyph
            size: 16
            color: row.current ? Theme.accentText : Theme.textMuted
        }
    }

    // ---- texts: one line ---------------------------------------------------
    // primary: the title (calc: the answer). secondary: the subtitle after it
    // (calc: the expression before it).
    readonly property font _answerFont: Qt.font({ family: Theme.fontUi, pixelSize: Theme.typeTitle2.pixelSize,
                                                  weight: Theme.typeTitle2.weight, features: { "tnum": 1 } })
    Text {
        id: primary
        x: row._textLeft + (row.isCalc ? secondary.width + Theme.space8 : 0)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, row._avail - (row.isCalc ? secondary.width + Theme.space8 : 0))
        text: row.isCalc ? Match.escapeHtml(row.title)
                         : Match.emphasize(row.title, row.query, Theme.accentText)
        textFormat: Text.StyledText
        font: row.isCalc ? row._answerFont : Theme.typeBody
        color: Theme.text
        elide: Text.ElideRight
        maximumLineCount: 1
    }
    Text {
        id: secondary
        readonly property real room: row.isCalc ? row._avail * 0.6
                                                : row._avail - primary.width - Theme.space8
        x: row.isCalc ? row._textLeft : primary.x + primary.width + (primary.width > 0 ? Theme.space8 : 0)
        anchors.baseline: primary.baseline
        width: Math.max(0, Math.min(implicitWidth, room))
        visible: text !== "" && room >= 40
        text: row.isCalc ? Match.escapeHtml(row.query.trim().replace(/^=/, "")) + " ="
                         : Match.emphasize(row.subtitle, row.query, "")
        textFormat: Text.StyledText
        font: row.isCalc ? Theme.typeBodyTnum : Theme.typeLabel
        color: Theme.textMuted
        elide: Text.ElideRight
        maximumLineCount: 1
    }

    MouseArea {
        anchors.fill: parent
        anchors.leftMargin: row.inset
        anchors.rightMargin: row.inset
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // LauncherBody only lets a real pointer move (a new global position)
        // take the highlight, so results appearing under a resting cursor
        // don't steal it from the keyboard.
        onPositionChanged: mouse => row.hoverMoved(row.index, mapToGlobal(mouse.x, mouse.y))
        onPressedChanged: row.pressChanged(row.index, pressed)
        onClicked: row.clicked(row.index)
    }
}

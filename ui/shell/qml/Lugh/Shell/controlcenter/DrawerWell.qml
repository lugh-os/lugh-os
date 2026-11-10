// The inset surface a control-center drawer's content sits in: a faint well
// with a hairline, 6 px padding, `topGap` px of air above it. Sized by its
// content (give children `width: parent.width`).
import QtQuick
import Lugh.UI

Item {
    id: root

    property int topGap: Theme.space8
    // Bind to the drawer's `expanded`: `entering` is true for a moment after
    // it opens, which is when rows play their staggered entrance.
    property bool active: false
    property bool entering: false
    default property alias content: inner.data

    implicitHeight: inner.childrenRect.height + 12 + topGap

    onActiveChanged: { entering = active; if (active) settle.restart(); }
    Component.onCompleted: if (active) { entering = true; settle.start(); }
    Timer { id: settle; interval: 400; onTriggered: root.entering = false }

    Rectangle {
        y: root.topGap
        width: root.width
        height: root.implicitHeight - root.topGap
        radius: Theme.radiusLg
        antialiasing: true
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, Theme.dark ? 0.06 : 0.045)
        border.width: 1
        border.color: Theme.glassBorder

        Item {
            id: inner
            x: 6
            y: 6
            width: parent.width - 12
            height: childrenRect.height
        }
    }
}

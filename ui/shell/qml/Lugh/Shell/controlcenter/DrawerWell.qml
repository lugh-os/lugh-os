// The inset surface a control-center drawer's content sits in: a faint well
// with a hairline, 6 px padding, `topGap` px of air above it. Sized by its
// content (give children `width: parent.width`).
import QtQuick
import Lugh.UI

Item {
    id: root

    property int topGap: Theme.space8
    default property alias content: inner.data

    implicitHeight: inner.childrenRect.height + 12 + topGap

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

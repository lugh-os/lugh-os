// Hairline between groups of MenuItems (API.md): 1 px border, 4 px vertical margin.
import QtQuick
import QtQuick.Templates as T

T.MenuSeparator {
    id: control

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             implicitContentHeight + topPadding + bottomPadding)

    topPadding: Theme.space4
    bottomPadding: Theme.space4
    leftPadding: Theme.space4
    rightPadding: Theme.space4

    Accessible.role: Accessible.Separator

    contentItem: Rectangle {
        implicitWidth: 180
        implicitHeight: 1
        color: Theme.border
    }
}

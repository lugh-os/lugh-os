// A believable floating app window for the desktop preview: Lugh-mode chrome
// (DESIGN-SYSTEM §8): rounded 14 px, soft shadow (stronger when focused),
// window buttons on the LEFT (close / minimise / maximise), colour-coded with
// glyphs on hover. Content goes in the default property, below the title bar.
pragma ComponentBehavior: Bound
import QtQuick
import Lugh.UI

Item {
    id: root
    property string title
    property bool focused: false
    // Fill behind the content (the frame itself, so rounded corners stay clean).
    property color bodyColor: Theme.bg
    // Title bar fill; defaults to the body so the window reads as one sheet.
    property color titleBarColor: bodyColor
    property color titleColor: focused ? Theme.text : Theme.textMuted
    readonly property int titleBarHeight: 38
    default property alias content: body.data
    signal activated()
    signal closeRequested()

    Optional {
        anchors.fill: parent
        type: "Shadow"
        props: ({ target: frame, radius: frame.radius, elevation: root.focused ? "window" : "popover" })
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        radius: Theme.radiusLg
        color: root.bodyColor
        border.width: 1
        border.color: Theme.dark ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.10)

        // Title bar (top corners rounded by the frame; bottom edge square).
        Rectangle {
            id: titleBar
            x: 1; y: 1
            width: parent.width - 2
            height: root.titleBarHeight
            radius: frame.radius - 1
            color: root.titleBarColor
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: parent.radius
                color: parent.color
            }
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: Theme.dark ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(0, 0, 0, 0.07)
            }

            Row {
                id: buttons
                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 8
                Repeater {
                    model: [
                        { kind: "close", name: qsTr("Close"), fill: Theme.danger },
                        { kind: "min", name: qsTr("Minimize"), fill: Theme.warningFill },
                        { kind: "max", name: qsTr("Maximize"), fill: Theme.success }
                    ]
                    delegate: Rectangle {
                        id: btn
                        required property var modelData
                        width: 13; height: 13; radius: 6.5
                        color: root.focused || buttonsHover.hovered ? modelData.fill : Theme.surface3
                        border.width: root.focused || buttonsHover.hovered ? 0 : 1
                        border.color: Theme.border
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData.name
                        // Glyphs (shown on hover): ×, −, + drawn as bars.
                        Item {
                            anchors.centerIn: parent
                            width: 7; height: 7
                            visible: buttonsHover.hovered
                            rotation: btn.modelData.kind === "close" ? 45 : 0
                            Rectangle {
                                anchors.centerIn: parent
                                width: 7; height: 1.5; radius: 0.75
                                color: Qt.rgba(0, 0, 0, 0.6)
                            }
                            Rectangle {
                                anchors.centerIn: parent
                                visible: btn.modelData.kind !== "min"
                                width: 1.5; height: 7; radius: 0.75
                                color: Qt.rgba(0, 0, 0, 0.6)
                            }
                        }
                        TapHandler {
                            onTapped: if (btn.modelData.kind === "close") root.closeRequested(); else root.activated()
                        }
                    }
                }
                HoverHandler { id: buttonsHover }
            }

            // Drag the window by its title bar.
            DragHandler {
                target: root
                dragThreshold: 4
                onActiveChanged: if (active) root.activated()
            }

            Text {
                anchors.centerIn: parent
                width: Math.min(implicitWidth, parent.width - 2 * (buttons.width + 28))
                text: root.title
                elide: Text.ElideRight
                font: Theme.typeBodyStrong
                color: root.titleColor
            }
        }

        Item {
            id: body
            anchors {
                fill: parent
                topMargin: root.titleBarHeight + 1
                leftMargin: 1; rightMargin: 1; bottomMargin: 1
            }
        }
    }

    // Click anywhere to focus (raise); content still gets its own clicks.
    // (Default DragThreshold policy only takes a passive grab.)
    TapHandler {
        onPressedChanged: if (pressed) root.activated()
    }
}

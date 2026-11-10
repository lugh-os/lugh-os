// LughUI containers demo: Shadow, GlassPanel, Card, Popover, Dialog,
// Skeleton, EmptyState, ErrorBanner. Left half: a busy warm backdrop to judge
// glass (the real blur comes from the compositor, so here glass shows its
// plain tint). Right half: Theme.bg.
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/components/demos/containers.qml \
//       /tmp/lugh-shots/containers/light.png 1400 900 [900 -- --dark]
//   --modal  shows the danger dialog modal and centered, with the scrim.
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI

Item {
    id: demo
    implicitWidth: 1400
    implicitHeight: 900

    readonly property bool modalDemo: Qt.application.arguments.indexOf("--modal") >= 0
    Component.onCompleted: Theme.dark = Qt.application.arguments.indexOf("--dark") >= 0

    component Label: Text {
        font: Theme.typeCaption
        color: Theme.textMuted
    }

    // ---- left: busy backdrop ----------------------------------------------
    Item {
        id: left
        width: parent.width / 2
        height: parent.height
        clip: true

        Rectangle { anchors.fill: parent; color: Theme.dark ? "#2A1A10" : "#F3D9B8" }
        Rectangle { x: -120; y: -80; width: 520; height: 520; radius: 260; color: Theme.dark ? "#8A4A16" : "#F2A93B" }
        Rectangle { x: 330; y: 140; width: 460; height: 460; radius: 230; color: Theme.dark ? "#7A2E26" : "#E8705A" }
        Rectangle { x: 40; y: 520; width: 420; height: 420; radius: 210; color: Theme.dark ? "#14504F" : "#3FA7A0" }
        Rectangle { x: 470; y: 650; width: 300; height: 300; radius: 150; color: Theme.dark ? "#6B5A12" : "#F5C04A" }
        Repeater {
            model: 14
            Rectangle {
                required property int index
                x: -200 + index * 70; y: -100
                width: 18; height: 1200
                rotation: 28
                color: Theme.dark ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(1, 1, 1, 0.28)
            }
        }

        // GlassPanel at every elevation
        Row {
            x: 40; y: 40
            spacing: 24
            Repeater {
                model: ["none", "menu", "popover", "window"]
                GlassPanel {
                    required property string modelData
                    width: 136; height: 96
                    radius: Theme.radiusLg
                    elevation: modelData
                    Column {
                        anchors.centerIn: parent
                        spacing: 2
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Glass"; font: Theme.typeBodyStrong; color: Theme.text }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData; font: Theme.typeCaption; color: Theme.textMuted }
                    }
                }
            }
        }

        // dock-like glass pill
        GlassPanel {
            x: 40; y: 176
            width: 360; height: 72
            radius: Theme.radiusXl
            elevation: "window"
            Row {
                anchors.centerIn: parent
                spacing: 12
                Repeater {
                    model: ["folder", "globe", "terminal", "settings", "music"]
                    Rectangle {
                        required property string modelData
                        width: 48; height: 48; radius: 12
                        color: Theme.surface2
                        Icon { anchors.centerIn: parent; name: modelData; size: 24; color: Theme.text }
                    }
                }
            }
        }

        // anchor for the glass popover
        Item { id: popAnchor; x: 430; y: 176; width: 1; height: 1 }

        Popover {
            id: glassPop
            parent: popAnchor
            glass: true
            closePolicy: Popover.NoAutoClose
            width: 236
            ColumnLayout {
                width: parent.width
                spacing: Theme.space12
                Text { text: "Wi-Fi"; font: Theme.typeTitle3; color: Theme.text }
                Repeater {
                    model: [["wifi", "Home 5G", "Connected"], ["wifi", "Café Lugh", "Secured"], ["wifi-off", "Guest", "Open"]]
                    RowLayout {
                        required property var modelData
                        spacing: Theme.space8
                        Icon { name: modelData[0]; size: 18; color: Theme.text }
                        Text { Layout.fillWidth: true; text: modelData[1]; font: Theme.typeBody; color: Theme.text }
                        Text { text: modelData[2]; font: Theme.typeCaption; color: Theme.textMuted }
                    }
                }
            }
        }

        // anchor for the normal dialog
        Item { id: dlgAnchorLeft; x: 40; y: 452; width: 448; height: 1 }
        Dialog {
            id: plainDialog
            parent: dlgAnchorLeft
            anchors.centerIn: undefined
            x: 0; y: 0
            modal: false
            dim: false
            title: "Rename workspace"
            text: "Workspace names show in the overview and the top bar."
            primaryText: "Rename"
            TextField {
                width: parent.width
                text: "Design review"
                placeholderText: "Workspace name"
            }
        }
    }

    // ---- right: Theme.bg ----------------------------------------------------
    Rectangle {
        id: right
        x: parent.width / 2
        width: parent.width / 2
        height: parent.height
        color: Theme.bg

        // Cards
        Label { x: 40; y: 20; text: "Card: plain · elevated · interactive (focused)" }
        Row {
            x: 40; y: 40
            spacing: 24
            Repeater {
                model: [["Plain", "Surface with a hairline border.", false, false],
                        ["Elevated", "Adds a menu-level shadow.", true, false],
                        ["Interactive", "Hover, press and focus states.", true, true]]
                Card {
                    id: card
                    required property var modelData
                    required property int index
                    width: 190
                    elevated: modelData[2]
                    interactive: modelData[3]
                    Connections {
                        target: focusTimer
                        function onTriggered() { if (card.interactive) card.forceActiveFocus() }
                    }
                    ColumnLayout {
                        width: parent.width
                        spacing: Theme.space4
                        Text { text: card.modelData[0]; font: Theme.typeTitle3; color: Theme.text }
                        Text { Layout.fillWidth: true; text: card.modelData[1]; font: Theme.typeBody; color: Theme.textMuted; wrapMode: Text.Wrap }
                    }
                }
            }
        }

        // Shadow levels on surface rects
        Label { x: 40; y: 176; text: "Shadow: menu · popover · window" }
        Row {
            x: 40; y: 200
            spacing: 32
            Repeater {
                model: ["menu", "popover", "window"]
                Item {
                    required property string modelData
                    width: 180; height: 84
                    Shadow { target: plate; radius: Theme.radiusLg; elevation: modelData }
                    Rectangle {
                        id: plate
                        anchors.fill: parent
                        radius: Theme.radiusLg
                        color: Theme.surface
                        Text { anchors.centerIn: parent; text: modelData; font: Theme.typeBodyStrong; color: Theme.text }
                    }
                }
            }
        }

        // Skeleton rows
        Label { x: 40; y: 334; text: "Skeleton" }
        Card {
            x: 40; y: 356
            width: 300
            Column {
                width: parent.width
                spacing: Theme.space16
                Repeater {
                    model: 3
                    Row {
                        spacing: Theme.space12
                        Skeleton { width: 36; height: 36; radius: 18 }
                        Column {
                            spacing: Theme.space8
                            anchors.verticalCenter: parent.verticalCenter
                            Skeleton { width: 180; height: 12 }
                            Skeleton { width: 120; height: 10 }
                        }
                    }
                }
            }
        }

        // EmptyState
        Label { x: 372; y: 334; text: "EmptyState" }
        Rectangle {
            x: 372; y: 356
            width: 288; height: 224
            radius: Theme.radiusMd
            color: "transparent"
            border.width: 1
            border.color: Theme.border
            EmptyState {
                anchors.centerIn: parent
                width: parent.width - 2 * Theme.space16
                iconName: "package"
                title: "No bottles yet"
                body: "Windows apps you install get their own bottle."
                actionText: "Install a Windows app"
            }
        }

        // ErrorBanner
        Label { x: 40; y: 594; text: "ErrorBanner" }
        ErrorBanner {
            x: 40; y: 614
            width: 620
            text: "Couldn’t reach the update server. Check your connection and try again."
            actionText: "Try again"
        }

        // Danger dialog with an error
        Item { id: dlgAnchorRight; x: 40; y: 680; width: 448; height: 1 }
        Dialog {
            id: dangerDialog
            parent: demo.modalDemo ? T.Overlay.overlay : dlgAnchorRight
            anchors.centerIn: demo.modalDemo ? parent : undefined
            x: 0; y: 0
            modal: demo.modalDemo
            dim: demo.modalDemo
            title: "Delete “Photoshop CS6” bottle?"
            text: "The bottle and every app in it are removed."
            primaryText: "Delete"
            danger: true
            errorText: "The bottle is still running. Quit its apps first."
        }
    }

    Timer {
        interval: 50
        running: true
        onTriggered: { glassPop.open(); plainDialog.open(); dangerDialog.open(); focusTimer.start() }
    }
    // after the popups took focus, show the card's keyboard focus ring
    Timer { id: focusTimer; interval: 400 }
}

// lugh-hello: one window, one Rust-backed QObject. Colors and type follow
// docs/DESIGN-SYSTEM.md (light theme, Amber accent).
import QtQuick
import QtQuick.Window
import QtQuick.Templates as T
import os.lugh.hello

Window {
    id: root

    // DESIGN-SYSTEM §2 (light) tokens used here.
    readonly property color colorBg: "#F7F6F3"
    readonly property color colorText: "#1C1B19"
    readonly property color colorTextMuted: "#5F5B54"
    readonly property color colorAccent: "#E8962E"
    readonly property color colorOnAccent: "#1C1B19"
    readonly property string fontUi: "Inter"

    // True after a key press, false after a pointer press: the focus ring shows
    // for keyboard users only. `visualFocus` alone is not enough here, because
    // with a single focusable item Tab never re-focuses it with TabFocusReason.
    property bool keyboardMode: false

    width: 480
    height: 300
    minimumWidth: 360
    minimumHeight: 240
    visible: true
    title: qsTr("Lugh — Hello")
    color: root.colorBg

    Greeter {
        id: greeter
    }

    // Passive: sees every pointer press, even ones the button grabs.
    PointHandler {
        target: null
        onActiveChanged: if (active) root.keyboardMode = false
    }

    Column {
        anchors.fill: parent
        anchors.margins: 32
        spacing: 12

        Text {
            text: qsTr("Phase 0 · toolchain check")
            color: root.colorTextMuted
            font.family: root.fontUi
            font.pixelSize: 12   // caption 12 / 450
            font.weight: 450
        }

        Text {
            text: qsTr("Hello, Lugh")
            color: root.colorText
            font.family: root.fontUi
            font.pixelSize: 26   // title-1 26 / 600
            font.weight: Font.DemiBold
            lineHeight: 1.2
        }

        Text {
            width: parent.width
            text: greeter.greeting
            color: root.colorText
            font.family: root.fontUi
            font.pixelSize: 14   // body 14 / 400
            font.weight: Font.Normal
            lineHeight: 1.45
            wrapMode: Text.Wrap
        }

        Item {
            width: 1
            height: 8
        }

        T.Button {
            id: greetButton

            focus: true
            implicitWidth: label.implicitWidth + 32
            implicitHeight: 36   // ≥ 32 px hit target
            text: qsTr("Say hello")
            onClicked: greeter.greet()
            Keys.onPressed: event => {
                root.keyboardMode = true;
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    greeter.greet();
                    event.accepted = true;
                }
            }

            scale: greetButton.down ? 0.98 : 1.0
            Behavior on scale {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }

            contentItem: Text {
                id: label
                text: greetButton.text
                color: root.colorOnAccent
                font.family: root.fontUi
                font.pixelSize: 14   // body-strong 14 / 550
                font.weight: 550
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            background: Rectangle {
                radius: 6
                color: greetButton.down ? Qt.darker(root.colorAccent, 1.12)
                     : greetButton.hovered ? Qt.darker(root.colorAccent, 1.06)
                     : root.colorAccent
                Behavior on color {
                    ColorAnimation {
                        duration: 120
                    }
                }

                // Keyboard focus: 2 px accent ring with a 2 px offset (DESIGN-SYSTEM §7).
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -4
                    radius: 10
                    color: "transparent"
                    border.width: 2
                    border.color: root.colorAccent
                    visible: greetButton.activeFocus && root.keyboardMode
                }
            }
        }

        Text {
            text: greeter.count === 0 ? qsTr("Not greeted yet.")
                : greeter.count === 1 ? qsTr("Greeted once.")
                : qsTr("Greeted %1 times.").arg(greeter.count)
            color: root.colorTextMuted
            font.family: root.fontUi
            font.pixelSize: 12
            font.weight: 450
            font.features: { "tnum": 1 }
        }
    }
}

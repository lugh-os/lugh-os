// Control center › sound drawer: output chips, one slider per app that is
// playing, and the microphone (slider, mute on its icon, input chips when
// there is a choice). Content is created on first expand.
import QtQuick
import Lugh.UI
import Lugh.Shell
import "icons.js" as Icons

Drawer {
    id: drawer

    property var cc
    readonly property var audio: Services.audio

    expanded: cc.drawer === "sound"

    function focusFirst(viaKeyboard) { if (loader.item) loader.item.focusFirst(viaKeyboard); }

    component Heading: Text {
        x: 4
        height: 20
        verticalAlignment: Text.AlignVCenter
        font: Theme.typeCaption
        color: Theme.textMuted
    }

    Loader {
        id: loader
        width: parent.width
        active: drawer.loaded
        sourceComponent: DrawerWell {
            topGap: Theme.space4

            function focusFirst(viaKeyboard) {
                const reason = viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason;
                for (let i = 0; i < outs.count; ++i) {
                    const c = outs.itemAt(i);
                    if (c && (c.selected || i === outs.count - 1)) { c.forceActiveFocus(reason); return; }
                }
                mic.forceActiveFocus(reason);
            }

            Column {
                x: 2
                width: parent.width - 4
                spacing: Theme.space4

                Heading { visible: outs.count > 0; text: qsTr("Output") }
                Flow {
                    id: outFlow
                    visible: outs.count > 0
                    width: parent.width
                    spacing: 6

                    Repeater {
                        id: outs
                        model: drawer.audio.outputs
                        Chip {
                            required property var model
                            width: Math.min(implicitWidth, outFlow.width)
                            text: model.name
                            iconName: model.icon
                            selected: model.active
                            onClicked: drawer.audio.setOutput(model.devId)
                        }
                    }
                }

                Heading { visible: apps.count > 0; text: qsTr("Apps") }
                Column {
                    visible: apps.count > 0
                    width: parent.width

                    Repeater {
                        id: apps
                        model: drawer.audio.streams
                        Item {
                            id: s
                            required property int streamId
                            required property var model
                            readonly property string name: model.name !== "" ? model.name : qsTr("App")
                            readonly property string icon: model.icon
                            required property real volume
                            required property bool muted

                            width: parent.width
                            height: 32

                            AppIcon {
                                x: 4
                                anchors.verticalCenter: parent.verticalCenter
                                size: 20
                                iconName: s.icon
                                fallbackText: s.name
                                opacity: s.muted ? Theme.disabledOpacity : 1
                            }
                            Text {
                                x: 32
                                width: 72
                                anchors.verticalCenter: parent.verticalCenter
                                text: s.name
                                font: Theme.typeLabel
                                color: Theme.text
                                elide: Text.ElideRight
                            }
                            LevelSlider {
                                anchors.left: parent.left
                                anchors.leftMargin: 112
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                level: s.volume
                                iconName: Icons.volume(s.volume, s.muted)
                                iconTooltip: s.muted ? qsTr("Unmute %1").arg(s.name) : qsTr("Mute %1").arg(s.name)
                                Accessible.name: qsTr("%1 volume").arg(s.name)
                                onMoved: drawer.audio.setStreamVolume(s.streamId, value)
                                onIconClicked: drawer.audio.setStreamMuted(s.streamId, !s.muted)
                                Keys.onPressed: event => {
                                    if (event.key === Qt.Key_M) {
                                        drawer.audio.setStreamMuted(s.streamId, !s.muted);
                                        event.accepted = true;
                                    }
                                }
                            }
                        }
                    }
                }

                Heading { text: qsTr("Input") }
                LevelSlider {
                    id: mic
                    width: parent.width
                    level: drawer.audio.micVolume
                    iconName: drawer.audio.micMuted ? "mic-off" : "mic"
                    iconTooltip: drawer.audio.micMuted ? qsTr("Unmute microphone") : qsTr("Mute microphone")
                    Accessible.name: qsTr("Microphone volume")
                    onMoved: drawer.audio.setMicVolume(value)
                    onIconClicked: drawer.audio.setMicMuted(!drawer.audio.micMuted)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_M) {
                            drawer.audio.setMicMuted(!drawer.audio.micMuted);
                            event.accepted = true;
                        }
                    }
                }
                Flow {
                    id: inFlow
                    visible: ins.count > 1
                    width: parent.width
                    spacing: 6

                    Repeater {
                        id: ins
                        model: drawer.audio.inputs
                        Chip {
                            required property var model
                            width: Math.min(implicitWidth, inFlow.width)
                            text: model.name
                            iconName: model.icon
                            selected: model.active
                            onClicked: drawer.audio.setInput(model.devId)
                        }
                    }
                }
            }
        }
    }
}

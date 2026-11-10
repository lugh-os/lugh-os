// Control center › Sound: volume, output device picker, microphone mute.
import QtQuick
import QtQuick.Layouts
import Lugh.UI
import Lugh.Shell
import "icons.js" as Icons

FocusScope {
    id: page

    property Item cc
    property real maxHeight: 640

    readonly property QtObject audio: Services.audio

    implicitWidth: 336
    implicitHeight: col.implicitHeight

    function focusFirst(viaKeyboard) {
        const r = viaKeyboard ? Qt.TabFocusReason : Qt.OtherFocusReason;
        if (list.count > 0) {
            for (let i = 0; i < audio.outputs.count; ++i) if (audio.outputs.get(i).active) list.currentIndex = i;
            list.forceActiveFocus(r);
        } else {
            header.backButton.forceActiveFocus(r);
        }
    }
    function activate(index) {
        const o = audio.outputs.get(index);
        if (!o) return;
        list.currentIndex = index;
        audio.setOutput(o.devId);
    }

    ColumnLayout {
        id: col
        width: parent.width
        spacing: Theme.space8

        PageHeader {
            id: header
            Layout.fillWidth: true
            title: qsTr("Sound")
            onBackRequested: page.cc.back()
        }

        Slider {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space4
            Layout.rightMargin: Theme.space4
            iconName: Icons.volume(page.audio.volume, page.audio.muted)
            iconTooltip: page.audio.muted ? qsTr("Unmute") : qsTr("Mute")
            showValue: true
            value: page.audio.volume
            onMoved: page.audio.setVolume(value)
            onIconClicked: page.audio.setMuted(!page.audio.muted)
            Accessible.name: page.audio.muted ? qsTr("Volume, muted") : qsTr("Volume")
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.topMargin: Theme.space8
            text: qsTr("Output")
            font: Theme.typeCaption
            color: Theme.textMuted
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Text {
            visible: list.count === 0
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            text: qsTr("No output devices found.")
            font: Theme.typeBody
            color: Theme.textMuted
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, Math.max(120, page.maxHeight - 200))
            interactive: contentHeight > height
            clip: interactive
            boundsBehavior: Flickable.StopAtBounds
            activeFocusOnTab: true
            keyNavigationEnabled: true
            model: page.audio.outputs
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Output devices")

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    page.activate(currentIndex);
                    event.accepted = true;
                }
            }

            delegate: ListRow {
                required property int index
                required property string devId
                required property string name
                required property var model   // "icon" clashes with AbstractButton.icon
                required property bool active

                width: ListView.view.width
                focusPolicy: Qt.NoFocus
                title: name
                iconName: model.icon !== "" ? model.icon : "speaker"
                selected: active
                onClicked: page.activate(index)
                Accessible.name: active ? qsTr("%1, in use").arg(name) : name
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space4
            implicitHeight: 1
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.10)
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space8
            spacing: Theme.space12

            Icon {
                name: page.audio.micMuted ? "mic-off" : "mic"
                size: 20
                color: Theme.textMuted
            }
            Toggle {
                Layout.fillWidth: true
                text: qsTr("Microphone")
                checked: !page.audio.micMuted
                onToggled: page.audio.setMicMuted(!checked)
                Accessible.name: page.audio.micMuted ? qsTr("Microphone, muted") : qsTr("Microphone, on")
            }
        }
    }
}

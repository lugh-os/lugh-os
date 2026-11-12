// Customize → Motion: reduce motion and the speed of every animation.
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI
import Lugh.Shell

CustomizePage {
    id: page
    key: "motion"
    pageTitle: qsTr("Motion")
    iconName: "zap"

    SettingGroup {
        title: qsTr("Animation")

        ToggleRow {
            title: qsTr("Reduce motion")
            description: qsTr("Replace sliding, zooming and springs with short fades")
            keywords: "reduce motion animation accessibility vestibular fade"
            checked: ShellSettings.reduceMotion
            onEdited: v => ShellSettings.reduceMotion = v
        }

        SettingRow {
            id: speedRow
            title: qsTr("Animation speed")
            description: ShellSettings.reduceMotion ? qsTr("Fades stay short while reduce motion is on")
                                                    : qsTr("How quickly panels open, morph and settle")
            keywords: "animation speed duration fast slow snappy relaxed"
            stacked: true
            enabled: !ShellSettings.reduceMotion

            readonly property real v: ShellSettings.animationScale
            readonly property int tier: v < 0.875 ? 0 : v <= 1.125 ? 1 : 2

            ColumnLayout {
                spacing: Theme.space4
                Layout.fillWidth: true

                RowLayout {
                    spacing: Theme.space12
                    Layout.fillWidth: true
                    Slider {
                        id: sl
                        compact: true
                        from: 0.5; to: 1.5; stepSize: 0.25
                        snapMode: T.Slider.SnapAlways
                        value: speedRow.v
                        Layout.fillWidth: true
                        accessibleName: speedRow.title
                        Accessible.description: [qsTr("Snappy"), qsTr("Default"), qsTr("Relaxed")][speedRow.tier]
                                                + ", " + speedRow.v.toFixed(2) + "×"
                        onMoved: {
                            ShellSettings.animationScale = value;
                            value = Qt.binding(() => speedRow.v);
                        }
                    }
                    Text {
                        text: speedRow.v.toFixed(2) + "×"
                        font: Theme.typeCaptionTnum
                        color: Theme.textMuted
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: 44
                    }
                }
                Item {
                    Layout.fillWidth: true
                    Layout.rightMargin: 44 + Theme.space12
                    implicitHeight: 18
                    Repeater {
                        model: [qsTr("Snappy"), qsTr("Default"), qsTr("Relaxed")]
                        Text {
                            required property string modelData
                            required property int index
                            x: index === 0 ? 0 : index === 1 ? (parent.width - width) / 2 : parent.width - width
                            text: modelData
                            font: index === speedRow.tier ? Theme.typeLabel : Theme.typeCaption
                            color: index === speedRow.tier ? Theme.text : Theme.textMuted
                        }
                    }
                }
            }
        }

        SettingRow {
            title: qsTr("Try it")
            description: qsTr("Plays a panel-sized move at the chosen speed")
            keywords: "test preview animation speed demo"

            Rectangle {
                id: track
                implicitWidth: 160
                implicitHeight: 32
                radius: 16
                color: Theme.hoverOverlay
                border.width: 1
                border.color: Theme.glassBorder
                Accessible.ignored: true
                property bool atEnd: false
                Rectangle {
                    id: puck
                    width: 24; height: 24; radius: 12
                    y: 4
                    x: track.atEnd ? track.width - width - 4 : 4
                    color: Theme.accent
                    Behavior on x {
                        enabled: !ShellSettings.reduceMotion
                        NumberAnimation {
                            duration: Theme.durLarge * ShellSettings.animationScale
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Theme.easeStandard
                        }
                    }
                }
            }
            Button {
                text: qsTr("Play")
                iconName: "play"
                size: "sm"
                onClicked: track.atEnd = !track.atEnd
            }
        }
    }
}

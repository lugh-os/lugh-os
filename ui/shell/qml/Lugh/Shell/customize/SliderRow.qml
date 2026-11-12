// A SettingRow with a compact Slider and its value as text.
//
//   SliderRow { title: qsTr("Height"); from: 40; to: 64; stepSize: 2
//               value: ShellSettings.panelHeight; valueText: value + " px"
//               onEdited: v => ShellSettings.panelHeight = v }
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI

SettingRow {
    id: r

    property real value: 0
    property real from: 0
    property real to: 1
    property real stepSize: 1
    property string valueText: ""
    property int sliderWidth: 200
    signal edited(real value)

    Slider {
        id: sl
        compact: true
        from: r.from
        to: r.to
        stepSize: r.stepSize
        snapMode: T.Slider.SnapAlways
        value: r.value
        Layout.preferredWidth: r.sliderWidth
        Layout.fillWidth: r._stack
        accessibleName: r.title
        Accessible.description: r.valueText
        onMoved: {
            r.edited(value);
            value = Qt.binding(() => r.value);
        }
    }
    Text {
        text: r.valueText
        font: Theme.typeCaptionTnum
        color: Theme.textMuted
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: 52
        Accessible.ignored: true
    }
}

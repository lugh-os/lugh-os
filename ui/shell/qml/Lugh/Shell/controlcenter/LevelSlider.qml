// Compact slider bound to a service level: follows `level` unless the user is
// dragging (a user move replaces a plain `value:` binding).
//
//   LevelSlider { level: audio.volume; onMoved: audio.setVolume(value) }
import QtQuick
import Lugh.UI

Slider {
    id: control

    property real level: 0

    compact: true
    value: level
    onLevelChanged: if (!pressed) value = level
}

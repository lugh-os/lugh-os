// Symbolic icon from the vendored Lucide font (DESIGN-SYSTEM §6).
//
//   Icon { name: "wifi"; size: 20; color: Theme.textMuted }
//
// A font glyph: crisp at any size, recolored for free, no textures. Unknown
// names render nothing and warn once. Decorative by default
// (Accessible.ignored); the parent control carries the accessible name.
import QtQuick

Text {
    id: root

    property string name: ""
    property int size: 20

    width: size
    height: size
    color: Theme.text
    text: {
        const g = IconNames.glyph(name);
        if (g === "" && name !== "")
            IconNames.warnUnknown(name);
        return g;
    }
    font.family: IconNames.fontFamily
    font.pixelSize: size
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    renderType: Text.QtRendering
    textFormat: Text.PlainText
    Accessible.ignored: true
}

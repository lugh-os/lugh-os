// Preview-only: the simulated compositor blur under a surface's glass panel
// (`panel`, e.g. Launcher.panelItem). Follows the panel's on-screen rect
// (including its open/close scale and slide) and its effective opacity.
// Tracking is per frame, but only while the panel is visible, and only in the
// preview (production never loads this file).
import QtQuick
import Lugh.UI

GlassBackdrop {
    id: root
    // The glass panel to sit under. `relativeTo` is this item's parent's
    // coordinate space (the preview's desk, at scene 0,0).
    property Item panel: null
    property Item relativeTo: parent

    readonly property bool _live: panel !== null && panel.visible && _opacityOf(panel) > 0

    visible: _live && width > 0 && height > 0
    radius: panel && panel.radius !== undefined ? panel.radius : Theme.radiusXl

    function _opacityOf(item) {
        let o = 1;
        for (let it = item; it && it !== relativeTo; it = it.parent) {
            if (!it.visible) return 0;
            o *= it.opacity;
        }
        return o;
    }
    function _sync() {
        if (!panel || !relativeTo) return;
        const r = panel.mapToItem(relativeTo, Qt.rect(0, 0, panel.width, panel.height));
        x = r.x; y = r.y; width = r.width; height = r.height;
        // Scaled panels scale their corners too.
        opacity = _opacityOf(panel);
    }
    onPanelChanged: _sync()

    FrameAnimation {
        running: root.panel !== null && root.panel.visible
        onTriggered: root._sync()
    }
}

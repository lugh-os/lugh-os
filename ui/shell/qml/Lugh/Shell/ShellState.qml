// Shell-wide UI state: which overlay is open. One overlay at a time; opening
// one closes the others. Surfaces bind to these flags and animate themselves;
// the frame (main.qml / preview.qml) maps/unmaps layer windows from the
// surfaces' `shown` property.
pragma Singleton
import QtQuick

QtObject {
    id: state

    property bool launcherOpen: false
    property bool controlCenterOpen: false
    property bool notificationCenterOpen: false
    property bool lughMenuOpen: false
    // "lugh" only in Phase 1; Classic/Focus arrive in Phase 2.
    property string mode: "lugh"
    // Sub-page the control center opens on ("" = main): "wifi" | "bluetooth" | "sound" | "power".
    property string controlCenterPage: ""

    // Island geometry in screen coordinates, published by the Bar so overlays
    // can morph out of the island that opened them (docs/design/lugh-mode.md).
    property rect logoIsland: Qt.rect(10, 8, 120, 36)
    property rect centerIsland: Qt.rect(0, 8, 160, 36)
    property rect statusIsland: Qt.rect(0, 8, 140, 36)

    readonly property bool anyOverlayOpen: launcherOpen || controlCenterOpen
                                           || notificationCenterOpen || lughMenuOpen

    function closeAll() {
        launcherOpen = false;
        controlCenterOpen = false;
        notificationCenterOpen = false;
        lughMenuOpen = false;
    }
    function openLauncher() { closeAll(); launcherOpen = true; }
    function toggleLauncher() { const o = !launcherOpen; closeAll(); launcherOpen = o; }
    function toggleControlCenter() { const o = !controlCenterOpen; closeAll(); controlCenterPage = ""; controlCenterOpen = o; }
    function openControlCenter(page) { closeAll(); controlCenterPage = page || ""; controlCenterOpen = true; }
    function toggleNotificationCenter() { const o = !notificationCenterOpen; closeAll(); notificationCenterOpen = o; }
    function toggleLughMenu() { const o = !lughMenuOpen; closeAll(); lughMenuOpen = o; }
}

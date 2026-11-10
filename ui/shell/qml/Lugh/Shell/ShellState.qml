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
    function toggleControlCenter() { const o = !controlCenterOpen; closeAll(); controlCenterOpen = o; }
    function toggleNotificationCenter() { const o = !notificationCenterOpen; closeAll(); notificationCenterOpen = o; }
    function toggleLughMenu() { const o = !lughMenuOpen; closeAll(); lughMenuOpen = o; }
}

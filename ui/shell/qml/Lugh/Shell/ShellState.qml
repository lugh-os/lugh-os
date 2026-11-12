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
    // Workspace overview (Super+Tab): grid of workspaces, KDE-style.
    property bool overviewOpen: false
    // Customize panel (advanced shell settings, edits ShellSettings).
    property bool customizeOpen: false
    // Section the Customize panel opens on ("" = first):
    // "appearance" | "panel" | "clock" | "quick" | "workspaces" | "windows" | "motion"
    property string customizePage: ""
    // "lugh" only in Phase 1; Classic/Focus arrive in Phase 2.
    property string mode: "lugh"
    // Sub-page the control center opens on ("" = main): "wifi" | "bluetooth" | "sound" | "power".
    property string controlCenterPage: ""
    // The launcher was opened from the panel (it grows out of logoIsland)
    // rather than by keyboard / D-Bus (it grows from its own center).
    property bool launcherFromPanel: false

    // Geometry in screen coordinates, published by the bottom Panel so
    // overlays can morph out of (and sit just above) what opened them.
    //   logoIsland    the start (Lugh logo) button
    //   centerIsland  the clock in the tray
    //   statusIsland  the whole tray (status icons + clock)
    //   panelRect     the visible panel pill/strip
    // `panelReserved` = px the panel takes at the bottom when shown (also
    // with autohide, since overlays reveal it); overlays keep their bottom
    // edge above it.
    property rect logoIsland: Qt.rect(10, 1032, 40, 40)
    property rect centerIsland: Qt.rect(1780, 1032, 120, 40)
    property rect statusIsland: Qt.rect(1700, 1032, 210, 40)
    property rect panelRect: Qt.rect(0, 1024, 1920, 56)
    property int panelReserved: 60

    // Super+B (space.lugh.Shell1.FocusPanel): the panel on the active output
    // takes the keyboard and focuses its first item.
    signal focusPanelRequested()
    function focusPanel() { closeAll(); focusPanelRequested(); }

    readonly property bool anyOverlayOpen: launcherOpen || controlCenterOpen
                                           || notificationCenterOpen || lughMenuOpen
                                           || overviewOpen || customizeOpen

    function closeAll() {
        launcherOpen = false;
        controlCenterOpen = false;
        notificationCenterOpen = false;
        lughMenuOpen = false;
        overviewOpen = false;
        customizeOpen = false;
    }
    function openLauncher() { closeAll(); launcherFromPanel = false; launcherOpen = true; }
    function toggleLauncher(fromPanel) {
        const o = !launcherOpen;
        closeAll();
        launcherFromPanel = fromPanel === true;
        launcherOpen = o;
    }
    function toggleControlCenter() { const o = !controlCenterOpen; closeAll(); controlCenterPage = ""; controlCenterOpen = o; }
    function openControlCenter(page) { closeAll(); controlCenterPage = page || ""; controlCenterOpen = true; }
    function toggleNotificationCenter() { const o = !notificationCenterOpen; closeAll(); notificationCenterOpen = o; }
    function toggleLughMenu() { const o = !lughMenuOpen; closeAll(); lughMenuOpen = o; }
    function toggleOverview() { const o = !overviewOpen; closeAll(); overviewOpen = o; }
    function openOverview() { closeAll(); overviewOpen = true; }
    function openCustomize(page) { closeAll(); customizePage = page || ""; customizeOpen = true; }
    function toggleCustomize() { const o = !customizeOpen; closeAll(); customizePage = ""; customizeOpen = o; }
}

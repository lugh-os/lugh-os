// User customization of the shell, persisted across sessions (QtCore
// Settings → ~/.config/lugh/lugh-shell.conf, category "shell"). The
// Customize panel edits these; every surface binds to them. Changing a
// value applies live — no restart.
//
// Appearance values (dark, accent, transparency, reduceMotion,
// animationScale) are mirrored into Theme by the frame (main.qml) at start
// and on change.
pragma Singleton
import QtQuick
import QtCore

QtObject {
    id: s

    // ---- appearance -----------------------------------------------------------
    property bool dark: false
    property string accent: "amber"            // Theme.accentNames: amber teal green blue red graphite
    property bool transparency: true
    property bool reduceMotion: false
    property real animationScale: 1.0          // 0.5 (snappy) … 1.5 (relaxed); Theme.dur multiplies by it
    property int cornerRadius: 14              // shell panels and windows, 8 … 22

    // ---- panel (the bottom taskbar) ------------------------------------------
    property int panelHeight: 48               // 40 … 64
    property int panelIconSize: 32             // 24 … 44 (app icons in the panel)
    property bool panelFloating: true          // floating pill with a margin vs. edge-to-edge strip
    property bool panelAutohide: false
    property string panelAlignment: "center"   // "center" | "left": where the app list sits
    property bool panelShowStart: true         // Lugh logo button (→ Lugh menu / launcher)
    property bool panelShowWorkspaces: true    // workspace grid indicator
    property bool panelShowSearch: false       // search button next to the start button
    property bool panelMagnify: false          // dock-style magnify on hover
    property bool panelShowRunningIndicator: true

    // ---- clock & tray ---------------------------------------------------------
    property bool clock24h: true
    property bool clockShowSeconds: false
    property bool clockShowDate: true
    property string clockDateFormat: "ddd d MMM" // Qt.formatDate format
    property bool trayShowNetwork: true
    property bool trayShowBluetooth: true
    property bool trayShowVolume: true
    property bool trayShowBattery: true
    property bool trayShowKeyboard: false
    property bool trayShowMedia: true
    property bool showBatteryPercent: false

    // ---- quick panel (clock + calendar + controls, opened from the tray) -------
    // Order and selection of the toggle tiles. Known ids:
    // "wifi" "bluetooth" "dnd" "nightlight" "airplane" "powerprofile" "darkmode" "caffeine"
    property var quickToggles: ["wifi", "bluetooth", "dnd", "nightlight", "darkmode", "powerprofile"]
    property bool quickShowCalendar: true
    property bool quickShowMedia: true
    property bool quickShowSliders: true
    property bool quickShowNotifications: true
    property bool quickCalendarFolded: false   // calendar folded to the current week

    // ---- workspaces -------------------------------------------------------------
    property int workspaceRows: 2              // 1 … 4
    property int workspaceCols: 2              // 1 … 4
    readonly property int workspaceCount: workspaceRows * workspaceCols
    property bool overviewShowEmpty: true      // show empty workspaces in the overview grid
    property bool workspaceWrap: false         // grid navigation wraps at the edges

    // ---- windows ------------------------------------------------------------------
    property string titlebarButtons: "minimize,maximize,close" // order, right side
    property bool titlebarCompact: true
    // The appearance service reads titlebarButtons from the config file and
    // writes it to org.gnome.desktop.wm.preferences button-layout on reload:
    // flush the file first, then ask it to reload.
    onTitlebarButtonsChanged: Qt.callLater(_applyTitlebar)
    function _applyTitlebar() {
        _store.sync();
        Services.appearance.reload();
    }

    function reset() {
        dark = false; accent = "amber"; transparency = true; reduceMotion = false;
        animationScale = 1.0; cornerRadius = 14;
        panelHeight = 48; panelIconSize = 32; panelFloating = true; panelAutohide = false;
        panelAlignment = "center"; panelShowStart = true; panelShowWorkspaces = true;
        panelShowSearch = false; panelMagnify = false; panelShowRunningIndicator = true;
        clock24h = true; clockShowSeconds = false; clockShowDate = true; clockDateFormat = "ddd d MMM";
        trayShowNetwork = true; trayShowBluetooth = true; trayShowVolume = true; trayShowBattery = true;
        trayShowKeyboard = false; trayShowMedia = true; showBatteryPercent = false;
        quickToggles = ["wifi", "bluetooth", "dnd", "nightlight", "darkmode", "powerprofile"];
        quickShowCalendar = true; quickShowMedia = true; quickShowSliders = true; quickShowNotifications = true; quickCalendarFolded = false;
        workspaceRows = 2; workspaceCols = 2; overviewShowEmpty = true; workspaceWrap = false;
        titlebarButtons = "minimize,maximize,close"; titlebarCompact = true;
    }

    readonly property Settings _store: Settings {
        location: StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/lugh/lugh-shell.conf"
        category: "shell"
        property alias dark: s.dark
        property alias accent: s.accent
        property alias transparency: s.transparency
        property alias reduceMotion: s.reduceMotion
        property alias animationScale: s.animationScale
        property alias cornerRadius: s.cornerRadius
        property alias panelHeight: s.panelHeight
        property alias panelIconSize: s.panelIconSize
        property alias panelFloating: s.panelFloating
        property alias panelAutohide: s.panelAutohide
        property alias panelAlignment: s.panelAlignment
        property alias panelShowStart: s.panelShowStart
        property alias panelShowWorkspaces: s.panelShowWorkspaces
        property alias panelShowSearch: s.panelShowSearch
        property alias panelMagnify: s.panelMagnify
        property alias panelShowRunningIndicator: s.panelShowRunningIndicator
        property alias clock24h: s.clock24h
        property alias clockShowSeconds: s.clockShowSeconds
        property alias clockShowDate: s.clockShowDate
        property alias clockDateFormat: s.clockDateFormat
        property alias trayShowNetwork: s.trayShowNetwork
        property alias trayShowBluetooth: s.trayShowBluetooth
        property alias trayShowVolume: s.trayShowVolume
        property alias trayShowBattery: s.trayShowBattery
        property alias trayShowKeyboard: s.trayShowKeyboard
        property alias trayShowMedia: s.trayShowMedia
        property alias showBatteryPercent: s.showBatteryPercent
        property alias quickToggles: s.quickToggles
        property alias quickShowCalendar: s.quickShowCalendar
        property alias quickShowMedia: s.quickShowMedia
        property alias quickShowSliders: s.quickShowSliders
        property alias quickShowNotifications: s.quickShowNotifications
        property alias quickCalendarFolded: s.quickCalendarFolded
        property alias workspaceRows: s.workspaceRows
        property alias workspaceCols: s.workspaceCols
        property alias overviewShowEmpty: s.overviewShowEmpty
        property alias workspaceWrap: s.workspaceWrap
        property alias titlebarButtons: s.titlebarButtons
        property alias titlebarCompact: s.titlebarCompact
    }
}

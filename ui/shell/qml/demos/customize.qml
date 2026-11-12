// Customize demo: the wallpaper and the Customize panel open on a section
// (Panel by default).
//
//   QT_QPA_PLATFORM=offscreen scripts/qml-shot.sh ui/shell/qml/demos/customize.qml \
//       /tmp/lugh-shots/customize/panel-light.png 1440 900 900
//
// Args:
//   --dark, --accent <name>, --reduce-motion
//   --page <key>      appearance | panel | clock | quick | workspaces | windows | motion
//   --query <text>    type a search into the field after opening
//   --confirm         show the reset confirmation in the footer
// Theme follows ShellSettings changes made in the panel (as main.qml does);
// the flags only set the starting look, so the demo never writes the user's
// ~/.config/lugh/lugh-shell.conf unless you click something.
import QtQuick
import Lugh.UI
import Lugh.Shell

Item {
    id: demo
    implicitWidth: 1440
    implicitHeight: 900

    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.lastIndexOf(name);    // ours come after qml-shot's own --out/--delay
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    function flag(name) { return args.indexOf(name) >= 0; }

    property bool configured: false
    Component.onCompleted: {
        Theme.dark = flag("--dark");
        Theme.accentName = arg("--accent", ShellSettings.accent);
        Theme.reduceMotion = flag("--reduce-motion");
        Theme.transparency = ShellSettings.transparency;
        // the repo's art: lugh-branding is not installed in the dev tree
        Services.appearance.wallpaperDir = Qt.resolvedUrl("../../../../branding/wallpapers/");
        configured = true;
        start.start();
    }
    Connections {
        target: ShellSettings
        function onDarkChanged() { Theme.dark = ShellSettings.dark; }
        function onAccentChanged() { Theme.accentName = ShellSettings.accent; }
        function onTransparencyChanged() { Theme.transparency = ShellSettings.transparency; }
        function onReduceMotionChanged() { Theme.reduceMotion = ShellSettings.reduceMotion; }
    }

    Timer {
        id: start
        interval: 1
        onTriggered: {
            ShellState.openCustomize(demo.arg("--page", "panel"));
            customize.forceActiveFocus();
            after.start();
        }
    }
    Timer {
        id: after
        interval: 300
        onTriggered: {
            const q = demo.arg("--query", "");
            if (q !== "") customize.item.query = q;
            if (demo.flag("--confirm")) demo.findReset(customize.item);
        }
    }
    // Clicks the footer's reset button (it has the rotate-ccw icon and is visible).
    function findReset(it) {
        for (let i = 0; i < it.children.length; ++i) {
            const c = it.children[i];
            if (c.iconName === "rotate-ccw" && c.clicked !== undefined && c.visible) { c.clicked(); return true; }
            if (findReset(c)) return true;
        }
        return false;
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    // The repo's art (the demo runs without lugh-branding installed).
    Loader {
        anchors.fill: parent
        active: demo.configured
        sourceComponent: Wallpaper { blurred: true; _useRepo: true }
        onLoaded: Theme.backdrop = item
    }
    Loader {
        anchors.fill: parent
        active: demo.configured
        sourceComponent: Wallpaper { _useRepo: true }
    }

    // Created once the wallpaper dir is set (its thumbnails load from it).
    Loader {
        id: customize
        anchors.fill: parent
        active: demo.configured
        focus: true
        sourceComponent: Customize {
            visible: shown
            focus: true
        }
    }
}

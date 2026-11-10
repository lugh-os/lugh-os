// LughUI liquid components demo (docs/design/lugh-mode.md): Squish, Island,
// MorphPanel, IconToggle, Chip, Drawer and the compact Slider in every state.
//
//   scripts/qml-shot.sh ui/components/demos/liquid.qml out.png 1400 900 [900] [-- --dark]
//
// --dark            dark theme
// --accent NAME     amber | teal | green | blue | red | graphite
// --reduce-motion   reduce motion
// --focus NAME      keyboard focus on: toggle (default) | island | chip
// --motion KIND     motion capture: morph | morph-close | morph-reverse |
//                   morph-grow | drawer | drawer-close | island | toggle.
//                   Triggers the animation and grabs the stage every ~33 ms
//                   for ~0.75 s into <out-dir>/<kind>-NN.png, logs the animated
//                   value per frame, then quits.
// --out-dir DIR     where motion frames go (default /tmp/lugh-shots/liquid)
import QtQuick
import QtQuick.Layouts
import Lugh.UI

Rectangle {
    id: page
    color: Theme.bg

    readonly property var args: Qt.application.arguments
    function arg(name, fallback) {
        const i = args.indexOf(name);
        return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }
    readonly property string motion: arg("--motion", "")
    readonly property string outDir: arg("--out-dir", "/tmp/lugh-shots/liquid")

    // demo state
    property bool morphOpen: motion === "" || motion === "morph-close" || motion === "morph-grow"
    property bool drawerOpen: motion === "" || motion === "drawer-close" || motion === "morph-grow"
    property bool wifi: true
    property bool islandWide: false
    property string output: "spk"

    Component.onCompleted: {
        Theme.dark = args.indexOf("--dark") >= 0;
        Theme.accentName = arg("--accent", "amber");
        Theme.reduceMotion = args.indexOf("--reduce-motion") >= 0;
        if (motion === "") {
            const f = { island: focusIsland, chip: focusChip }[arg("--focus", "")] || focusToggle;
            f.forceActiveFocus(Qt.TabFocusReason);
        }
    }

    component Caption: Text {
        font: Theme.typeCaption
        color: Theme.textMuted
    }
    component SectionTitle: Text {
        font: Theme.typeTitle3
        color: Theme.text
    }

    // ---- warm busy backdrop on the right half (to judge glass) -------------
    Item {
        id: backdrop
        x: parent.width / 2
        width: parent.width / 2
        height: parent.height
        clip: true

        Rectangle { anchors.fill: parent; color: Theme.warningFill; opacity: 0.55 }
        Repeater {
            model: 14
            Rectangle {
                required property int index
                x: (index * 137) % (backdrop.width - 60) - 40
                y: (index * 211) % (backdrop.height - 60) - 40
                width: 120 + (index * 53) % 180
                height: width * (0.5 + (index % 3) * 0.3)
                radius: index % 2 ? width / 2 : Theme.radiusLg
                rotation: index * 23
                color: [Theme.accent, Theme.danger, Theme.text, Theme.info, Theme.surface][index % 5]
                opacity: 0.75
            }
        }
        Repeater {
            model: 9
            Text {
                required property int index
                x: 30 + (index * 173) % (backdrop.width - 220)
                y: 40 + index * 96
                text: "Umuhanzi w'Ijuru · Kigali Heights"
                font: Theme.typeTitle2
                color: index % 2 ? Theme.bg : Theme.text
            }
        }
    }

    // ---- left: components on a plain background ---------------------------
    ColumnLayout {
        visible: page.motion === ""
        x: Theme.space32
        y: Theme.space24
        width: parent.width / 2 - 2 * Theme.space32
        spacing: Theme.space12

        Text { text: "LughUI · Liquid"; font: Theme.typeTitle1; color: Theme.text }
        Caption {
            text: (Theme.dark ? "Dark" : "Light") + " · " + Theme.accentName
                  + (Theme.reduceMotion ? " · reduce motion" : "")
        }

        SectionTitle { text: "IconToggle" }
        Row {
            spacing: Theme.space16
            Column { spacing: 4; IconToggle { iconName: "bluetooth"; label: "Bluetooth" } Caption { text: "off" } }
            Column { spacing: 4; IconToggle { iconName: "wifi-off"; checkedIconName: "wifi"; label: "Wi-Fi"; checked: true } Caption { text: "on" } }
            Column { spacing: 4; IconToggle { iconName: "wifi-off"; checkedIconName: "wifi"; label: "Wi-Fi"; checked: true; hasDetail: true } Caption { text: "detail" } }
            Column { spacing: 4; IconToggle { iconName: "bluetooth"; label: "Bluetooth"; hasDetail: true } Caption { text: "off+detail" } }
            Column { spacing: 4; IconToggle { iconName: "wifi-off"; label: "Wi-Fi"; busy: true } Caption { text: "busy" } }
            Column { spacing: 4; IconToggle { iconName: "wifi"; label: "Wi-Fi"; checked: true; busy: true } Caption { text: "busy on" } }
            Column { spacing: 4; IconToggle { iconName: "moon"; label: "Night light"; down: true } Caption { text: "pressed" } }
            Column { spacing: 4; IconToggle { id: focusToggle; iconName: "moon"; label: "Night light"; checked: true } Caption { text: "focus" } }
            Column { spacing: 4; IconToggle { iconName: "plane"; label: "Airplane mode"; enabled: false } Caption { text: "disabled" } }
        }
        Row {
            spacing: Theme.space16
            IconToggle { iconName: "bell-off"; label: "Do not disturb"; checked: true; tone: "danger" }
            IconToggle { iconName: "zap"; label: "Power saver"; checked: true; tone: "success" }
            IconToggle { iconName: "monitor"; label: "Cast"; checked: true; tone: "info" }
            IconToggle { iconName: "keyboard"; label: "Keyboard"; checked: true; tone: "neutral" }
            IconToggle { iconName: "sun"; label: "Brightness"; size: 40; checked: true }
            IconToggle { iconName: "sun"; label: "Brightness"; size: 40; hasDetail: true }
            Caption { text: "tones · size 40"; anchors.verticalCenter: parent.verticalCenter }
        }

        SectionTitle { text: "Chip" }
        Row {
            spacing: Theme.space8
            Chip { text: "Speakers"; iconName: "speaker" }
            Chip { text: "Headphones"; iconName: "headphones"; selected: true }
            Chip { text: "Balanced" }
            Chip { text: "Performance"; selected: true }
            Chip { text: "Pressed"; down: true }
            Chip { id: focusChip; text: "HDMI"; iconName: "monitor" }
            Chip { text: "Disabled"; iconName: "usb"; enabled: false }
            Chip { text: "A very long output device name"; width: 130 }
        }

        SectionTitle { text: "Slider · compact" }
        RowLayout {
            spacing: Theme.space16
            Slider { compact: true; iconName: "volume-2"; value: 0.62; showValue: true; Layout.preferredWidth: 260 }
            Slider { compact: true; value: 0.3; Layout.preferredWidth: 140 }
            Slider { compact: true; iconName: "sun"; value: 0.8; enabled: false; Layout.preferredWidth: 140 }
        }
        Slider { iconName: "volume-2"; value: 0.4; showValue: true; Layout.preferredWidth: 300 }

        SectionTitle { text: "Drawer" }
        Rectangle {
            Layout.preferredWidth: 420
            implicitHeight: drawerCol.implicitHeight + 2 * Theme.space12
            radius: Theme.radiusMd
            color: Theme.surface
            border.width: 1
            border.color: Theme.border
            Column {
                id: drawerCol
                x: Theme.space12; y: Theme.space12
                width: parent.width - 2 * Theme.space12
                Text { text: "Expanded drawer ⌄"; font: Theme.typeLabel; color: Theme.text; height: 24 }
                Drawer {
                    width: parent.width
                    expanded: true
                    Column {
                        width: parent.width
                        spacing: Theme.space8
                        Row { spacing: Theme.space8; Chip { text: "Speakers"; selected: true } Chip { text: "HDMI" } }
                        Slider { compact: true; iconName: "mic"; value: 0.5; width: parent.width }
                    }
                }
                Text { text: "Collapsed drawer ›  (nothing below)"; font: Theme.typeLabel; color: Theme.text; height: 24 }
                Drawer {
                    width: parent.width
                    expanded: false
                    Rectangle { width: parent.width; implicitHeight: 80; color: Theme.danger }
                }
                Caption { text: "end of card" }
            }
        }

        SectionTitle { text: "Squish" }
        Row {
            spacing: Theme.space24
            Repeater {
                model: [{ t: "rest", p: false, h: false }, { t: "hover (lift 2)", p: false, h: true }, { t: "pressed", p: true, h: false }]
                Column {
                    required property var modelData
                    spacing: 4
                    Squish {
                        pressed: modelData.p; hovered: modelData.h; lift: 2
                        Rectangle {
                            width: 48; height: 48; radius: Theme.radiusMd; color: Theme.accent
                            Icon { anchors.centerIn: parent; name: "app-window"; size: 22; color: Theme.onAccent }
                        }
                    }
                    Caption { text: modelData.t }
                }
            }
        }
    }

    // ---- right: glass on the busy backdrop --------------------------------
    Item {
        id: stage
        x: page.motion === "" ? parent.width / 2 : 0
        width: page.motion === "" ? parent.width / 2 : 480
        height: page.motion === "" ? parent.height : 430

        Rectangle { visible: page.motion !== ""; anchors.fill: parent; color: Theme.surface3 }

        // islands
        Island {
            id: logoIsland
            x: Theme.islandSideMargin; y: Theme.islandMargin
            text: "Lugh menu"
            Icon { name: "flame"; size: 16; color: Theme.accentText; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Firefox"; font: Theme.typeLabel; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
        }
        Island {
            id: centerIsland
            anchors.horizontalCenter: parent.horizontalCenter
            y: Theme.islandMargin
            text: "Notifications and calendar"
            Text {
                text: page.islandWide ? "Tue 10 Nov · 02:20 · 3 notifications waiting" : "Tue 10 · 02:20"
                font: Theme.typeLabelTnum; color: Theme.text
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        Island {
            id: statusIsland
            anchors.right: parent.right
            anchors.rightMargin: Theme.islandSideMargin
            y: Theme.islandMargin
            text: "Control center"
            active: page.morphOpen
            Icon { name: "wifi"; size: 16; anchors.verticalCenter: parent.verticalCenter }
            Icon { name: "volume-2"; size: 16; anchors.verticalCenter: parent.verticalCenter }
            Icon { name: "battery-medium"; size: 16; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "64"; font: Theme.typeLabelTnum; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
        }

        // island states (stills only)
        Column {
            visible: page.motion === ""
            x: Theme.space16
            y: 70
            spacing: Theme.space12
            Repeater {
                model: [{ t: "pressed", d: true, a: false, i: true }, { t: "active", d: false, a: true, i: true },
                        { t: "not interactive (OSD)", d: false, a: false, i: false }]
                Row {
                    required property var modelData
                    spacing: Theme.space12
                    Island {
                        down: modelData.d ? true : undefined; active: modelData.a; interactive: modelData.i
                        Icon { name: "volume-2"; size: 16; anchors.verticalCenter: parent.verticalCenter }
                        Slider { compact: true; value: 0.64; width: 110; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: "64"; font: Theme.typeLabelTnum; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Text { text: modelData.t; font: Theme.typeCaption; color: Theme.text; anchors.verticalCenter: parent.verticalCenter }
                }
            }
            Row {
                spacing: Theme.space12
                Island {
                    id: focusIsland
                    Text { text: "Focused island"; font: Theme.typeLabel; color: Theme.text }
                }
                Island {
                    height: 44; elevation: "popover"
                    Icon { name: "bell"; size: 18; color: Theme.accentText; anchors.verticalCenter: parent.verticalCenter }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        Text { text: "Updates ready"; font: Theme.typeLabel; color: Theme.text }
                        Text { text: "12 packages · restart later"; font: Theme.typeCaption; color: Theme.textMuted }
                    }
                }
            }
        }

        // the morphing control center
        MorphPanel {
            id: morph
            anchors.fill: parent
            open: page.morphOpen
            originRect: stage.mapFromItem(null, statusIsland.sceneRect.x, statusIsland.sceneRect.y,
                                          statusIsland.sceneRect.width, statusIsland.sceneRect.height)
            targetRect: Qt.rect(stage.width - 320 - Theme.islandSideMargin, 52, 320,
                                ccBody.implicitHeight + 2 * Theme.space12)

            Column {
                id: ccBody
                x: Theme.space12; y: Theme.space12
                width: parent.width - 2 * Theme.space12
                spacing: Theme.space12

                Grid {
                    columns: 4
                    columnSpacing: (parent.width - 4 * 48) / 3
                    rowSpacing: Theme.space12
                    IconToggle {
                        id: wifiToggle
                        iconName: "wifi-off"; checkedIconName: "wifi"; label: "Wi-Fi"
                        stateText: "Kigali Heights 5G"; hasDetail: true; checked: page.wifi
                    }
                    IconToggle { iconName: "bluetooth"; label: "Bluetooth"; hasDetail: true }
                    IconToggle { iconName: "moon"; label: "Night light"; checked: true }
                    IconToggle { iconName: "plane"; label: "Airplane mode" }
                    IconToggle { iconName: "bell-off"; label: "Do not disturb" }
                    IconToggle { iconName: "sun"; label: "Dark style"; checked: true }
                    IconToggle { iconName: "zap"; label: "Power profile"; hasDetail: true; busy: page.motion === "" }
                    IconToggle { iconName: "keyboard"; label: "Keyboard" }
                }
                Text {
                    width: parent.width
                    text: "Wi-Fi · Kigali Heights 5G"
                    font: Theme.typeCaption; color: Theme.textMuted
                    elide: Text.ElideRight
                }
                Slider { compact: true; width: parent.width; iconName: "volume-2"; value: 0.64 }
                Drawer {
                    id: ccDrawer
                    width: parent.width
                    expanded: page.drawerOpen
                    Column {
                        id: ccDrawerBody
                        width: parent.width
                        spacing: Theme.space8
                        Row {
                            spacing: Theme.space8
                            Chip { text: "Speakers"; iconName: "speaker"; selected: page.output === "spk"; onClicked: page.output = "spk" }
                            Chip { text: "Headphones"; iconName: "headphones"; selected: page.output === "hp"; onClicked: page.output = "hp" }
                        }
                        Slider { compact: true; width: parent.width; iconName: "mic"; value: 0.4 }
                    }
                }
                Slider { compact: true; width: parent.width; iconName: "sun"; value: 0.8 }
                Text {
                    text: "64% · 3 h 40"
                    font: Theme.typeCaptionTnum; color: Theme.textMuted
                }
            }
        }
    }

    // ---- motion capture ---------------------------------------------------
    property int _frame: 0
    property int _pending: 0
    property double _t0: 0
    function _value() {
        const p = morph._panel;
        if (motion.startsWith("morph"))
            return "x=" + p.x.toFixed(1) + " y=" + p.y.toFixed(1) + " w=" + p.width.toFixed(1) + " h=" + p.height.toFixed(1)
                 + " r=" + p.radius.toFixed(1) + " op=" + p.opacity.toFixed(2) + " progress=" + morph.progress.toFixed(3)
                 + " shown=" + morph.shown + " settled=" + morph.settled;
        if (motion.startsWith("drawer"))
            return "h=" + ccDrawer.implicitHeight.toFixed(1) + " target.h=" + morph.targetRect.height.toFixed(1) + " body=" + ccBody.implicitHeight.toFixed(1) + " animating=" + ccDrawer.animating + " panel.h=" + p.height.toFixed(1);
        if (motion === "island")
            return "w=" + centerIsland.width.toFixed(1) + " sceneRect=" + centerIsland.sceneRect;
        return "checked=" + wifiToggle.checked;
    }
    function _trigger() {
        _t0 = Date.now();
        switch (motion) {
        case "morph": case "morph-reverse": morphOpen = true; break;
        case "morph-close": morphOpen = false; break;
        case "morph-grow": drawerOpen = false; break;
        case "drawer": drawerOpen = true; break;
        case "drawer-close": drawerOpen = false; break;
        case "island": islandWide = true; break;
        case "toggle": wifi = !wifi; break;
        }
    }
    Timer {     // settle first, then go
        interval: 400
        running: page.motion !== ""
        onTriggered: {
            if (page.motion === "drawer" || page.motion === "toggle") {
                page.morphOpen = true;     // those live inside the panel
                later.start();
            } else {
                page._trigger(); grabber.start();
            }
        }
    }
    Timer { id: later; interval: 900; onTriggered: { page._trigger(); grabber.start(); } }
    Timer {
        id: grabber
        interval: 33
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const n = page._frame++;
            const t = Date.now() - page._t0;
            if (page.motion === "morph-reverse" && n === 5) page.morphOpen = false;
            if (page.motion === "morph-reverse" && n === 8) page.morphOpen = true;
            console.log("frame " + n + " t=" + t + "ms " + page._value());
            page._pending++;
            stage.grabToImage(r => {
                r.saveToFile(page.outDir + "/" + page.motion + "-" + String(n).padStart(2, "0") + ".png");
                if (--page._pending === 0 && !grabber.running) Qt.exit(0);
            });
            if (page._frame >= 24) stop();
        }
    }
}

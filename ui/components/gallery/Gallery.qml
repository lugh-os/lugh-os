// LughUI gallery: every Lugh.UI component in every state it supports, light
// and dark. It is the design reference and the source of the screenshot tests
// (phase-1 §3, acceptance 12).
//
//   scripts/qml-shot.sh ui/components/gallery/Gallery.qml out.png 1600 3700 1200 [-- args]
//   qml6 -I ui/components ui/components/gallery/main.qml [-- args]      (interactive)
//
// Args (after `--`):
//   --dark              dark theme
//   --accent NAME       amber | teal | green | blue | red | graphite
//   --section NAME      render one section only (focused screenshots):
//                       tokens icons buttons iconbuttons toggles sliders badges
//                       fields lists tabs menus surfaces feedback overlays
//   --reduce-motion     Theme.reduceMotion (also --reduce)
//
// States: rest, pressed (`down`/`pressed` forced), focus, selected/checked,
// disabled, loading/busy, empty and error are rendered statically. Only one
// item can hold keyboard focus, so one specimen per page gets real Tab focus
// (its ring proves the visualFocus path) and the other "Focus" specimens get
// the same FocusRing forced on in the same parent. Hover cannot be forced from
// QML (Control.hovered is read-only): check it in main.qml with a pointer.
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Lugh.UI

Rectangle {
    id: root
    color: Theme.bg
    implicitWidth: 1600
    implicitHeight: page.implicitHeight

    // ---- arguments ---------------------------------------------------------
    readonly property var _args: Qt.application.arguments
    function _arg(name, fallback) {
        const i = _args.indexOf(name);
        return i >= 0 && i + 1 < _args.length ? _args[i + 1] : fallback;
    }
    function _has(name) { return _args.indexOf(name) >= 0 }

    readonly property var sectionNames: ["tokens", "icons", "buttons", "iconbuttons", "toggles", "sliders",
        "badges", "fields", "lists", "tabs", "menus", "surfaces", "feedback", "overlays"]
    property string sectionFilter: _arg("--section", "")
    readonly property bool _solo: sectionFilter !== ""
    function shows(name) { return !_solo || sectionFilter === name }

    // Popups open (and real focus is placed) after the first layout pass.
    property bool ready: false

    readonly property int _margin: _solo ? Theme.space32 : Theme.space48
    readonly property int _gap: Theme.space32
    readonly property real _contentW: width - 2 * _margin
    readonly property real _colW: _solo ? _contentW : Math.floor((_contentW - _gap) / 2)

    readonly property url _logoUrl: Qt.resolvedUrl("../../../branding/logo/png/lugh-logo" + (Theme.dark ? "-dark" : "") + "-128.png")
    readonly property string _logoPath: _logoUrl.toString().replace(/^file:\/\//, "")
    readonly property url _wideArtUrl: Qt.resolvedUrl("../../../branding/wallpapers/dawn-light-blur.jpg")

    Component.onCompleted: {
        Theme.dark = _has("--dark");
        const a = _arg("--accent", "");
        if (a !== "") {
            if (Theme.accentNames.indexOf(a) < 0)
                console.warn("gallery: unknown accent", a, "- use one of", Theme.accentNames.join(" "));
            Theme.accentName = a;
        }
        Theme.reduceMotion = _has("--reduce-motion") || _has("--reduce");
        if (_solo && sectionNames.indexOf(sectionFilter) < 0)
            console.warn("gallery: unknown section", sectionFilter, "- use one of", sectionNames.join(" "));
    }

    // ---- forced focus rings + the one real keyboard focus ----------------------
    // Specimens opt in with `property string galleryRing: "<path to the item
    // that hosts the component's own FocusRing>"` ("self" = the specimen) and
    // optionally `property int galleryRealFocus: <priority>` (lowest wins).
    Component { id: ringComponent; FocusRing { show: true } }

    function _hostOf(item) {
        const p = item.galleryRing;
        if (p === "self") return item;
        return p.split(".").reduce((o, k) => o ? o[k] : null, item);
    }
    function _collect(item, out) {
        if (!item || !item.visible) return;
        if (item.galleryRing) out.push(item);
        for (let i = 0; i < item.children.length; ++i)
            _collect(item.children[i], out);
    }
    function _applyFocus() {
        const specs = [];
        _collect(page, specs);
        let real = null;
        for (const s of specs)
            if (s.galleryRealFocus !== undefined && (!real || s.galleryRealFocus < real.galleryRealFocus))
                real = s;
        for (const s of specs) {
            if (s === real) continue;
            const host = _hostOf(s);
            if (host) ringComponent.createObject(host);
            else console.warn("gallery: no focus-ring host for", s, s.galleryRing);
        }
        if (real) real.forceActiveFocus(Qt.TabFocusReason);
    }
    Timer {
        interval: 60; running: true
        onTriggered: { root.ready = true; focusTimer.start(); }
    }
    Timer {
        id: focusTimer; interval: 120
        onTriggered: {
            root._applyFocus();
            if (root._has("--print-size"))
                console.info("gallery-size", Math.ceil(root.width), Math.ceil(page.implicitHeight));
        }
    }

    // ---- page building blocks ----------------------------------------------------
    component Cap: Text {
        font: Theme.typeCaption
        color: Theme.textMuted
        elide: Text.ElideRight
    }
    component RowLabel: Text {
        font: Theme.typeCaption
        color: Theme.textMuted
        Layout.preferredWidth: 92
        Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
        elide: Text.ElideRight
    }
    component Sub: Text {
        font: Theme.typeBodyStrong
        color: Theme.text
        Layout.topMargin: Theme.space4
    }
    component Rule: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.border
    }
    component Note: Text {
        Layout.fillWidth: true
        font: Theme.typeCaption
        color: Theme.textMuted
        wrapMode: Text.Wrap
        lineHeight: Theme.lineBody
    }

    // A labeled section: typeTitle2 title, muted caption, content on a surface.
    component Section: ColumnLayout {
        id: sec
        property string name
        property string title
        property string caption
        property bool shown: true
        property bool bare: false          // content without the surface panel
        default property alias body: panel.data

        visible: shown
        spacing: Theme.space8
        Layout.fillWidth: true

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12
            Text {
                text: sec.title
                font: Theme.typeTitle2
                color: Theme.text
                Accessible.role: Accessible.Heading
            }
            Item { Layout.fillWidth: true }
            Text {
                text: "--section " + sec.name
                font: Theme.typeMono
                color: Theme.textMuted
                opacity: 0.8
            }
        }
        Text {
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.space8
            visible: text !== ""
            text: sec.caption
            font: Theme.typeBody
            lineHeight: Theme.lineBody
            color: Theme.textMuted
            wrapMode: Text.Wrap
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: panel.implicitHeight + 2 * pad
            readonly property int pad: sec.bare ? 0 : Theme.space24
            color: sec.bare ? "transparent" : Theme.surface
            border.width: sec.bare ? 0 : 1
            border.color: Theme.border
            radius: Theme.radiusLg
            ColumnLayout {
                id: panel
                x: parent.pad
                y: parent.pad
                width: parent.width - 2 * parent.pad
                spacing: Theme.space16
            }
        }
    }

    // The blurred default wallpaper, as the compositor would show it behind glass.
    component Backdrop: Rectangle {
        color: Theme.bg
        radius: Theme.radiusMd
        clip: true
        border.width: 1
        border.color: Theme.border
        Image {
            anchors.fill: parent
            anchors.margins: 1
            source: Qt.resolvedUrl("../../../branding/wallpapers/dawn-" + (Theme.dark ? "dark" : "light") + "-blur.jpg")
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: 960
            asynchronous: false
        }
    }

    // A quiet stage for floating things (popups, shadows): bg with a hairline.
    component Stage: Rectangle {
        color: Theme.bg
        radius: Theme.radiusMd
        border.width: 1
        border.color: Theme.border
    }

    component Swatch: ColumnLayout {
        id: sw
        property string token
        readonly property color value: Theme[token]
        spacing: Theme.space4
        Layout.preferredWidth: 104
        Rectangle {
            implicitWidth: 104
            implicitHeight: 52
            radius: Theme.radiusSm
            color: sw.value
            border.width: 1
            border.color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.12)
        }
        Text { text: sw.token; font: Theme.typeCaption; color: Theme.text }
        Text {
            text: String(sw.value).toUpperCase()
            font.family: Theme.fontMono
            font.pixelSize: 11
            color: Theme.textMuted
        }
    }

    // WCAG ratio of two opaque colors (live, from the running Theme).
    function _lum(c) {
        const f = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
    }
    function contrast(a, b) {
        const x = _lum(a), y = _lum(b);
        return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
    }
    component PairChip: Rectangle {
        id: pc
        property color fg
        property color bgc
        property string label
        property real need: 4.5
        readonly property real ratio: root.contrast(fg, bgc)
        readonly property bool pass: ratio >= need
        implicitWidth: 150
        implicitHeight: 64
        radius: Theme.radiusSm
        color: bgc
        border.width: 1
        border.color: Theme.border
        Text {
            x: Theme.space12; y: Theme.space8
            text: "Aa"
            font: Theme.typeTitle3
            color: pc.fg
        }
        Text {
            x: Theme.space12; y: 36
            width: parent.width - 2 * Theme.space12
            text: pc.label
            font: Theme.typeCaption
            color: pc.fg
            elide: Text.ElideRight
        }
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.space8
            implicitWidth: verdict.implicitWidth + 12
            implicitHeight: 20
            radius: 10
            color: Theme.surface
            border.width: 1
            border.color: pc.pass ? Theme.border : Theme.danger
            Row {
                id: verdict
                anchors.centerIn: parent
                spacing: 3
                Icon {
                    name: pc.pass ? "check" : "x"
                    size: 12
                    color: pc.pass ? Theme.success : Theme.danger
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: pc.ratio.toFixed(1)
                    font: Theme.typeCaptionTnum
                    color: Theme.text
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // ---- the page ----------------------------------------------------------------
    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: page.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        clip: true

        ColumnLayout {
            id: page
            width: flick.width
            spacing: 0

            // ==== header =======================================================
            Rectangle {
                Layout.fillWidth: true
                visible: !root._solo
                implicitHeight: header.implicitHeight + 2 * Theme.space40
                color: Theme.surface
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }

                RowLayout {
                    id: header
                    x: root._margin
                    y: Theme.space40
                    width: root._contentW
                    spacing: Theme.space40

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignTop
                        spacing: Theme.space8

                        RowLayout {
                            spacing: Theme.space12
                            Image {
                                source: root._logoUrl
                                sourceSize: Qt.size(32, 32)
                                Layout.preferredWidth: 32
                                Layout.preferredHeight: 32
                            }
                            Text {
                                text: "LUGH OS  ·  DESIGN SYSTEM"
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                                font.weight: 600
                                font.letterSpacing: 1.4
                                color: Theme.accentText
                            }
                        }
                        Text {
                            text: "LughUI component gallery"
                            font: Theme.typeDisplay
                            color: Theme.text
                            Layout.topMargin: Theme.space4
                        }
                        Text {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 760
                            text: "Every component in Lugh.UI, in every state it supports, drawn from the live Theme tokens. "
                                + "Use it as the reference when building shell surfaces and apps, and as the source of the "
                                + "light/dark screenshot and contrast checks."
                            font: Theme.typeBody
                            lineHeight: Theme.lineBody
                            color: Theme.textMuted
                            wrapMode: Text.Wrap
                        }
                        Flow {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.space12
                            spacing: Theme.space8
                            Repeater {
                                model: ["Rest", "Pressed", "Focus", "Selected", "Disabled", "Loading", "Empty", "Error"]
                                Rectangle {
                                    required property string modelData
                                    implicitWidth: chipText.implicitWidth + 20
                                    implicitHeight: 24
                                    radius: 12
                                    color: Theme.surface2
                                    Text {
                                        id: chipText
                                        anchors.centerIn: parent
                                        text: parent.modelData
                                        font: Theme.typeCaption
                                        color: Theme.text
                                    }
                                }
                            }
                            Text {
                                height: 24
                                verticalAlignment: Text.AlignVCenter
                                text: "Hover needs a pointer: open main.qml and move over any control."
                                font: Theme.typeCaption
                                color: Theme.textMuted
                            }
                        }
                    }

                    // Live switches: these are real Lugh.UI controls driving Theme.
                    Rectangle {
                        Layout.alignment: Qt.AlignTop
                        Layout.preferredWidth: 380
                        implicitHeight: switches.implicitHeight + 2 * Theme.space20
                        radius: Theme.radiusLg
                        color: Theme.bg
                        border.width: 1
                        border.color: Theme.border

                        ColumnLayout {
                            id: switches
                            x: Theme.space20; y: Theme.space20
                            width: parent.width - 2 * Theme.space20
                            spacing: Theme.space12

                            RowLayout {
                                Layout.fillWidth: true
                                Text { text: "Theme"; font: Theme.typeBodyStrong; color: Theme.text; Layout.fillWidth: true }
                                SegmentedControl {
                                    implicitWidth: 200
                                    model: [{ text: "Light", iconName: "sun" }, { text: "Dark", iconName: "moon" }]
                                    currentIndex: Theme.dark ? 1 : 0
                                    onActivated: i => Theme.dark = i === 1
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space8
                                Text { text: "Accent"; font: Theme.typeBodyStrong; color: Theme.text; Layout.fillWidth: true }
                                Repeater {
                                    model: Theme.accentNames
                                    Rectangle {
                                        id: swatchBtn
                                        required property string modelData
                                        readonly property bool current: Theme.accentName === modelData
                                        implicitWidth: 28; implicitHeight: 28
                                        radius: 14
                                        color: Theme.accentSwatch(modelData)
                                        border.width: current ? 2 : 1
                                        border.color: current ? Theme.text : Qt.rgba(0, 0, 0, 0.15)
                                        Accessible.role: Accessible.RadioButton
                                        Accessible.name: modelData
                                        Accessible.checked: current
                                        Icon {
                                            anchors.centerIn: parent
                                            visible: swatchBtn.current
                                            name: "check"
                                            size: 14
                                            color: root.contrast(swatchBtn.color, Qt.rgba(1, 1, 1, 1)) > 3 ? Qt.rgba(1, 1, 1, 1) : Qt.rgba(0.08, 0.08, 0.075, 1)
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: Theme.accentName = swatchBtn.modelData
                                        }
                                    }
                                }
                            }
                            Toggle {
                                text: "Reduce motion"
                                checked: Theme.reduceMotion
                                onToggled: Theme.reduceMotion = checked
                            }
                            Toggle {
                                text: "Shell transparency"
                                checked: Theme.transparency
                                onToggled: Theme.transparency = checked
                            }
                            Text {
                                text: (Theme.dark ? "Dark" : "Light") + " · " + Theme.accentName
                                    + (Theme.reduceMotion ? " · reduce motion" : "")
                                    + (Theme.transparency ? "" : " · opaque glass")
                                font: Theme.typeCaption
                                color: Theme.textMuted
                            }
                        }
                    }
                }
            }

            // ==== body ===========================================================
            ColumnLayout {
                Layout.leftMargin: root._margin
                Layout.rightMargin: root._margin
                Layout.topMargin: root._solo ? root._margin : Theme.space48
                Layout.bottomMargin: root._margin
                Layout.preferredWidth: root._contentW
                spacing: Theme.space48

                // ---- tokens ------------------------------------------------------
                Section {
                    id: secTokens
                    name: "tokens"; shown: root.shows(name)
                    title: "Foundations"
                    caption: "Color, contrast, type, radius and spacing tokens from Theme.qml, read live. Hex values are what QML "
                        + "actually resolves, so a token that fails to apply shows up here."

                    Sub { text: "Color" }
                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.space16
                        Repeater {
                            model: ["bg", "surface", "surface2", "surface3", "border", "text", "textMuted",
                                    "accent", "onAccent", "accentText", "success", "danger", "onDanger",
                                    "info", "warning", "warningFill"]
                            Swatch { required property string modelData; token: modelData }
                        }
                    }

                    Rule {}
                    Sub { text: "Contrast (WCAG 2.x, live)" }
                    Note { text: "Text pairs need 4.5:1, the focus ring 3:1 against what it sits on. The full matrix (every accent, glass over the wallpaper) is scripts/check-contrast.py." }
                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.space12
                        PairChip { fg: Theme.text; bgc: Theme.bg; label: "text / bg" }
                        PairChip { fg: Theme.textMuted; bgc: Theme.bg; label: "textMuted / bg" }
                        PairChip { fg: Theme.textMuted; bgc: Theme.surface2; label: "textMuted / surface2" }
                        PairChip { fg: Theme.accentText; bgc: Theme.surface; label: "accentText / surface" }
                        PairChip { fg: Theme.onAccent; bgc: Theme.accent; label: "onAccent / accent" }
                        PairChip { fg: Theme.onDanger; bgc: Theme.danger; label: "onDanger / danger" }
                        PairChip { fg: Theme.danger; bgc: Theme.surface; label: "danger / surface" }
                        PairChip { fg: Theme.bg; bgc: Theme.text; label: "tooltip (bg / text)" }
                        PairChip { fg: Theme.focusRing; bgc: Theme.bg; label: "focus ring / bg"; need: 3 }
                    }

                    Rule {}
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space48

                        ColumnLayout {
                            Layout.alignment: Qt.AlignTop
                            Layout.fillWidth: true
                            spacing: Theme.space12
                            Sub { text: "Type scale (Inter)" }
                            Repeater {
                                model: [
                                    { n: "typeDisplay", s: "34 / 600", f: Theme.typeDisplay },
                                    { n: "typeTitle1", s: "26 / 600", f: Theme.typeTitle1 },
                                    { n: "typeTitle2", s: "20 / 600", f: Theme.typeTitle2 },
                                    { n: "typeTitle3", s: "16 / 600", f: Theme.typeTitle3 },
                                    { n: "typeBody", s: "14 / 400", f: Theme.typeBody },
                                    { n: "typeBodyStrong", s: "14 / 550", f: Theme.typeBodyStrong },
                                    { n: "typeCaption", s: "12 / 450", f: Theme.typeCaption },
                                    { n: "typeMono", s: "13 / 400", f: Theme.typeMono }
                                ]
                                RowLayout {
                                    required property var modelData
                                    spacing: Theme.space16
                                    Layout.fillWidth: true
                                    ColumnLayout {
                                        spacing: 0
                                        Layout.preferredWidth: 120
                                        Layout.alignment: Qt.AlignVCenter
                                        Text { text: modelData.n; font: Theme.typeCaption; color: Theme.text }
                                        Text { text: modelData.s; font: Theme.typeCaption; color: Theme.textMuted }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.n === "typeMono" ? "systemctl --user status lugh-shell"
                                            : "Light for every surface, 0123456789"
                                        font: modelData.f
                                        color: Theme.text
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.alignment: Qt.AlignTop
                            Layout.preferredWidth: 520
                            spacing: Theme.space12
                            Sub { text: "Radius" }
                            RowLayout {
                                spacing: Theme.space16
                                Repeater {
                                    model: [["radiusSm", Theme.radiusSm], ["radiusMd", Theme.radiusMd],
                                            ["radiusLg", Theme.radiusLg], ["radiusXl", Theme.radiusXl],
                                            ["radiusFull", Theme.radiusFull]]
                                    ColumnLayout {
                                        required property var modelData
                                        spacing: Theme.space4
                                        Rectangle {
                                            implicitWidth: 72; implicitHeight: 56
                                            radius: modelData[1]
                                            color: Theme.surface2
                                            border.width: 1
                                            border.color: Theme.border
                                        }
                                        Cap { text: modelData[0] + "  " + (modelData[1] > 100 ? "full" : modelData[1]) }
                                    }
                                }
                            }
                            Sub { text: "Spacing"; Layout.topMargin: Theme.space12 }
                            Repeater {
                                model: [2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64]
                                RowLayout {
                                    required property int modelData
                                    spacing: Theme.space12
                                    Cap { text: "space" + modelData; Layout.preferredWidth: 64 }
                                    Rectangle {
                                        implicitWidth: modelData * 4
                                        implicitHeight: 8
                                        radius: 2
                                        color: Theme.accent
                                        opacity: 0.85
                                    }
                                    Cap { text: modelData + " px" }
                                }
                            }
                        }
                    }
                }

                // ---- two columns ---------------------------------------------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: root._solo ? 0 : root._gap

                    ColumnLayout {
                        id: col1
                        Layout.alignment: Qt.AlignTop
                        Layout.preferredWidth: root._colW
                        Layout.maximumWidth: root._colW
                        visible: secButtons.shown || secToggles.shown || secBadges.shown || secLists.shown || secSurfaces.shown || secMenus.shown
                        spacing: Theme.space48

                        // ---- buttons -----------------------------------------------
                        Section {
                            id: secButtons
                            name: "buttons"; shown: root.shows(name)
                            title: "Button"
                            caption: "Primary for the one main action, secondary for the rest, ghost in toolbars, danger for destructive actions. "
                                + "Pressed scales to 0.98; loading swaps the icon for a spinner and keeps the width; disabled explains itself in a tooltip."

                            GridLayout {
                                columns: 6
                                columnSpacing: Theme.space16
                                rowSpacing: Theme.space12

                                Cap { text: "" }
                                Cap { text: "Rest" }
                                Cap { text: "Pressed" }
                                Cap { text: "Focus" }
                                Cap { text: "Disabled" }
                                Cap { text: "Loading" }

                                RowLabel { text: "primary" }
                                Button { variant: "primary"; text: "Install"; iconName: "download" }
                                Button { variant: "primary"; text: "Install"; iconName: "download"; down: true }
                                Button { variant: "primary"; text: "Install"; iconName: "download"; property string galleryRing: "background"; property int galleryRealFocus: 5 }
                                Button { variant: "primary"; text: "Install"; iconName: "download"; enabled: false; disabledReason: "Already installed" }
                                Button { variant: "primary"; text: "Install"; iconName: "download"; loading: true }

                                RowLabel { text: "secondary" }
                                Button { text: "Share"; iconName: "share" }
                                Button { text: "Share"; iconName: "share"; down: true }
                                Button { text: "Share"; iconName: "share"; property string galleryRing: "background" }
                                Button { text: "Share"; iconName: "share"; enabled: false }
                                Button { text: "Share"; iconName: "share"; loading: true }

                                RowLabel { text: "ghost" }
                                Button { variant: "ghost"; text: "Details" }
                                Button { variant: "ghost"; text: "Details"; down: true }
                                Button { variant: "ghost"; text: "Details"; property string galleryRing: "background" }
                                Button { variant: "ghost"; text: "Details"; enabled: false }
                                Button { variant: "ghost"; text: "Details"; loading: true }

                                RowLabel { text: "danger" }
                                Button { variant: "danger"; text: "Delete"; iconName: "trash-2" }
                                Button { variant: "danger"; text: "Delete"; iconName: "trash-2"; down: true }
                                Button { variant: "danger"; text: "Delete"; iconName: "trash-2"; property string galleryRing: "background" }
                                Button { variant: "danger"; text: "Delete"; iconName: "trash-2"; enabled: false }
                                Button { variant: "danger"; text: "Delete"; iconName: "trash-2"; loading: true }

                                RowLabel { text: "sm" }
                                Button { size: "sm"; variant: "primary"; text: "Apply" }
                                Button { size: "sm"; text: "Copy"; iconName: "copy"; down: true }
                                Button { size: "sm"; variant: "ghost"; text: "Undo"; property string galleryRing: "background" }
                                Button { size: "sm"; variant: "danger"; text: "Remove"; enabled: false }
                                Button { size: "sm"; text: "Retry"; iconName: "refresh-cw"; loading: true }
                            }
                            Rule {}
                            RowLayout {
                                spacing: Theme.space12
                                RowLabel { text: "long label" }
                                Button {
                                    Layout.maximumWidth: 240
                                    variant: "primary"
                                    iconName: "download"
                                    text: "Install Microsoft Office Professional Plus 2019"
                                }
                                Cap { text: "elides at its max width" }
                            }
                        }

                        // ---- toggles + segmented ------------------------------------
                        Section {
                            id: secToggles
                            name: "toggles"; shown: root.shows(name)
                            title: "Toggle and SegmentedControl"
                            caption: "On is an accent track with the knob right and a check in the knob, so state never relies on color. "
                                + "Segments share one sliding pill that springs between options."

                            GridLayout {
                                columns: 6
                                columnSpacing: Theme.space24
                                rowSpacing: Theme.space8
                                Cap { text: "Off" }
                                Cap { text: "On" }
                                Cap { text: "Pressed" }
                                Cap { text: "Focus" }
                                Cap { text: "Disabled off" }
                                Cap { text: "Disabled on" }
                                Toggle {}
                                Toggle { checked: true }
                                Toggle { checked: true; down: true }
                                Toggle { checked: true; property string galleryRing: "indicator.children.0" }
                                Toggle { enabled: false; disabledReason: "Managed by your organization" }
                                Toggle { enabled: false; checked: true }
                            }
                            ColumnLayout {
                                Layout.preferredWidth: 380
                                spacing: Theme.space4
                                Toggle { text: "Wi-Fi"; checked: true }
                                Toggle { text: "Do not disturb" }
                                Toggle { text: "Bluetooth"; enabled: false; disabledReason: "No Bluetooth adapter found" }
                                Toggle { text: "Automatically install security updates and restart at night when idle"; checked: true }
                            }
                            Rule {}
                            GridLayout {
                                columns: 2
                                columnSpacing: Theme.space16
                                rowSpacing: Theme.space12
                                RowLabel { text: "text" }
                                SegmentedControl { implicitWidth: 300; model: ["Lugh", "Classic", "Focus"]; currentIndex: 0 }
                                RowLabel { text: "icon + text" }
                                SegmentedControl {
                                    implicitWidth: 220
                                    model: [{ text: "Grid", iconName: "layout-grid" }, { text: "List", iconName: "list" }]
                                    currentIndex: 1
                                }
                                RowLabel { text: "focus" }
                                SegmentedControl {
                                    implicitWidth: 300
                                    model: ["Small", "Medium", "Large"]
                                    currentIndex: 1
                                    property string galleryRing: "background"
                                }
                                RowLabel { text: "disabled" }
                                SegmentedControl { implicitWidth: 300; enabled: false; model: ["Lugh", "Classic", "Focus"]; currentIndex: 2 }
                            }
                        }

                        // ---- badges + spinner ------------------------------------
                        Section {
                            id: secBadges
                            name: "badges"; shown: root.shows(name)
                            title: "Badge and Spinner"
                            caption: "Badges pair a tone with a word or a count; a dot only marks “something new” next to a label. "
                                + "Spinners are for actions in progress; content loads with Skeleton."

                            GridLayout {
                                columns: 6
                                columnSpacing: Theme.space20
                                rowSpacing: Theme.space12
                                Cap { text: "" }
                                Cap { text: "accent" }
                                Cap { text: "neutral" }
                                Cap { text: "danger" }
                                Cap { text: "success" }
                                Cap { text: "info" }
                                RowLabel { text: "text" }
                                Badge { text: "3" }
                                Badge { tone: "neutral"; text: "Beta" }
                                Badge { tone: "danger"; text: "12" }
                                Badge { tone: "success"; text: "Saved" }
                                Badge { tone: "info"; text: "New" }
                                RowLabel { text: "count 99+" }
                                Badge { text: "99+" }
                                Badge { tone: "neutral"; text: "120" }
                                Badge { tone: "danger"; text: "99+" }
                                Badge { tone: "success"; text: "1" }
                                Badge { tone: "info"; text: "42" }
                                RowLabel { text: "dot" }
                                Badge { dot: true }
                                Badge { dot: true; tone: "neutral" }
                                Badge { dot: true; tone: "danger" }
                                Badge { dot: true; tone: "success" }
                                Badge { dot: true; tone: "info" }
                            }
                            RowLayout {
                                spacing: Theme.space24
                                RowLabel { text: "on an icon" }
                                Item {
                                    implicitWidth: 52; implicitHeight: 52
                                    AppIcon { anchors.centerIn: parent; size: 48; iconName: root._logoPath; fallbackText: "Lugh" }
                                    Badge { text: "4"; tone: "danger"; _outline: Theme.surface; x: parent.width - width + 4; y: -4 }
                                }
                                Item {
                                    implicitWidth: 52; implicitHeight: 52
                                    AppIcon { anchors.centerIn: parent; size: 48; iconName: "no-such-app"; fallbackText: "Mail" }
                                    Badge { dot: true; tone: "accent"; _outline: Theme.surface; x: parent.width - width + 2; y: -2 }
                                }
                            }
                            Rule {}
                            RowLayout {
                                spacing: Theme.space24
                                RowLabel { text: "Spinner" }
                                Spinner { size: 12 }
                                Spinner { size: 16 }
                                Spinner { size: 20 }
                                Spinner { size: 24; color: Theme.accentText }
                                Spinner { size: 32; color: Theme.text }
                                Rectangle {
                                    implicitWidth: 36; implicitHeight: 36; radius: Theme.radiusSm + 2
                                    color: Theme.accent
                                    Spinner { anchors.centerIn: parent; size: 16; color: Theme.onAccent }
                                }
                                Cap { text: "12 · 16 · 20 · 24 · 32 · on accent" }
                            }
                        }

                        // ---- list rows ----------------------------------------------
                        Section {
                            id: secLists
                            name: "lists"; shown: root.shows(name)
                            title: "ListRow"
                            caption: "Settings lists, launcher results and pickers. Highlighted (keyboard-current) adds a left bar; "
                                + "selected adds a check: tint plus a shape, never tint alone."

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "title" }
                                    ListRow { Layout.fillWidth: true; title: "Wi-Fi"; iconName: "wifi"; trailingText: "Home-5G"; showChevron: true }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "subtitle" }
                                    ListRow {
                                        Layout.fillWidth: true
                                        title: "Bluetooth"; subtitle: "2 devices connected"; iconName: "bluetooth"
                                        trailing: Component { Toggle { checked: true } }
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "app icon" }
                                    ListRow { Layout.fillWidth: true; title: "Lugh Welcome"; subtitle: "Application · /usr/share/lugh"; appIcon: root._logoPath; trailingText: "Open" }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "icon missing" }
                                    ListRow { Layout.fillWidth: true; title: "Notepad++"; subtitle: "Windows app · bottle “Tools”"; appIcon: "notepad-plus-plus" }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "selected" }
                                    ListRow { Layout.fillWidth: true; title: "Light"; iconName: "sun"; selected: true }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "highlighted" }
                                    ListRow { Layout.fillWidth: true; title: "Terminal"; subtitle: "Application"; iconName: "terminal"; highlighted: true; trailingText: "Enter" }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "pressed" }
                                    ListRow { Layout.fillWidth: true; title: "Display"; iconName: "monitor"; showChevron: true; down: true }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "focus" }
                                    ListRow { Layout.fillWidth: true; title: "Sound"; iconName: "volume-2"; showChevron: true; property string galleryRing: "background" }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "danger" }
                                    ListRow { Layout.fillWidth: true; title: "Remove bottle"; iconName: "trash-2"; danger: true }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "disabled" }
                                    ListRow { Layout.fillWidth: true; title: "Printers"; subtitle: "The printing service isn’t running"; iconName: "printer"; enabled: false; showChevron: true }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    RowLabel { text: "long text" }
                                    ListRow {
                                        Layout.fillWidth: true
                                        title: "Adobe Photoshop CS6 Extended (32-bit) with the Camera Raw and Bridge plug-ins"
                                        subtitle: "Windows app · bottle “Creative Suite” · last opened three weeks ago from the Downloads folder"
                                        iconName: "image"
                                        trailingText: "1.8 GB on disk, compressed"
                                        showChevron: true
                                    }
                                }
                            }
                        }

                        // ---- surfaces -------------------------------------------------
                        Section {
                            id: secSurfaces
                            name: "surfaces"; shown: root.shows(name)
                            title: "Card, GlassPanel and Shadow"
                            caption: "Cards hold app content; glass is only for the shell (bar, dock, launcher, control center), "
                                + "with the blur done by the compositor. Shadows come in three soft, neutral levels."

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space16
                                Repeater {
                                    model: [
                                        { t: "Plain", b: "Surface, 1 px border, radiusMd.", e: false, i: false },
                                        { t: "Elevated", b: "Adds the menu-level shadow.", e: true, i: false },
                                        { t: "Interactive", b: "Hover, press and keyboard focus.", e: false, i: true }
                                    ]
                                    Card {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 104
                                        elevated: modelData.e
                                        interactive: modelData.i
                                        property string galleryRing: modelData.i ? "self" : ""
                                        ColumnLayout {
                                            width: parent.width
                                            spacing: Theme.space4
                                            Text { text: modelData.t; font: Theme.typeTitle3; color: Theme.text }
                                            Text {
                                                Layout.fillWidth: true
                                                text: modelData.b + (modelData.i ? " (focus shown)" : "")
                                                font: Theme.typeBody; color: Theme.textMuted; wrapMode: Text.Wrap
                                            }
                                        }
                                    }
                                }
                            }

                            Backdrop {
                                Layout.fillWidth: true
                                implicitHeight: 248

                                GlassPanel {
                                    x: 20; y: 20
                                    width: parent.width - 40; height: 34
                                    radius: Theme.radiusMd
                                    elevation: "menu"
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.space12
                                        anchors.rightMargin: Theme.space12
                                        spacing: Theme.space12
                                        Image { source: root._logoUrl; sourceSize: Qt.size(16, 16); Layout.preferredWidth: 16; Layout.preferredHeight: 16 }
                                        Text { text: "Files"; font: Theme.typeBodyStrong; color: Theme.text }
                                        Text { text: "Edit   View   Go"; font: Theme.typeBody; color: Theme.textMuted }
                                        Item { Layout.fillWidth: true }
                                        Icon { name: "wifi"; size: 16 }
                                        Icon { name: "volume-2"; size: 16 }
                                        Icon { name: "battery-medium"; size: 16 }
                                        Text { text: "Wed 10 Nov  09:41"; font: Theme.typeBodyTnum; color: Theme.text }
                                    }
                                }
                                Repeater {
                                    model: [["menu", Theme.radiusMd], ["popover", Theme.radiusLg], ["window", Theme.radiusXl]]
                                    GlassPanel {
                                        required property var modelData
                                        required property int index
                                        x: 20 + index * ((parent.width - 40 + 16) / 3)
                                        y: 76
                                        width: (parent.width - 40 - 32) / 3
                                        height: 148
                                        radius: modelData[1]
                                        elevation: modelData[0]
                                        ColumnLayout {
                                            x: Theme.space16; y: Theme.space16
                                            width: parent.width - 2 * Theme.space16
                                            spacing: Theme.space4
                                            Text { text: "Glass · " + modelData[0]; font: Theme.typeTitle3; color: Theme.text }
                                            Text {
                                                Layout.fillWidth: true
                                                text: "radius " + modelData[1] + ". Muted text has to stay readable on the brightest part of the wallpaper."
                                                font: Theme.typeBody; color: Theme.textMuted; wrapMode: Text.Wrap
                                                lineHeight: Theme.lineBody
                                            }
                                        }
                                    }
                                }
                            }

                            Stage {
                                Layout.fillWidth: true
                                implicitHeight: 152
                                Repeater {
                                    model: [["menu", Theme.radiusMd], ["popover", Theme.radiusLg], ["window", Theme.radiusLg]]
                                    Item {
                                        required property var modelData
                                        required property int index
                                        x: 28 + index * ((parent.width - 56 + 32) / 3)
                                        y: 28
                                        width: (parent.width - 56 - 64) / 3
                                        height: 88
                                        Shadow { target: shBox; radius: modelData[1]; elevation: modelData[0] }
                                        Rectangle {
                                            id: shBox
                                            anchors.fill: parent
                                            radius: modelData[1]
                                            color: Theme.surface
                                            Text {
                                                anchors.centerIn: parent
                                                text: "Shadow · " + modelData[0]
                                                font: Theme.typeBodyStrong; color: Theme.text
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ---- menus + tooltips ---------------------------------------------------
                        Section {
                            id: secMenus
                            name: "menus"; shown: root.shows(name)
                            title: "Menu, MenuItem and Tooltip"
                            caption: "Menus line labels up when any item has an icon or a check. Row 2 is highlighted (arrow keys), "
                                + "“Copy path” pressed, “Rename” disabled. Tooltips use inverted colors."

                            Stage {
                                id: menuStage
                                Layout.fillWidth: true
                                implicitHeight: 330

                                // One Menu only: Qt keeps a single top-level Menu open per
                                // window (opening a second closes the first).
                                Menu {
                                    id: richMenu
                                    parent: menuStage
                                    x: 20; y: 20
                                    focus: false
                                    closePolicy: T.Popup.NoAutoClose
                                    visible: secMenus.shown
                                    MenuItem { text: "Open"; iconName: "folder-open"; shortcutText: "Ctrl+O" }
                                    MenuItem { text: "Open with…"; iconName: "app-window"; highlighted: true }
                                    MenuItem { text: "Copy path"; iconName: "copy"; shortcutText: "Ctrl+Shift+C"; down: true }
                                    MenuSeparator {}
                                    MenuItem { text: "Show hidden files"; checkable: true; checked: true; shortcutText: "Ctrl+H" }
                                    MenuItem { text: "Sort by date"; checkable: true }
                                    MenuItem { text: "Rename"; iconName: "pencil"; shortcutText: "F2"; enabled: false }
                                    Menu { title: "Move to workspace"; MenuItem { text: "Workspace 1" } }
                                    MenuSeparator {}
                                    MenuItem { text: "Move to Trash"; iconName: "trash-2"; shortcutText: "Del"; danger: true }
                                }
                                // tooltips, anchored to real buttons
                                IconButton {
                                    id: tipAnchor1
                                    x: 400; y: 120
                                    variant: "filled"; iconName: "settings"; tooltip: "Settings"
                                    Tooltip { text: "Settings"; delay: 0; visible: root.ready && secMenus.shown; closePolicy: T.Popup.NoAutoClose }
                                }
                                IconButton {
                                    x: parent.width - 180; y: 250
                                    variant: "filled"; iconName: "shield-alert"; tooltip: "Quarantined"
                                    Tooltip {
                                        text: "Quarantined: this app came from an unknown source, so it runs without network access."
                                        delay: 0; visible: root.ready && secMenus.shown; closePolicy: T.Popup.NoAutoClose
                                    }
                                }
                            }
                        }

                    }

                    ColumnLayout {
                        id: col2
                        Layout.alignment: Qt.AlignTop
                        Layout.preferredWidth: root._colW
                        Layout.maximumWidth: root._colW
                        visible: secIconButtons.shown || secSliders.shown || secIcons.shown || secFields.shown
                                 || secTabs.shown || secFeedback.shown
                        spacing: Theme.space48

                        // ---- icon buttons ---------------------------------------------
                        Section {
                            id: secIconButtons
                            name: "iconbuttons"; shown: root.shows(name)
                            title: "IconButton"
                            caption: "Icon-only buttons always carry a tooltip, which is also their accessible name. Checked is the selected "
                                + "state: accent tint, accent icon and an accent hairline."

                            GridLayout {
                                columns: 7
                                columnSpacing: Theme.space20
                                rowSpacing: Theme.space12
                                Cap { text: "" }
                                Cap { text: "Rest" }
                                Cap { text: "Pressed" }
                                Cap { text: "Checked" }
                                Cap { text: "Focus" }
                                Cap { text: "Disabled" }
                                Cap { text: "Badge" }

                                RowLabel { text: "ghost" }
                                IconButton { iconName: "settings"; tooltip: "Settings" }
                                IconButton { iconName: "settings"; tooltip: "Settings"; down: true }
                                IconButton { iconName: "bell-off"; tooltip: "Do not disturb"; checkable: true; checked: true }
                                IconButton { iconName: "settings"; tooltip: "Settings"; property string galleryRing: "background.children.0" }
                                IconButton { iconName: "settings"; tooltip: "Settings"; enabled: false; disabledReason: "Locked by policy" }
                                IconButton { iconName: "bell"; tooltip: "Notifications"; badge: 3 }

                                RowLabel { text: "filled" }
                                IconButton { variant: "filled"; iconName: "search"; tooltip: "Search" }
                                IconButton { variant: "filled"; iconName: "search"; tooltip: "Search"; down: true }
                                IconButton { variant: "filled"; iconName: "pin"; tooltip: "Pin"; checkable: true; checked: true }
                                IconButton { variant: "filled"; iconName: "search"; tooltip: "Search"; property string galleryRing: "background.children.0" }
                                IconButton { variant: "filled"; iconName: "search"; tooltip: "Search"; enabled: false }
                                IconButton { variant: "filled"; iconName: "bell"; tooltip: "Notifications"; badge: 120 }

                                RowLabel { text: "glass 44" }
                                IconButton { variant: "glass"; size: 44; iconSize: 20; iconName: "wifi"; tooltip: "Wi-Fi" }
                                IconButton { variant: "glass"; size: 44; iconSize: 20; iconName: "wifi"; tooltip: "Wi-Fi"; down: true }
                                IconButton { variant: "glass"; size: 44; iconSize: 20; iconName: "wifi"; tooltip: "Wi-Fi"; checkable: true; checked: true }
                                IconButton { variant: "glass"; size: 44; iconSize: 20; iconName: "wifi"; tooltip: "Wi-Fi"; property string galleryRing: "background.children.0" }
                                IconButton { variant: "glass"; size: 44; iconSize: 20; iconName: "wifi"; tooltip: "Wi-Fi"; enabled: false }
                                IconButton { variant: "glass"; size: 44; iconSize: 20; iconName: "bell"; tooltip: "Notifications"; badge: 7 }

                                RowLabel { text: "accent" }
                                IconButton { variant: "accent"; iconName: "plus"; tooltip: "New" }
                                IconButton { variant: "accent"; iconName: "plus"; tooltip: "New"; down: true }
                                IconButton { variant: "accent"; iconName: "plus"; tooltip: "New"; checkable: true; checked: true }
                                IconButton { variant: "accent"; iconName: "plus"; tooltip: "New"; property string galleryRing: "background.children.0" }
                                IconButton { variant: "accent"; iconName: "plus"; tooltip: "New"; enabled: false }
                                IconButton { variant: "accent"; iconName: "mail"; tooltip: "Mail"; badge: 99 }
                            }
                        }

                        // ---- sliders ------------------------------------------------------
                        Section {
                            id: secSliders
                            name: "sliders"; shown: root.shows(name)
                            title: "Slider"
                            caption: "The thick control-center slider. The leading icon is a button (mute, night light) and turns "
                                + "onAccent exactly where the fill covers it."

                            GridLayout {
                                columns: 2
                                columnSpacing: Theme.space16
                                rowSpacing: Theme.space12
                                RowLabel { text: "plain" }
                                Slider { Layout.fillWidth: true; value: 0.35 }
                                RowLabel { text: "icon + value" }
                                Slider { Layout.fillWidth: true; iconName: "volume-2"; iconTooltip: "Mute"; showValue: true; value: 0.62 }
                                RowLabel { text: "pressed" }
                                Slider { Layout.fillWidth: true; iconName: "sun"; iconTooltip: "Night light"; showValue: true; value: 0.8; pressed: true }
                                RowLabel { text: "focus" }
                                Slider { Layout.fillWidth: true; iconName: "volume-2"; showValue: true; value: 0.45; property string galleryRing: "background" }
                                RowLabel { text: "disabled" }
                                Slider { Layout.fillWidth: true; iconName: "mic"; showValue: true; value: 0.5; enabled: false }
                                RowLabel { text: "empty (0%)" }
                                Slider { Layout.fillWidth: true; iconName: "volume-x"; iconTooltip: "Unmute"; showValue: true; value: 0 }
                                RowLabel { text: "full (100%)" }
                                Slider { Layout.fillWidth: true; iconName: "sun"; showValue: true; value: 1 }
                                RowLabel { text: "narrow 160" }
                                Slider { Layout.preferredWidth: 160; iconName: "volume-1"; showValue: true; value: 0.08 }
                            }
                        }

                        // ---- icons -----------------------------------------------------------
                        Section {
                            id: secIcons
                            name: "icons"; shown: root.shows(name)
                            title: "Icon and AppIcon"
                            caption: "Symbolic icons are Lucide glyphs at 16, 20 and 24 px, colored by token. App icons resolve "
                                + "theme names, paths and URLs; wide art sits on a plate, and missing icons fall back to a letter."

                            Repeater {
                                model: [16, 20, 24]
                                RowLayout {
                                    id: iconRow
                                    required property int modelData
                                    spacing: Theme.space16
                                    RowLabel { text: iconRow.modelData + " px" }
                                    Repeater {
                                        model: ["wifi", "volume-2", "battery-medium", "bluetooth", "bell", "search",
                                                "shield", "folder", "settings", "power", "moon", "download"]
                                        Item {
                                            required property string modelData
                                            implicitWidth: 28; implicitHeight: 28
                                            Icon { anchors.centerIn: parent; name: parent.modelData; size: iconRow.modelData }
                                        }
                                    }
                                }
                            }
                            RowLayout {
                                spacing: Theme.space16
                                RowLabel { text: "tokens" }
                                Icon { name: "circle-check"; color: Theme.text }
                                Icon { name: "circle-check"; color: Theme.textMuted }
                                Icon { name: "circle-check"; color: Theme.accentText }
                                Icon { name: "circle-check"; color: Theme.success }
                                Icon { name: "circle-alert"; color: Theme.danger }
                                Icon { name: "info"; color: Theme.info }
                                Icon { name: "triangle-alert"; color: Theme.warning }
                                Cap { text: "text · muted · accentText · success · danger · info · warning" }
                            }
                            Rule {}
                            GridLayout {
                                columns: 6
                                columnSpacing: Theme.space24
                                rowSpacing: Theme.space8
                                Repeater {
                                    model: [
                                        { i: "firefox", f: "Firefox", c: "theme name" },
                                        { i: "utilities-terminal", f: "Terminal", c: "theme name" },
                                        { i: root._logoPath, f: "Lugh", c: "absolute path" },
                                        { i: root._wideArtUrl, f: "Wallpaper", c: "wide (plate)" },
                                        { i: "no-such-app", f: "Bottles", c: "missing → letter" },
                                        { i: "no-such-app", f: "", c: "no name → glyph" }
                                    ]
                                    ColumnLayout {
                                        required property var modelData
                                        spacing: Theme.space8
                                        AppIcon { Layout.alignment: Qt.AlignHCenter; size: 48; iconName: modelData.i; fallbackText: modelData.f }
                                        Cap { Layout.alignment: Qt.AlignHCenter; text: modelData.c }
                                    }
                                }
                            }
                            RowLayout {
                                spacing: Theme.space16
                                RowLabel { text: "sizes" }
                                Repeater {
                                    model: [16, 24, 32, 48, 64]
                                    AppIcon { required property int modelData; size: modelData; iconName: root._logoPath; Layout.alignment: Qt.AlignBottom }
                                }
                                Repeater {
                                    model: [24, 32, 48]
                                    AppIcon { required property int modelData; size: modelData; iconName: "no-such-app"; fallbackText: "Steam"; Layout.alignment: Qt.AlignBottom }
                                }
                            }
                        }

                        // ---- fields ------------------------------------------------------------
                        Section {
                            id: secFields
                            name: "fields"; shown: root.shows(name)
                            title: "TextField and SearchField"
                            caption: "Inputs sit on surface2 with a hairline; focus turns the border accent and adds the ring for keyboard focus. "
                                + "Errors say what is wrong and how to fix it, below the field."

                            GridLayout {
                                columns: 2
                                columnSpacing: Theme.space16
                                rowSpacing: Theme.space12
                                RowLabel { text: "empty" }
                                TextField { Layout.fillWidth: true; placeholderText: "Hostname"; iconName: "server" }
                                RowLabel { text: "filled" }
                                TextField { Layout.fillWidth: true; placeholderText: "Hostname"; iconName: "server"; text: "lugh-desktop"; clearable: true }
                                RowLabel { text: "focus (Tab)" }
                                TextField {
                                    Layout.fillWidth: true; placeholderText: "Hostname"; iconName: "server"; text: "lugh-desktop"
                                    property string galleryRing: "background"
                                    property int galleryRealFocus: 1
                                }
                                RowLabel { text: "password" }
                                TextField { Layout.fillWidth: true; placeholderText: "Password"; iconName: "lock"; password: true; text: "correct horse battery" }
                                RowLabel { text: "error"; Layout.alignment: Qt.AlignTop; Layout.topMargin: 10 }
                                TextField {
                                    Layout.fillWidth: true; placeholderText: "Hostname"; iconName: "server"; text: "lugh desktop"
                                    errorText: "Use letters, digits and hyphens only. Spaces aren’t allowed in a hostname."
                                }
                                RowLabel { text: "disabled" }
                                TextField { Layout.fillWidth: true; placeholderText: "Hostname"; iconName: "server"; text: "lugh-desktop"; enabled: false }
                                RowLabel { text: "long text" }
                                TextField { Layout.fillWidth: true; iconName: "link"; text: "https://downloads.example.org/releases/lugh-os/trixie/amd64/lugh-os-1.0-live-amd64.iso" }
                            }
                            Rule {}
                            GridLayout {
                                columns: 2
                                columnSpacing: Theme.space16
                                rowSpacing: Theme.space12
                                RowLabel { text: "search" }
                                SearchField { Layout.fillWidth: true; placeholderText: "Search settings" }
                                RowLabel { text: "filled" }
                                SearchField { Layout.fillWidth: true; text: "bluetooth" }
                                RowLabel { text: "busy" }
                                SearchField { Layout.fillWidth: true; text: "fire"; busy: true }
                                RowLabel { text: "focus" }
                                SearchField { Layout.fillWidth: true; placeholderText: "Search files"; property string galleryRing: "background" }
                                RowLabel { text: "disabled" }
                                SearchField { Layout.fillWidth: true; enabled: false }
                            }
                            Backdrop {
                                Layout.fillWidth: true
                                implicitHeight: 172
                                GlassPanel {
                                    x: 24; y: 22
                                    width: parent.width - 48; height: 128
                                    radius: Theme.radiusXl
                                    elevation: "window"
                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: Theme.space8
                                        spacing: 0
                                        SearchField { Layout.fillWidth: true; large: true; placeholderText: "Search apps, files and settings" }
                                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.glassBorder }
                                        SearchField { Layout.fillWidth: true; large: true; text: "firef"; busy: true }
                                    }
                                }
                            }
                            Note { text: "Large (launcher) fields: transparent on glass, 20 px text; empty and busy." }
                        }

                        // ---- tabs ------------------------------------------------------------------
                        Section {
                            id: secTabs
                            name: "tabs"; shown: root.shows(name)
                            title: "Tabs"
                            caption: "Underline tabs; the 2 px accent line slides between tabs (fades under reduce motion)."

                            GridLayout {
                                columns: 2
                                columnSpacing: Theme.space16
                                rowSpacing: Theme.space12
                                RowLabel { text: "current" }
                                Tabs { model: ["General", "Network", "Privacy", "Updates"]; currentIndex: 0 }
                                RowLabel { text: "focus" }
                                Tabs {
                                    model: ["General", "Network", "Privacy", "Updates"]; currentIndex: 1
                                    property string galleryRing: "contentChildren.2.background.children.0"
                                }
                                RowLabel { text: "disabled" }
                                Tabs { model: ["General", "Network", "Privacy"]; currentIndex: 2; enabled: false }
                                RowLabel { text: "overflow" }
                                Tabs {
                                    Layout.preferredWidth: 360
                                    model: ["Overview", "Processes", "Startup apps", "Services", "Bottles", "History"]
                                    currentIndex: 0
                                }
                            }
                        }

                        // ---- feedback --------------------------------------------------------------
                        Section {
                            id: secFeedback
                            name: "feedback"; shown: root.shows(name)
                            title: "Skeleton, EmptyState and ErrorBanner"
                            caption: "Loading content shimmers in place of what is coming; empty states offer one way forward; "
                                + "errors give a plain cause and a recovery action."

                            Sub { text: "Loading" }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space24
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.space16
                                    Repeater {
                                        model: 3
                                        RowLayout {
                                            required property int index
                                            spacing: Theme.space12
                                            Skeleton { implicitWidth: 36; implicitHeight: 36; radius: 18 }
                                            ColumnLayout {
                                                spacing: Theme.space8
                                                Skeleton { implicitWidth: [180, 140, 200][index]; implicitHeight: 12 }
                                                Skeleton { implicitWidth: [120, 96, 150][index]; implicitHeight: 10; radius: 5 }
                                            }
                                        }
                                    }
                                }
                                Skeleton { Layout.preferredWidth: 220; Layout.preferredHeight: 132; radius: Theme.radiusMd }
                            }
                            Rule {}
                            Sub { text: "Empty" }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space16
                                Stage {
                                    Layout.fillWidth: true
                                    implicitHeight: 248
                                    EmptyState {
                                        anchors.centerIn: parent
                                        width: parent.width - 32
                                        iconName: "package"
                                        title: "No bottles yet"
                                        body: "Windows apps you install get their own bottle, so they can’t touch the rest of the system."
                                        actionText: "Install a Windows app"
                                    }
                                }
                                Stage {
                                    Layout.fillWidth: true
                                    implicitHeight: 248
                                    EmptyState {
                                        anchors.centerIn: parent
                                        width: parent.width - 32
                                        title: "No results for “qwertz”"
                                        body: "Try a shorter search, or check the spelling."
                                    }
                                }
                            }
                            Rule {}
                            Sub { text: "Error" }
                            ErrorBanner {
                                Layout.fillWidth: true
                                text: "Couldn’t reach the update server. Check your connection."
                                actionText: "Try again"
                            }
                            ErrorBanner {
                                Layout.fillWidth: true
                                text: "No Bluetooth adapter found."
                                dismissible: false
                            }
                            ErrorBanner {
                                Layout.fillWidth: true
                                text: "“Photoshop” stopped responding while saving “poster-final-v3.psd”. Your last autosave from 09:12 is safe; "
                                    + "reopen the app to recover it, or send a report so we can look into it."
                                actionText: "Reopen"
                            }
                        }
                    }
                }

                // ---- overlays -----------------------------------------------------------------
                Section {
                    id: secOverlays
                    name: "overlays"; shown: root.shows(name)
                    title: "Dialog and Popover"
                    caption: "Dialogs are modal: the scrim dims everything behind, Esc rejects, Enter accepts. While busy both actions "
                        + "lock and the primary shows a spinner. Popovers open below their anchor, or above it from the dock."

                    GridLayout {
                        Layout.fillWidth: true
                        columns: root._solo || root._contentW > 1300 ? 3 : 1
                        columnSpacing: Theme.space24
                        rowSpacing: Theme.space24

                        // Dialog stages: wallpaper + scrim, dialog centered. Non-modal here so
                        // three can be open at once; the stage draws the scrim instead.
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space8
                            Cap { text: "Default · extra content" }
                            Backdrop {
                                id: dlgStage1
                                Layout.fillWidth: true
                                Layout.minimumWidth: 448
                                implicitHeight: 312
                                Rectangle { anchors.fill: parent; radius: parent.radius; color: Theme.scrim }
                                Dialog {
                                    parent: dlgStage1
                                    modal: false; focus: false
                                    visible: root.ready && secOverlays.shown
                                    title: "Rename bottle"
                                    text: "Bottle names appear in the launcher and in Settings."
                                    primaryText: "Rename"
                                    TextField { width: parent ? parent.width : 0; text: "Office tools"; iconName: "package" }
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space8
                            Cap { text: "Danger · busy" }
                            Backdrop {
                                id: dlgStage2
                                Layout.fillWidth: true
                                Layout.minimumWidth: 448
                                implicitHeight: 312
                                Rectangle { anchors.fill: parent; radius: parent.radius; color: Theme.scrim }
                                Dialog {
                                    parent: dlgStage2
                                    modal: false; focus: false
                                    visible: root.ready && secOverlays.shown
                                    title: "Delete “Photos”?"
                                    text: "The bottle and the 3 apps in it are removed. This can’t be undone."
                                    primaryText: "Delete"
                                    danger: true
                                    busy: true
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space8
                            Cap { text: "Error · recovery" }
                            Backdrop {
                                id: dlgStage3
                                Layout.fillWidth: true
                                Layout.minimumWidth: 448
                                implicitHeight: 312
                                Rectangle { anchors.fill: parent; radius: parent.radius; color: Theme.scrim }
                                Dialog {
                                    parent: dlgStage3
                                    modal: false; focus: false
                                    visible: root.ready && secOverlays.shown
                                    title: "Connect to “Home-5G”"
                                    text: "Enter the password for this network."
                                    primaryText: "Connect"
                                    errorText: "The password is incorrect. Check it and try again."
                                    TextField { width: parent ? parent.width : 0; text: "hunter22"; password: true; iconName: "lock" }
                                }
                            }
                        }

                        Repeater {
                            model: 3
                            ColumnLayout {
                                required property int index
                                Layout.fillWidth: true
                                spacing: Theme.space8
                                Cap { text: ["Popover · surface", "Popover · glass", "Popover · opens above (dock)"][index] }
                                Rectangle {
                                    id: popStage
                                    Layout.fillWidth: true
                                    implicitHeight: 312
                                    radius: Theme.radiusMd
                                    color: Theme.bg
                                    border.width: 1
                                    border.color: Theme.border
                                    clip: true
                                    Image {
                                        anchors.fill: parent
                                        anchors.margins: 1
                                        visible: index > 0
                                        source: Qt.resolvedUrl("../../../branding/wallpapers/dawn-" + (Theme.dark ? "dark" : "light") + "-blur.jpg")
                                        fillMode: Image.PreserveAspectCrop
                                        sourceSize.width: 960
                                    }
                                    Item {
                                        id: popAnchor
                                        x: 24
                                        y: index === 2 ? parent.height - 64 : 24
                                        width: anchorBtn.width; height: anchorBtn.height
                                        Button {
                                            id: anchorBtn
                                            visible: index === 0
                                            text: "Quick settings"; iconName: "sliders-horizontal"
                                        }
                                        IconButton {
                                            visible: index > 0
                                            variant: "glass"; size: 44; iconSize: 20
                                            iconName: index === 1 ? "wifi" : "folder"
                                            tooltip: index === 1 ? "Wi-Fi" : "Files"
                                            checkable: true; checked: true
                                        }
                                        Popover {
                                            focus: false
                                            glass: index > 0
                                            closePolicy: T.Popup.NoAutoClose
                                            visible: root.ready && secOverlays.shown
                                            width: 300
                                            y: index === 2 ? -implicitHeight - 8 : parent.height + 8
                                            ColumnLayout {
                                                width: 268
                                                spacing: Theme.space8
                                                Text {
                                                    text: ["Quick settings", "Wi-Fi", "Recent files"][index]
                                                    font: Theme.typeTitle3; color: Theme.text
                                                }
                                                Toggle { visible: index < 2; text: index === 0 ? "Night light" : "Use Wi-Fi"; checked: true }
                                                Slider { visible: index === 0; Layout.fillWidth: true; iconName: "sun"; showValue: true; value: 0.7 }
                                                ListRow { visible: index === 1; Layout.fillWidth: true; title: "Home-5G"; subtitle: "Connected · secured"; iconName: "wifi"; selected: true }
                                                ListRow { visible: index === 1; Layout.fillWidth: true; title: "Café Lugh"; subtitle: "Open network"; iconName: "wifi-low" }
                                                ListRow { visible: index === 2; Layout.fillWidth: true; title: "poster-final-v3.psd"; subtitle: "Pictures · 09:12"; iconName: "image" }
                                                ListRow { visible: index === 2; Layout.fillWidth: true; title: "Quarterly report.odt"; subtitle: "Documents · yesterday"; iconName: "file-text" }
                                                Text {
                                                    visible: index === 0
                                                    Layout.fillWidth: true
                                                    text: "Warmer colors after sunset, until 07:00."
                                                    font: Theme.typeCaption; color: Theme.textMuted; wrapMode: Text.Wrap
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

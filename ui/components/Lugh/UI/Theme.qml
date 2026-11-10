// LughUI design tokens: the single source of truth for color, type, space,
// shape and motion in every Lugh surface. Mirrors docs/DESIGN-SYSTEM.md; when
// the two disagree, the doc wins and this file gets fixed.
//
//   import Lugh.UI
//   Rectangle { color: Theme.surface; radius: Theme.radiusMd }
//   Text { font: Theme.typeBody; color: Theme.text }
//
// Live switching: set `Theme.dark`, `Theme.accentName` or `Theme.reduceMotion`
// and every binding updates without a restart (phase-1 acceptance 11).
pragma Singleton
import QtQuick

QtObject {
    id: theme

    // ---- switches ---------------------------------------------------------
    property bool dark: false
    // amber | teal | green | blue | red | graphite (DESIGN-SYSTEM §2.3)
    property string accentName: "amber"
    // Follows Settings → Accessibility and the system flag. Movement becomes
    // short cross-fades (DESIGN-SYSTEM §5).
    property bool reduceMotion: false
    // Shell glass on/off (Settings → Appearance → transparency). When false,
    // glass surfaces use their opaque fallback.
    property bool transparency: true
    // Preview only: an Item at scene (0,0), full-window size, showing the
    // blurred wallpaper. When set, GlassPanel draws the part under itself
    // before its tint (simulating Hyprland's layer blur). Always null in
    // production, where the compositor blurs.
    property Item backdrop: null

    // ---- color: base (DESIGN-SYSTEM §2.1 / §2.2) --------------------------
    readonly property color bg: dark ? "#141413" : "#F7F6F3"
    readonly property color surface: dark ? "#1C1B19" : "#FFFFFF"
    readonly property color surface2: dark ? "#262522" : "#EEECE7"
    readonly property color surface3: dark ? "#302E2A" : "#E4E1DA"
    readonly property color border: dark ? "#34322E" : "#DEDAD2"
    readonly property color text: dark ? "#EDEBE6" : "#1C1B19"
    readonly property color textMuted: dark ? "#A29D94" : "#5F5B54"

    // ---- color: accent ----------------------------------------------------
    // Every preset has a fill, a text color on that fill, and an accent text
    // color for links/labels; all pairs pass WCAG AA against bg and surface.
    readonly property var _accents: ({
        "amber":    { light: ["#E8962E", "#1C1B19", "#9A5800"], dark: ["#F2A93B", "#141413", "#F2A93B"] },
        "teal":     { light: ["#0E7C7E", "#FFFFFF", "#0C6A6C"], dark: ["#2AA5A7", "#141413", "#2AA5A7"] },
        "green":    { light: ["#2A7B44", "#FFFFFF", "#256C3C"], dark: ["#4CB06B", "#141413", "#4CB06B"] },
        "blue":     { light: ["#2F6FDB", "#FFFFFF", "#225CC0"], dark: ["#6A98E6", "#141413", "#6A98E6"] },
        "red":      { light: ["#C23B31", "#FFFFFF", "#AE352C"], dark: ["#E2756B", "#141413", "#E2756B"] },
        "graphite": { light: ["#5F5B54", "#FFFFFF", "#5F5B54"], dark: ["#A29D94", "#141413", "#A29D94"] }
    })
    readonly property var _accent: (_accents[accentName] || _accents.amber)[dark ? "dark" : "light"]
    readonly property color accent: _accent[0]
    // `onAccent` / `onDanger` can't use an initializer: since `accent` and
    // `danger` exist, QML would parse `onAccent: …` as a signal handler. They
    // are bound by the Binding objects below instead (treat as read-only).
    property color onAccent
    readonly property color accentText: _accent[2]
    readonly property var accentNames: ["amber", "teal", "green", "blue", "red", "graphite"]
    function accentSwatch(name) { return (_accents[name] || _accents.amber)[dark ? "dark" : "light"][0] }

    // ---- color: semantic (§2.3) -------------------------------------------
    readonly property color success: dark ? "#4CC38A" : "#1F7A4A"
    readonly property color danger: dark ? "#F06A5F" : "#B4322A"
    readonly property color info: dark ? "#5BB4DA" : "#1E6A8C"
    readonly property color warning: dark ? "#F5C04A" : "#8A6100"     // text/icon
    readonly property color warningFill: "#F5C04A"
    property color onDanger
    property Binding _bindOnAccent: Binding { target: theme; property: "onAccent"; value: theme._accent[1] }
    property Binding _bindOnDanger: Binding { target: theme; property: "onDanger"; value: theme.dark ? "#141413" : "#FFFFFF" }

    // ---- color: state overlays (§7) ---------------------------------------
    readonly property color hoverOverlay: dark ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(0, 0, 0, 0.04)
    readonly property color pressedOverlay: dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.08)
    readonly property color selectedBg: Qt.rgba(accent.r, accent.g, accent.b, 0.16)
    // Non-text 3:1 (WCAG 1.4.11): the light amber fill is only ~2.2:1 on bg,
    // so light mode rings use the darker accent text color.
    readonly property color focusRing: dark ? accent : accentText
    readonly property real disabledOpacity: 0.4
    readonly property color scrim: Qt.rgba(0, 0, 0, dark ? 0.5 : 0.28)

    // ---- color: shell glass (§2) ------------------------------------------
    // The compositor blurs what is behind (30 px). Text on glass stays AA
    // because the tint never drops below these opacities (shell NFR-4).
    readonly property color glass: !transparency ? surface
        : dark ? Qt.rgba(28 / 255, 27 / 255, 25 / 255, 0.82) : Qt.rgba(1, 1, 1, 0.72)
    // Thin hairline on glass edges so surfaces read on busy wallpapers.
    readonly property color glassBorder: dark ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.08)
    readonly property color glassHighlight: dark ? Qt.rgba(1, 1, 1, 0.05) : Qt.rgba(1, 1, 1, 0.6)
    readonly property int glassBlurPx: 30

    // ---- shadows (§4: 3 levels, soft and neutral) --------------------------
    // For MultiEffect: shadowBlur 0..1, shadowVerticalOffset px, shadowColor.
    readonly property color shadowColor: Qt.rgba(0, 0, 0, dark ? 0.45 : 0.16)
    readonly property var elevationMenu:    ({ blur: 0.35, y: 2,  opacity: dark ? 0.40 : 0.14 })
    readonly property var elevationPopover: ({ blur: 0.6,  y: 6,  opacity: dark ? 0.45 : 0.16 })
    readonly property var elevationWindow:  ({ blur: 0.9,  y: 12, opacity: dark ? 0.50 : 0.18 })

    // ---- typography (§3) --------------------------------------------------
    readonly property string fontUi: "Inter"
    readonly property string fontMono: "JetBrains Mono"
    readonly property font typeDisplay:    Qt.font({ family: fontUi, pixelSize: 34, weight: 600 })
    readonly property font typeTitle1:     Qt.font({ family: fontUi, pixelSize: 26, weight: 600 })
    readonly property font typeTitle2:     Qt.font({ family: fontUi, pixelSize: 20, weight: 600 })
    readonly property font typeTitle3:     Qt.font({ family: fontUi, pixelSize: 16, weight: 600 })
    readonly property font typeBody:       Qt.font({ family: fontUi, pixelSize: 14, weight: 400 })
    readonly property font typeBodyStrong: Qt.font({ family: fontUi, pixelSize: 14, weight: 550 })
    readonly property font typeCaption:    Qt.font({ family: fontUi, pixelSize: 12, weight: 450 })
    readonly property font typeMono:       Qt.font({ family: fontMono, pixelSize: 13, weight: 400 })
    // Live numbers (clocks, meters): same as body/caption with tabular figures.
    readonly property font typeBodyTnum:    Qt.font({ family: fontUi, pixelSize: 14, weight: 500, features: { "tnum": 1 } })
    readonly property font typeCaptionTnum: Qt.font({ family: fontUi, pixelSize: 12, weight: 450, features: { "tnum": 1 } })
    readonly property real lineBody: 1.45
    readonly property real lineHeading: 1.2

    // ---- space (§4) -------------------------------------------------------
    readonly property int space2: 2
    readonly property int space4: 4
    readonly property int space8: 8
    readonly property int space12: 12
    readonly property int space16: 16
    readonly property int space20: 20
    readonly property int space24: 24
    readonly property int space32: 32
    readonly property int space40: 40
    readonly property int space48: 48
    readonly property int space64: 64

    // ---- shape (§4) -------------------------------------------------------
    readonly property int radiusSm: 6      // inputs, small buttons
    readonly property int radiusMd: 10     // cards, menus
    readonly property int radiusLg: 14     // windows, popovers
    readonly property int radiusXl: 20     // dock, launcher
    readonly property int radiusFull: 9999 // pills, toggles (clamped by Qt)
    readonly property int hitTarget: 32
    readonly property int focusRingWidth: 2
    readonly property int focusRingOffset: 2

    // ---- motion (§5) ------------------------------------------------------
    readonly property int durMicro: 120
    readonly property int durSmall: 180
    readonly property int durMedium: 240
    readonly property int durLarge: 300
    readonly property int durReduced: 100
    // Duration for a transition that moves or scales things. Under reduce
    // motion, callers should also skip the movement and only fade.
    function dur(ms) { return reduceMotion ? durReduced : ms }
    // cubic-bezier(0.2, 0, 0, 1) for fades and most property animations:
    //   easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeStandard
    readonly property var easeStandard: [0.2, 0, 0, 1, 1, 1]
    // Spring (stiffness 400, damping 32) for movement, as SpringAnimation params.
    readonly property real springSpring: 6.0
    readonly property real springDamping: 0.42
    readonly property real springEpsilon: 0.25
}

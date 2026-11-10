// Desktop wallpaper: fills its parent with the current wallpaper and
// cross-fades between the light and dark variant of the art when the theme
// (or the chosen wallpaper) changes.
//
//   Wallpaper { anchors.fill: parent }                  // desktop
//   Wallpaper { anchors.fill: parent; blurred: true }   // lock screen, glass backdrops
//   Wallpaper { anchors.fill: parent; name: "tide" }    // a bundled wallpaper by name
//
// Source, in order: `source` if set; else Services.appearance.wallpaperDark /
// wallpaperLight when they hold a file path or URL; else the bundled art
// `<name>-<light|dark>-<size>.jpg`, where the name is the one in
// Services.appearance.wallpaperDark / wallpaperLight when that has the form
// `lugh://wallpapers/<name>`, else the `name` property ("dawn", "tide",
// "ember"; see branding/wallpapers/wallpapers.json). Bundled art is looked up
// in /usr/share/backgrounds/lugh/ (lugh-branding) and, if that fails to load,
// in the repo's branding/wallpapers/ (preview and demos).
//
// Memory: the full-size image is decoded at the item's pixel size
// (sourceSize = size × devicePixelRatio, cropped to cover), asynchronously and
// uncached, from the smallest file that covers it: 2560×1600 up to 2560 device
// pixels wide, 3840×2160 up to 3840, 5120×2880 beyond. Two layers exist only to cross-fade; once a fade ends the hidden
// layer's source is cleared, so one full-size texture stays resident.
// `blurred` uses the small pre-blurred file (960×540, cached, scaled up
// smoothly) instead of a runtime blur shader.
import QtQuick
import QtQuick.Window
import Lugh.UI
import Lugh.Shell

Item {
    id: root

    property bool dark: Theme.dark
    property bool blurred: false
    // Bundled wallpaper to show when Services does not choose one.
    property string name: "dawn"
    // Optional override for both themes. Empty = follow Services/bundled art.
    property url source: ""

    // The image currently shown (after any fade finishes) and whether it is up.
    readonly property url currentSource: _front ? _front.source : ""
    readonly property bool ready: _front !== null && _front.status === Image.Ready

    // Services.appearance.wallpaperDir lets the preview point at the repo art
    // directly, so a dev tree never probes (and warns about) /usr/share.
    readonly property string systemDir: Services.appearance.wallpaperDir || "file:///usr/share/backgrounds/lugh/"
    readonly property string repoDir: Qt.resolvedUrl("../../../../../../branding/wallpapers/")

    // ---- resolution ---------------------------------------------------------
    property bool _useRepo: false        // set when the system copy fails to load
    property bool _customFailed: false   // set when source/Services path fails
    readonly property real _dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    readonly property int _pxW: Math.ceil(width * _dpr)
    readonly property int _pxH: Math.ceil(height * _dpr)
    readonly property string _custom: {
        if (_customFailed) return "";
        if (source.toString() !== "") return source.toString();
        return _setting.startsWith(_scheme) ? "" : _setting;
    }
    readonly property string _scheme: "lugh://wallpapers/"
    readonly property string _setting: {
        const a = Services.appearance;
        return (dark ? a.wallpaperDark : a.wallpaperLight) || "";
    }
    // The bundled name in effect: lugh://wallpapers/<name> from Services, else `name`.
    readonly property string bundledName: {
        if (source.toString() === "" && _setting.startsWith(_scheme)) {
            const n = _setting.slice(_scheme.length).replace(/[^a-z0-9_-]/gi, "");
            if (n !== "") return n;
        }
        return name || "dawn";
    }
    property bool _nameFailed: false     // set when the named art does not exist
    onBundledNameChanged: _nameFailed = false
    readonly property string _bundled: {
        const kind = blurred ? "blur" : (_pxW > 3840 ? "5120x2880" : _pxW > 2560 ? "3840x2160" : "2560x1600");
        return (_useRepo ? repoDir : systemDir) + (_nameFailed ? "dawn" : bundledName) + "-" + (dark ? "dark" : "light") + "-" + kind + ".jpg";
    }
    // Nothing loads until the item has a size: a 0×0 sourceSize would decode
    // the file at full resolution.
    readonly property string _target: (_pxW > 0 && _pxH > 0) ? (_custom || _bundled) : ""

    on_TargetChanged: _show(_target)
    onSourceChanged: _customFailed = false
    Connections {
        target: Services.appearance
        function onWallpaperLightChanged() { root._customFailed = false; }
        function onWallpaperDarkChanged() { root._customFailed = false; }
    }

    // ---- two layers, one fade -----------------------------------------------
    property Image _front: null     // fully shown layer
    property Image _incoming: null  // layer loading / fading in

    function _show(url) {
        if (fade.running) _finishFade();
        if (url === "") return;
        if (_incoming && _incoming.source.toString() === url) return;   // already loading
        if (_front && _front.source.toString() === url) {
            // Back to what is already shown (e.g. a toggle undone mid-load).
            if (_incoming) { _incoming.source = ""; _incoming = null; }
            return;
        }
        const next = (_front === layerA) ? layerB : layerA;
        if (_incoming && _incoming !== next) _incoming.source = "";
        next.opacity = 0;
        next.z = 1;
        if (_front) _front.z = 0;
        _incoming = next;
        next.source = url;
        if (next.status === Image.Ready) _startFade();   // cached (blurred) hit
    }
    function _startFade() {
        fade.target = _incoming;
        fade.restart();
    }
    function _finishFade() {
        fade.stop();
        if (!_incoming) return;
        _incoming.opacity = 1;
        if (_front && _front !== _incoming) _front.source = "";   // release the hidden texture
        _front = _incoming;
        _incoming = null;
    }
    function _failed(layer) {
        const url = layer.source.toString();
        if (url === "") return;
        if (url.startsWith(systemDir) && !_useRepo) {
            _useRepo = true;            // dev tree: no lugh-branding installed
        } else if (_custom !== "" && url === _custom) {
            console.warn("Wallpaper: cannot load", url, "- using the default");
            _customFailed = true;
        } else if (!_nameFailed && bundledName !== "dawn") {
            console.warn("Wallpaper: no bundled wallpaper named", bundledName, "- using dawn");
            _nameFailed = true;
        } else {
            console.warn("Wallpaper: cannot load", url);
            if (layer === _incoming) { layer.source = ""; _incoming = null; }
        }
    }

    NumberAnimation {
        id: fade
        property: "opacity"
        to: 1
        duration: Theme.dur(Theme.durLarge)
        easing.type: Easing.OutCubic
        onFinished: root._finishFade()
    }

    component Layer: Image {
        id: layer
        anchors.fill: parent
        opacity: 0
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        mipmap: false
        // The pre-blurred file is small and shared (lock screen + glass), so
        // it may stay cached; full-size art never is.
        readonly property bool isSmall: root.blurred && root._custom === ""
        cache: isSmall
        // Custom images in blurred mode: decode tiny and let smooth upscaling
        // blur it (no shader). Otherwise decode at the item's pixel size.
        sourceSize: isSmall ? Qt.size(-1, -1)
                    : root.blurred ? Qt.size(Math.max(1, Math.round(root._pxW / 16)), Math.max(1, Math.round(root._pxH / 16)))
                    : Qt.size(root._pxW, root._pxH)
        onStatusChanged: {
            if (status === Image.Ready && layer === root._incoming && !fade.running) root._startFade();
            else if (status === Image.Error) root._failed(layer);
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
    }
    Layer { id: layerA }
    Layer { id: layerB }

    Component.onCompleted: _show(_target)
}

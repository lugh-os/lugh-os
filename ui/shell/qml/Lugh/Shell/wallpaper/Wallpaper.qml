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
//
// Resize / scale change: the shown layer is never reloaded in place (that
// would blank it while decoding). It keeps covering the screen, scaled, and
// once the size has been still for 250 ms the art is decoded at the new size
// into the other layer and cross-faded in. Theme / wallpaper changes
// cross-fade the same way: the old image stays fully opaque under the new
// one until the new one is covering, so no empty or black frame shows.
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
    readonly property int _wantW: Math.ceil(width * _dpr)
    readonly property int _wantH: Math.ceil(height * _dpr)
    // The decode size: follows _want*, debounced while the size changes.
    property int _pxW: 0
    property int _pxH: 0
    on_WantWChanged: _sizeChanged()
    on_WantHChanged: _sizeChanged()
    function _sizeChanged() {
        if (_wantW === _pxW && _wantH === _pxH) { sizeSettle.stop(); return; }
        // Nothing shown yet: take the size at once.
        if (!_front || _pxW <= 0 || _pxH <= 0) { sizeSettle.stop(); _applySize(); }
        else sizeSettle.restart();
    }
    function _applySize() { _pxW = _wantW; _pxH = _wantH; }
    Timer { id: sizeSettle; interval: 250; onTriggered: root._applySize() }
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

    // The decode size a layer gets for `url`: the small pre-blurred file at
    // its own size; custom art in blurred mode tiny (smooth upscaling blurs
    // it, no shader); everything else at the item's pixel size.
    function _decodeSize(url) {
        if (blurred && _custom === "") return Qt.size(-1, -1);
        if (blurred) return Qt.size(Math.max(1, Math.round(_pxW / 16)), Math.max(1, Math.round(_pxH / 16)));
        return Qt.size(_pxW, _pxH);
    }
    function _key(url, sz) { return url === "" ? "" : url + "|" + sz.width + "x" + sz.height; }
    readonly property string _targetKey: _target === "" ? "" : _key(_target, _decodeSize(_target))

    on_TargetKeyChanged: _show(_target)
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
        const size = _decodeSize(url), key = _key(url, size);
        if (_incoming && _incoming.key === key) return;   // already loading
        if (_front && _front.key === key) {
            // Back to what is already shown (e.g. a toggle undone mid-load).
            if (_incoming) { _incoming.source = ""; _incoming.key = ""; _incoming = null; }
            return;
        }
        const next = (_front === layerA) ? layerB : layerA;
        if (_incoming && _incoming !== next) { _incoming.source = ""; _incoming.key = ""; }
        next.opacity = 0;
        next.z = 1;
        if (_front) _front.z = 0;
        _incoming = next;
        next.decodeSize = size;
        next.key = key;
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
        if (_front && _front !== _incoming) { _front.source = ""; _front.key = ""; }   // release the hidden texture
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
            if (layer === _incoming) { layer.source = ""; layer.key = ""; _incoming = null; }
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
        // Set with the source by _show(), never changed under a shown image
        // (that would blank it while it decodes again).
        property size decodeSize: Qt.size(-1, -1)
        property string key: ""
        // The pre-blurred file is small and shared (lock screen + glass), so
        // it may stay cached; full-size art never is.
        cache: decodeSize.width < 0
        sourceSize: decodeSize
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

    Component.onCompleted: { _applySize(); _show(_target); }
}

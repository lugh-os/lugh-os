// Shared cache for QML types that may not exist yet (surfaces and LughUI
// components are written in parallel). component() returns the Component, or
// null after warning once per type, so the preview runs with whatever exists.
.pragma library

const _cache = {};

function component(moduleUri, typeName) {
    if (!typeName) return null;
    const key = moduleUri + "/" + typeName;
    if (key in _cache) return _cache[key];
    const c = Qt.createComponent(moduleUri, typeName);
    if (c.status === 3 /* Component.Error */) {
        console.warn("lugh-preview:", key, "unavailable:", c.errorString().trim());
        _cache[key] = null;
    } else {
        _cache[key] = c;
    }
    return _cache[key];
}

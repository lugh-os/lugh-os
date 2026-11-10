// Loader for a type that may be missing: renders nothing when it is.
//   Optional { type: "Icon"; props: ({ name: "wifi", size: 16, color: Theme.text }) }
// `props` is re-applied whenever it changes, so bindings inside it stay live.
import QtQuick
import "optional.js" as Opt

Loader {
    id: opt
    property string module: "Lugh.UI"
    property string type
    property var props: ({})

    sourceComponent: Opt.component(module, type)
    function _apply() {
        if (!item) return;
        for (const k in props) item[k] = props[k];
    }
    onLoaded: _apply()
    onPropsChanged: _apply()
}

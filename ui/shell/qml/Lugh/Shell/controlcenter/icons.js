// Lucide icon names for live levels (shared by the control-center pages).
.pragma library

function wifi(enabled, connected, strength) {
    if (!enabled) return "wifi-off";
    if (!connected) return "wifi-zero";
    return signal(strength);
}

function signal(strength) {
    if (strength >= 67) return "wifi";
    if (strength >= 34) return "wifi-high";
    if (strength >= 10) return "wifi-low";
    return "wifi-zero";
}

function volume(v, muted) {
    if (muted || v <= 0) return "volume-x";
    if (v < 0.34) return "volume";
    if (v < 0.67) return "volume-1";
    return "volume-2";
}

function battery(percent, charging) {
    if (charging) return "battery-charging";
    if (percent <= 15) return "battery-warning";
    if (percent <= 40) return "battery-low";
    if (percent <= 75) return "battery-medium";
    return "battery-full";
}

function profile(p) {
    return p === "power-saver" ? "leaf" : p === "performance" ? "zap" : "gauge";
}

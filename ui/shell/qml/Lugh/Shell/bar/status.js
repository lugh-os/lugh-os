// Icon names and spoken descriptions for the bar's status cluster. Pure
// functions over the Services objects, so bindings that call them re-evaluate
// only when a property they read changes.
.pragma library

function _strengthWord(s) {
    return s >= 67 ? qsTr("strong signal")
         : s >= 34 ? qsTr("good signal")
         : s >= 10 ? qsTr("weak signal")
         : qsTr("very weak signal");
}

// Lucide name for the network state (shape differs per state, never color alone).
function networkIcon(n) {
    if (n.airplaneMode) return "plane";
    if (n.wired && n.connected) return "ethernet-port";
    if (!n.wifiAvailable || !n.wifiEnabled) return "wifi-off";
    if (n.connectingSsid !== "") return "wifi-sync";
    if (!n.connected) return "wifi-off";
    const s = n.strength;
    return s >= 67 ? "wifi" : s >= 34 ? "wifi-high" : s >= 10 ? "wifi-low" : "wifi-zero";
}

function networkDescription(n) {
    if (n.airplaneMode) return qsTr("Airplane mode is on");
    if (n.wired && n.connected) return qsTr("Wired: connected");
    if (!n.wifiAvailable) return qsTr("No network connection");
    if (!n.wifiEnabled) return qsTr("Wi-Fi is off");
    if (n.connectingSsid !== "") return qsTr("Wi-Fi: connecting to %1").arg(n.connectingSsid);
    if (!n.connected) return qsTr("Wi-Fi: not connected");
    return qsTr("Wi-Fi: %1, %2").arg(n.ssid).arg(_strengthWord(n.strength));
}

function volumeIcon(a) {
    if (a.muted || a.volume <= 0) return "volume-x";
    return a.volume < 0.34 ? "volume" : a.volume < 0.67 ? "volume-1" : "volume-2";
}

function volumeDescription(a) {
    if (a.muted) return qsTr("Sound: muted");
    return qsTr("Volume %1%").arg(Math.round(a.volume * 100));
}

function batteryIcon(p) {
    if (p.charging) return "battery-charging";
    const v = p.batteryPercent;
    return v <= 10 ? "battery-warning" : v <= 30 ? "battery-low" : v <= 70 ? "battery-medium" : "battery-full";
}

function batteryLow(p) { return !p.charging && p.batteryPercent <= 10; }

function batteryDescription(p) {
    const v = p.batteryPercent;
    if (p.charging)
        return v >= 100 ? qsTr("Battery full, plugged in") : qsTr("Battery %1%, charging").arg(v);
    if (p.timeRemaining !== "")
        return qsTr("Battery %1%, %2 left").arg(v).arg(p.timeRemaining);
    return qsTr("Battery %1%").arg(v);
}

function bluetoothShown(b) { return b.available && b.enabled && b.connectedCount > 0; }

// One spoken line for the whole status island:
// "Status: Wi-Fi: Kigali Heights 5G, strong signal; Volume 62%; Battery 64%".
function summary(n, b, a, p, k) {
    const parts = [];
    if (k.layouts.length > 1)
        parts.push(qsTr("Keyboard %1").arg(k.current.toUpperCase()));
    parts.push(networkDescription(n));
    if (bluetoothShown(b))
        parts.push(qsTr("Bluetooth: %n device(s) connected", "", b.connectedCount));
    parts.push(volumeDescription(a));
    if (p.hasBattery)
        parts.push(batteryDescription(p));
    return qsTr("Status: %1").arg(parts.join("; "));
}

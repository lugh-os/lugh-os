-- Environment for every process Hyprland starts (the shell, apps, portals).
--
-- lugh-session already exports the session identity (XDG_SESSION_TYPE,
-- XDG_CURRENT_DESKTOP, ...) before the compositor starts. They are repeated
-- here so a nested development session gets the same values. Nothing here is
-- pushed to systemd/D-Bus: lugh-session does that once, with an explicit list,
-- when Hyprland is up (see 70-session.lua).

local env = {
    -- Session identity. "Lugh:Hyprland": our name first (portals pick
    -- lugh-portals.conf; OnlyShowIn=Lugh works), Hyprland second so tools that
    -- look for Hyprland (xdg-desktop-portal-hyprland, scripts) still find it.
    XDG_CURRENT_DESKTOP = "Lugh:Hyprland",
    XDG_SESSION_DESKTOP = "lugh",
    XDG_SESSION_TYPE    = "wayland",
    DESKTOP_SESSION     = "lugh",

    -- Cursor. Adwaita ships in adwaita-icon-theme on every profile. Hyprcursor
    -- falls back to XCursor themes when no hyprcursor theme is installed.
    XCURSOR_THEME   = "Adwaita",
    XCURSOR_SIZE    = "24",
    HYPRCURSOR_SIZE = "24",

    -- Qt: Wayland first, X11 (xcb) fallback. Qt's own fallback client-side
    -- title bar is turned off: it looks foreign, and Lugh mode draws no frame
    -- (border 0, rounded corners and a shadow come from the compositor).
    QT_QPA_PLATFORM                     = "wayland;xcb",
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "1",

    -- GTK: Wayland first, X11 fallback.
    GDK_BACKEND = "wayland,x11",

    -- Firefox: native Wayland (default on current Firefox, harmless otherwise).
    MOZ_ENABLE_WAYLAND = "1",

    -- Electron/Chromium apps pick Wayland when available.
    ELECTRON_OZONE_PLATFORM_HINT = "auto",

    -- Java AWT under XWayland: avoid the blank-window bug with non-reparenting WMs.
    _JAVA_AWT_WM_NONREPARENTING = "1",
}

-- SDL_VIDEODRIVER is deliberately NOT set: forcing Wayland breaks older
-- games and the Steam runtime. SDL3 already prefers Wayland on its own.

for name, value in pairs(env) do
    hl.env(name, value)
end

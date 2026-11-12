-- Environment for every process Hyprland starts (the shell, apps, portals).
--
-- lugh-session already exports the session identity (XDG_SESSION_TYPE,
-- XDG_CURRENT_DESKTOP, ...) before the compositor starts. They are repeated
-- here so a nested development session gets the same values. Nothing here is
-- pushed to systemd/D-Bus: lugh-session does that once, with an explicit list,
-- when Hyprland is up (see 70-session.lua).

-- Lugh's server-side title bars (hyprbars) are installed and match this
-- Hyprland: decides how Qt decorates its windows (below).
local titlebars = require("lugh.titlebars").available()

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

    -- Title bars: GTK 3/4/libadwaita and Firefox draw their own (buttons on
    -- the right: gsettings button-layout, see
    -- ui/shell/session/90_lugh-session.gschema.override). Hyprland 0.55 has no
    -- title bars of its own and answers every xdg-decoration request with
    -- "server side"; Lugh's hyprbars build (lugh/titlebars.lua) draws a
    -- compact bar for exactly those windows (foot, mpv, Qt, X11, ...).

    -- Qt: Wayland first, X11 (xcb) fallback. With Lugh's title bars, Qt 5 and
    -- Qt 6 ask for server-side decorations and get one compact bar, with
    -- Hyprland's shadow only. Without them (plugin missing or built for
    -- another Hyprland), Qt must not bind xdg-decoration (it would draw
    -- nothing) and draws its own title bar with the Adwaita decoration plugin
    -- of qt6-wayland 6.8 (follows button-layout and the colour scheme through
    -- the Settings portal). QT_WAYLAND_DISABLED_INTERFACES is always set
    -- (empty with title bars) so no stale value survives in the systemd user
    -- environment from an earlier login.
    QT_QPA_PLATFORM                 = "wayland;xcb",
    QT_WAYLAND_DISABLED_INTERFACES  = titlebars and "" or "zxdg_decoration_manager_v1",
    QT_WAYLAND_DECORATION           = "adwaita",

    -- GTK: Wayland first, X11 fallback. GTK_CSD=1: GTK 3 windows without a
    -- header bar (and every GTK 3 app under XWayland, which has no window
    -- manager frame here) draw a client-side title bar too. Firefox reads it
    -- as well (tabs in the title bar, buttons from the GTK layout).
    GDK_BACKEND = "wayland,x11",
    GTK_CSD     = "1",

    -- Firefox: native Wayland (default on current Firefox, harmless otherwise).
    MOZ_ENABLE_WAYLAND = "1",

    -- Electron/Chromium apps pick Wayland when available. Their windows ask
    -- for client-side decorations (Chromium's own frame with the tabs, and
    -- frameless Electron apps) and draw them; the Lugh title bar is only
    -- added when they ask for server-side ("Use system title bar").
    ELECTRON_OZONE_PLATFORM_HINT = "auto",

    -- Java AWT under XWayland: avoid the blank-window bug with non-reparenting WMs.
    _JAVA_AWT_WM_NONREPARENTING = "1",
}

-- SDL_VIDEODRIVER is deliberately NOT set: forcing Wayland breaks older
-- games and the Steam runtime. SDL3 already prefers Wayland on its own.

for name, value in pairs(env) do
    hl.env(name, value)
end

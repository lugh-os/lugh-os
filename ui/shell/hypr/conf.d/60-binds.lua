-- Keybindings: the "Lugh" column of docs/specs/shell.md "Default keyboard shortcuts".
--
-- Shell actions go to lugh-shell over D-Bus (space.lugh.Shell1, see lugh/shell.lua).
-- Window actions use Hyprland dispatchers or lugh/window.lua.
-- From Phase 2, lugh-settingsd may write ~/.config/lugh/generated/hyprland-bindings.lua
-- (loaded after this file) to apply [bindings.*] from desktop.toml.

local shell  = require("lugh.shell")
local window = require("lugh.window")
local tiling = require("lugh.tiling")
local workspaces = require("lugh.workspaces")

local S = lugh.scripts

-- Bind with a description (shown by `hyprctl binds`, usable by a cheat sheet).
local function bind(keys, action, desc, opts)
    opts = opts or {}
    opts.description = desc
    return hl.bind(keys, action, opts)
end

-- Launch an app in its own systemd scope (ADR-015), resolving lugh.apps at
-- press time so user.lua overrides apply.
local function app(key, fallback)
    return function()
        local cmd = lugh.apps[key]
        local line = S .. "/launch.sh " .. shell.quote(key) .. " " .. cmd
        if fallback then
            local exe = cmd:match("^%S+") or cmd
            line = "if command -v " .. shell.quote(exe) .. " >/dev/null 2>&1; then "
                .. line .. "; else " .. fallback .. "; fi"
        end
        hl.exec_cmd(line)
    end
end

---------------------------------------------------------------------------
-- Shell surfaces
---------------------------------------------------------------------------
bind("SUPER + SPACE", shell.dsp("ShowLauncher", "s", ""),         "Search / launcher")
bind("SUPER + TAB",   shell.dsp("ShowOverview"),                  "Overview")
bind("SUPER + C",     shell.dsp("ToggleControlCenter"),           "Control center")
bind("SUPER + N",     shell.dsp("ToggleNotificationCenter"),      "Notification center")
bind("SUPER + B",     shell.dsp("FocusPanel"),                    "Focus the panel")

-- Lock goes through logind: the shell's lock screen listens to the session's
-- Lock signal, the same path used by idle and suspend.
bind("SUPER + L", hl.dsp.exec_cmd("loginctl lock-session"), "Lock")

-- Screenshots: area / screen / window.
bind("Print",         shell.dsp("Screenshot", "s", "area"),   "Screenshot (area)")
bind("SHIFT + Print", shell.dsp("Screenshot", "s", "screen"), "Screenshot (screen)")
bind("ALT + Print",   shell.dsp("Screenshot", "s", "window"), "Screenshot (window)")

---------------------------------------------------------------------------
-- Apps
---------------------------------------------------------------------------
bind("CTRL + ALT + T", app("terminal", S .. "/launch.sh terminal foot"), "Terminal")
bind("SUPER + E",      app("files"),                                       "Files")
bind("SUPER + comma",  app("settings", shell.command("ToggleControlCenter")), "Settings")
bind("CTRL + SHIFT + Escape", app("tasks", shell.command("ShowLauncher", "s", "Tasks")), "Tasks")

---------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------
bind("SUPER + Q", hl.dsp.window.close(), "Close window")
bind("ALT + F4",  hl.dsp.window.close(), "Close window")

bind("SUPER + M",  function() window.minimize() end, "Minimize")
bind("SUPER + up", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }), "Maximize")
bind("SUPER + F",  hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }), "Fullscreen")

bind("SUPER + left",  function() window.snap("left") end,  "Snap left")
bind("SUPER + right", function() window.snap("right") end, "Snap right")

bind("SUPER + SHIFT + left",  hl.dsp.window.move({ direction = "left" }),  "Move window left")
bind("SUPER + SHIFT + right", hl.dsp.window.move({ direction = "right" }), "Move window right")
bind("SUPER + SHIFT + up",    hl.dsp.window.move({ direction = "up" }),    "Move window up")
bind("SUPER + SHIFT + down",  hl.dsp.window.move({ direction = "down" }),  "Move window down")

bind("SUPER + T", function() tiling.toggle() end, "Toggle tiling on this workspace")

bind("ALT + TAB",         function() window.cycle(false) end, "Next window")
bind("ALT + SHIFT + TAB", function() window.cycle(true) end,  "Previous window")
bind("ALT + grave",       function() window.cycle_same_app() end, "Next window of this app")

-- Mouse: Super + left drag moves, Super + right drag resizes.
hl.bind("SUPER + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })

---------------------------------------------------------------------------
-- Workspaces: a rows × cols grid (default 2 × 2, lugh/workspaces.lua).
-- Super+Ctrl+arrows: neighbouring workspace; + Shift: take the window along.
-- Ctrl+1..9 switch, Ctrl+Shift+1..9 move the window there (grid only);
-- Super+scroll: next / previous in grid order (never leaves the grid).
-- Super+Tab (above) opens the shell's overview of the grid.
---------------------------------------------------------------------------
workspaces.apply()
for _, dir in ipairs({ "left", "right", "up", "down" }) do
    bind("SUPER + CTRL + " .. dir, function() workspaces.go(dir) end,
        "Workspace " .. dir)
    bind("SUPER + CTRL + SHIFT + " .. dir, function() workspaces.move(dir) end,
        "Move window to workspace " .. dir)
end
for i = 1, 9 do
    bind("CTRL + " .. i,         function() workspaces.focus(i) end, "Workspace " .. i)
    bind("CTRL + SHIFT + " .. i, function() workspaces.send(i) end,  "Move window to workspace " .. i)
end
bind("SUPER + mouse_down", function() workspaces.scroll(1) end,  "Next workspace")
bind("SUPER + mouse_up",   function() workspaces.scroll(-1) end, "Previous workspace")

---------------------------------------------------------------------------
-- Hardware keys: change the value, then show the shell's OSD.
-- `locked` = also work on the lock screen; `repeating` = auto-repeat.
---------------------------------------------------------------------------
local key = S .. "/media-key.sh "
local hw = { locked = true, repeating = true }
bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd(key .. "volume-up"),       "Volume up",       hw)
bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd(key .. "volume-down"),     "Volume down",     hw)
bind("XF86AudioMute",         hl.dsp.exec_cmd(key .. "volume-mute"),     "Mute",            { locked = true })
bind("XF86AudioMicMute",      hl.dsp.exec_cmd(key .. "mic-mute"),        "Microphone mute", { locked = true })
bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(key .. "brightness-up"),   "Brightness up",   hw)
bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(key .. "brightness-down"), "Brightness down", hw)
bind("XF86KbdBrightnessUp",   hl.dsp.exec_cmd(key .. "kbd-brightness-up"),   "Keyboard backlight up",   hw)
bind("XF86KbdBrightnessDown", hl.dsp.exec_cmd(key .. "kbd-brightness-down"), "Keyboard backlight down", hw)
bind("XF86AudioPlay",  hl.dsp.exec_cmd(key .. "play-pause"), "Play/pause", { locked = true })
bind("XF86AudioPause", hl.dsp.exec_cmd(key .. "play-pause"), "Play/pause", { locked = true })
bind("XF86AudioNext",  hl.dsp.exec_cmd(key .. "next"),       "Next track", { locked = true })
bind("XF86AudioPrev",  hl.dsp.exec_cmd(key .. "previous"),   "Previous track", { locked = true })
-- Caps Lock OSD: read the state after the key is released; the key itself
-- still reaches the keyboard (non_consuming).
bind("Caps_Lock", hl.dsp.exec_cmd(key .. "caps-lock"), "Caps Lock indicator",
    { release = true, non_consuming = true })

-- Lugh OS: Hyprland configuration for Lugh mode (Phase 1, ADR-012).
--
-- Target: Hyprland 0.55.2 (Debian trixie-backports, 0.55.2+ds-1~bpo13+1).
--         Also verified against 0.57.0 (Debian sid).
--
-- Format: Lua. Since 0.55 Hyprland's primary config language is Lua (`hl.*` API).
-- The old hyprlang `.conf` format is "legacy" in 0.55 and was removed in 0.57,
-- so Lugh is written in Lua from the start. See docs/dev/hyprland.md.
--
-- Installed layout (package lugh-hyprland-config):
--   /usr/share/lugh/hypr/lugh.lua          this file (entry point)
--   /usr/share/lugh/hypr/conf.d/*.lua      the parts, loaded in the order below
--   /usr/share/lugh/hypr/lugh/*.lua        Lua modules (tiling, shell helpers)
--   /usr/share/lugh/hypr/scripts/*         helpers called by binds and the shell
--
-- Launched by lugh-session as: start-hyprland -- --config /usr/share/lugh/hypr/lugh.lua
-- Validate with:               Hyprland --verify-config --config <path>/lugh.lua

-- Directory of this file, so the config works from /usr/share/lugh/hypr and
-- straight from a git checkout (ui/shell/hypr) for nested testing.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

-- One global table so binds, `hyprctl dispatch 'lugh.x.y'` and user overrides
-- can reach Lugh's helpers. `hl` itself is read-only.
lugh = {
    dir     = here,
    scripts = here .. "/scripts",
    -- Set by lugh-session. Unset when Hyprland runs nested for development:
    -- then we never touch the systemd/D-Bus environment of the host session.
    session = os.getenv("LUGH_SESSION") == "1",
    home    = os.getenv("HOME") or "",
    runtime = os.getenv("XDG_RUNTIME_DIR") or "/tmp",
}
lugh.config_home = os.getenv("XDG_CONFIG_HOME") or (lugh.home .. "/.config")

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end
lugh.file_exists = file_exists

-- Load an optional file. Errors in it are reported by Hyprland like any other
-- config error, but a missing file is fine.
local function load_optional(path)
    if file_exists(path) then dofile(path) end
end

-- Default apps used by binds. Resolved when the key is pressed, so a user.lua
-- override (e.g. lugh.apps.terminal = "kitty") applies without rebinding.
lugh.apps = {
    terminal = "xdg-terminal-exec", -- falls back to foot, see 60-binds.lua
    files    = "pcmanfm-qt",        -- shown as "Files" (Phase 1 minimal profile)
    settings = "lugh-settings",     -- Phase 2; the control center opens until then
    tasks    = "lugh-tasks",        -- Lugh Tasks (later phase)
}

-- The parts, in order. low-power.lua is NOT in this list: it is applied on top
-- when the low-power flag is set (see below and scripts/low-power.sh).
local parts = {
    "00-env",
    "10-look",
    "20-animations",
    "30-performance",
    "40-input",
    "50-rules",
    "60-binds",
    "70-session",
}
for _, name in ipairs(parts) do
    dofile(here .. "/conf.d/" .. name .. ".lua")
end

-- Low-power profile (weak GPUs, power-saver): no blur, no shadows, no animations.
-- The shell switches it with scripts/low-power.sh (flag file + `hyprctl reload`).
lugh.low_power_flag = lugh.runtime .. "/lugh/hypr-low-power"
lugh.low_power = os.getenv("LUGH_LOW_POWER") == "1" or file_exists(lugh.low_power_flag)
if lugh.low_power then
    dofile(here .. "/conf.d/low-power.lua")
end

-- Files written by the shell / lugh-settingsd (mode presets, keybinding presets).
-- They must be Lua too. Loaded in a fixed order if present.
local generated = lugh.config_home .. "/lugh/generated"
load_optional(generated .. "/hyprland-mode.lua")
load_optional(generated .. "/hyprland-bindings.lua")

-- Per-user overrides, last so they win. Plain Lua with the full `hl` API.
load_optional(lugh.config_home .. "/lugh/hypr/user.lua")

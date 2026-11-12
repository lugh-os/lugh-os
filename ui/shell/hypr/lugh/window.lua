-- Window actions for Lugh-mode binds that Hyprland has no single dispatcher for:
-- snap to a screen half, minimize, cycle windows of the same app.

local M = {}

local GAP_OUT = 10 -- general.gaps_out
local GAP_IN  = 6  -- general.gaps_in

-- Space the shell's panel reserves at the bottom of a monitor, in layout
-- px. Hyprland's Lua API (0.55) exposes no reserved area, and the panel's
-- layer surface (namespace lugh-dock) is much taller than what it reserves
-- (transparent headroom for tooltips and menus), so it is computed like the
-- panel does (Panel.qml exclusiveZone): `[shell]` panelHeight (clamped to
-- 36..72, default 48) + 8 px margin when panelFloating (default true), 0
-- with panelAutohide. Read from lugh-shell.conf (QSettings INI) at most
-- once a second.
local PANEL_MARGIN = 8 -- Theme.space8
local reserve_cache = { at = -1, value = 0 }
function M.panel_reserve()
    local now = os.time()
    if reserve_cache.at == now then return reserve_cache.value end
    local f = io.open(lugh.config_home .. "/lugh/lugh-shell.conf", "r")
    local text = f and f:read("a") or ""
    if f then f:close() end
    local tb = require("lugh.titlebars")
    local function get(key) return tb.ini_value(text, "shell", key) end
    local value = 0
    if get("panelAutohide") ~= "true" then
        local h = tonumber(get("panelHeight") or "") or 48
        h = math.max(36, math.min(72, h))
        value = h + ((get("panelFloating") ~= "false") and PANEL_MARGIN or 0)
    end
    reserve_cache.at, reserve_cache.value = now, value
    return value
end

-- Usable area of a monitor in layout coordinates: the monitor minus the
-- panel's reserved strip at the bottom, on monitors where the panel is
-- mapped (lugh-dock layer). The shell has no top bar.
local function usable_area(mon)
    local scale = mon.scale or 1
    if scale <= 0 then scale = 1 end
    local w, h = mon.width / scale, mon.height / scale
    if mon.transform == 1 or mon.transform == 3 or mon.transform == 5 or mon.transform == 7 then
        w, h = h, w
    end
    local area = { x = mon.x, y = mon.y, w = w, h = h }

    for _, l in ipairs(hl.get_layers({ monitor = mon.name }) or {}) do
        if l.mapped and l.namespace == "lugh-dock" then
            local cut = M.panel_reserve()
            if cut > 0 and cut < area.h / 2 then area.h = area.h - cut end
            break
        end
    end
    return area
end
M.usable_area = usable_area

-- Snap the focused floating window to the left or right half. A tiled
-- window moves focus in that direction instead.
function M.snap(side)
    local win = hl.get_active_window()
    if not win then return end
    if not win.floating then
        hl.dispatch(hl.dsp.focus({ direction = side }))
        return
    end
    local mon = win.monitor or hl.get_active_monitor()
    if not mon then return end
    local a = usable_area(mon)
    -- Room for a server-side title bar above the window, as in M.clamp.
    local tb = lugh.titlebars
    local bar = (tb and tb.active) and tb.height or 0
    local w = math.floor((a.w - 2 * GAP_OUT - GAP_IN) / 2)
    local h = math.floor(a.h - bar - 2 * GAP_OUT)
    local x = a.x + GAP_OUT
    if side == "right" then x = x + w + GAP_IN end
    local y = a.y + bar + GAP_OUT
    hl.dispatch(hl.dsp.window.resize({ x = w, y = h, window = win }))
    hl.dispatch(hl.dsp.window.move({ x = math.floor(x), y = math.floor(y), window = win }))
end

-- A {x, y} pair from a window field: Hyprland gives vectors as {x=, y=}
-- (or as an array in some versions). nil when absent.
local function pair(v)
    if type(v) ~= "table" then return nil end
    local x, y = v.x or v[1], v.y or v[2]
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end

-- Keep a floating window inside the usable area of its monitor: shrink it
-- when it is bigger (minus the outer gaps), then center it when any edge is
-- outside. Windows that fit are left exactly where they are.
function M.clamp(win)
    if not win or not win.floating or win.pinned == true then return end
    -- fullscreen is a mode number in hyprctl (0 = none); accept a bool too.
    local fs = win.fullscreen
    if fs == true or (type(fs) == "number" and fs ~= 0) then return end
    local mon = win.monitor or hl.get_active_monitor()
    if not mon then return end
    local ww, wh = pair(win.size)
    local wx, wy = pair(win.at)
    if not ww or not wx then return end
    local a = usable_area(mon)
    -- Room for a server-side title bar above the window (hyprbars draws it
    -- outside the window box). Lua can't tell which windows have one, so
    -- every window keeps that much room at the top.
    local tb = lugh.titlebars
    local bar = (tb and tb.active) and tb.height or 0
    a = { x = a.x, y = a.y + bar, w = a.w, h = a.h - bar }
    local maxw = math.floor(a.w - 2 * GAP_OUT)
    local maxh = math.floor(a.h - 2 * GAP_OUT)
    if maxw < 200 or maxh < 150 then return end
    local nw, nh = math.min(ww, maxw), math.min(wh, maxh)
    if nw ~= ww or nh ~= wh then
        hl.dispatch(hl.dsp.window.resize({ x = nw, y = nh, window = win }))
    end
    local outside = wx < a.x or wy < a.y or wx + nw > a.x + a.w or wy + nh > a.y + a.h
    if outside or nw ~= ww or nh ~= wh then
        hl.dispatch(hl.dsp.window.move({
            x = math.floor(a.x + (a.w - nw) / 2),
            y = math.floor(a.y + (a.h - nh) / 2),
            window = win,
        }))
    end
end

-- Clamp every mapped floating window (after a monitor change or rescale).
function M.clamp_all()
    for _, w in ipairs(hl.get_windows({ mapped = true }) or {}) do
        if not w.hidden then M.clamp(w) end
    end
end

-- Hook the clamp to new windows and to monitor changes. Called once per
-- config load from 50-rules.lua.
function M.install_clamp()
    hl.on("window.open", function(win) M.clamp(win) end)
    hl.on("monitor.layout_changed", function() M.clamp_all() end)
    hl.on("monitor.added", function() M.clamp_all() end)
end

-- Minimize: Hyprland has no minimized state, so the window goes to a hidden
-- special workspace without following it. The dock restores it through the
-- shell's Hyprland adapter (move back to the current workspace + focus).
M.minimized_workspace = "special:minimized"
function M.minimize()
    local win = hl.get_active_window()
    if not win then return end
    hl.dispatch(hl.dsp.window.move({ workspace = M.minimized_workspace, follow = false, window = win }))
end

-- Alt+`: next window of the same app (same class), like macOS Cmd+`.
function M.cycle_same_app()
    local win = hl.get_active_window()
    if not win or win.class == "" then return end
    -- Compare classes in Lua (exact match) rather than through a class regex.
    local list, current = {}, nil
    for _, w in ipairs(hl.get_windows({ mapped = true }) or {}) do
        if w.class == win.class and not w.hidden then
            list[#list + 1] = w
            if w.address == win.address then current = #list end
        end
    end
    if #list < 2 or not current then return end
    local nxt = list[current % #list + 1]
    hl.dispatch(hl.dsp.focus({ window = nxt }))
    hl.dispatch(hl.dsp.window.bring_to_top())
end

-- Alt+Tab: next window on the workspace, raised (floating windows overlap).
function M.cycle(prev)
    hl.dispatch(hl.dsp.window.cycle_next({ prev = prev or false }))
    hl.dispatch(hl.dsp.window.bring_to_top())
end

lugh.window = M
return M

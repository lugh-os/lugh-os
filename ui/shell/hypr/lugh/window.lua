-- Window actions for Lugh-mode binds that Hyprland has no single dispatcher for:
-- snap to a screen half, minimize, cycle windows of the same app.

local M = {}

local GAP_OUT = 10 -- general.gaps_out
local GAP_IN  = 6  -- general.gaps_in

-- Usable area of a monitor in layout coordinates: the monitor minus the
-- shell's bar (top) and dock (bottom) when they are mapped on it.
-- Best effort: Hyprland's Lua API (0.55) exposes no reserved area, so the
-- bar/dock layer geometry is used instead.
local function usable_area(mon)
    local scale = mon.scale or 1
    local w, h = mon.width / scale, mon.height / scale
    if mon.transform == 1 or mon.transform == 3 or mon.transform == 5 or mon.transform == 7 then
        w, h = h, w
    end
    local area = { x = mon.x, y = mon.y, w = w, h = h }

    for _, l in ipairs(hl.get_layers({ monitor = mon.name }) or {}) do
        if l.mapped and l.namespace == "lugh-bar" and l.y <= area.y + 1 then
            local bottom = l.y + l.h
            area.h = area.h - (bottom - area.y)
            area.y = bottom
        elseif l.mapped and l.namespace == "lugh-dock" then
            local cut = (area.y + area.h) - l.y
            if cut > 0 and cut < area.h / 2 then area.h = area.h - cut end
        end
    end
    return area
end

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
    local w = math.floor((a.w - 2 * GAP_OUT - GAP_IN) / 2)
    local h = math.floor(a.h - 2 * GAP_OUT)
    local x = a.x + GAP_OUT
    if side == "right" then x = x + w + GAP_IN end
    local y = a.y + GAP_OUT
    hl.dispatch(hl.dsp.window.resize({ x = w, y = h, window = win }))
    hl.dispatch(hl.dsp.window.move({ x = math.floor(x), y = math.floor(y), window = win }))
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

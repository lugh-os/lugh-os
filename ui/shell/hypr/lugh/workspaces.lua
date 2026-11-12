-- Workspace grid for Lugh mode: virtual desktops laid out as rows × columns
-- (default 2 × 2 = workspaces 1–4), like KDE Plasma's virtual desktop grid.
--
-- Workspace ids are numbered row by row: with 2 × 2,
--     1 2
--     3 4
-- Super+Ctrl+arrows move to the neighbouring workspace, Super+Ctrl+Shift+arrows
-- take the focused window along, Super+scroll steps through the grid in order
-- (1 → 2 → 3 → 4, wrapping with workspaceWrap). Super+Tab opens the shell's
-- overview of the grid (lugh-shell, Overview.qml), which reads the same
-- settings and shows workspaces beyond the grid (made by apps, or left over
-- after the grid shrank) in an "Other workspaces" strip.
--
-- Grid size, in order of precedence:
--   1. user.lua: lugh.workspaces.set_grid(3, 3) (also re-creates the
--      persistent-workspace rules), or lugh.workspaces.rows / .cols / .wrap.
--   2. ~/.config/lugh/lugh-shell.conf, written by the shell's ShellSettings
--      (QSettings INI): [shell] workspaceRows=, workspaceCols=, workspaceWrap=.
--      Re-read when a bind is pressed, so a change in the shell applies at
--      once; the persistent-workspace rules follow then too (M.sync).
--   3. 2 × 2, no wrap.
--
-- Called from: conf.d/60-binds.lua, and `hyprctl dispatch 'lugh.workspaces.go("right")'`.

local M = {}

M.default_rows = 2
M.default_cols = 2
M.max_side = 4          -- the shell's settings allow 1 … 4 per side

-- User overrides (nil = follow the shell's settings file).
M.rows = nil
M.cols = nil
M.wrap = nil

-- Workspace animation used for grid moves. Must match the "workspaces" leaf in
-- conf.d/20-animations.lua (speed in deciseconds, curve name, default style).
M.anim = { speed = 2.8, curve = "lugh", default = "slidefade 20%" }

M.settings_file = (lugh and lugh.config_home or ((os.getenv("HOME") or "") .. "/.config"))
    .. "/lugh/lugh-shell.conf"

local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

-- Best-effort read of the [shell] section of the shell's QSettings INI.
-- Returns a table of raw string values (empty when the file is missing).
local function read_settings()
    local out = {}
    local f = io.open(M.settings_file, "r")
    if not f then return out end
    local section = ""
    for line in f:lines() do
        line = line:gsub("\r$", "")
        local sec = line:match("^%s*%[([^%]]+)%]%s*$")
        if sec then
            section = sec
        elseif section == "shell" then
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then out[k] = v:gsub('^"(.*)"$', "%1") end
        end
    end
    f:close()
    return out
end

local function to_int(v, default)
    local n = tonumber(v)
    if not n then return default end
    return clamp(math.floor(n), 1, M.max_side)
end

-- Current grid: rows, cols, wrap.
function M.grid()
    local s = (M.rows and M.cols and M.wrap ~= nil) and {} or read_settings()
    local rows = M.rows or to_int(s.workspaceRows, M.default_rows)
    local cols = M.cols or to_int(s.workspaceCols, M.default_cols)
    local wrap = M.wrap
    if wrap == nil then wrap = s.workspaceWrap == "true" end
    return rows, cols, wrap
end

function M.count()
    local rows, cols = M.grid()
    return rows * cols
end

-- Workspace id next to `id` in `dir` ("left" | "right" | "up" | "down"), or
-- nil at an edge (without wrap). Ids outside the grid snap back to its last
-- workspace first.
function M.neighbour(id, dir)
    local rows, cols, wrap = M.grid()
    local count = rows * cols
    id = clamp(id or 1, 1, count)
    local r = math.floor((id - 1) / cols)
    local c = (id - 1) % cols
    if dir == "left" then
        c = c - 1
    elseif dir == "right" then
        c = c + 1
    elseif dir == "up" then
        r = r - 1
    elseif dir == "down" then
        r = r + 1
    else
        return nil
    end
    if wrap then
        r = r % rows
        c = c % cols
    elseif r < 0 or r >= rows or c < 0 or c >= cols then
        return nil
    end
    local target = r * cols + c + 1
    if target == id then return nil end
    return target
end

-- Run `fn` with the workspace animation set to `style` (a full slide along
-- the move's axis), then put the default (M.anim.default) back. Hyprland
-- reads the style when the switch starts, so only this switch uses it.
-- Skipped in low-power mode (animations are off there) and if the API
-- refuses a runtime change.
local function with_style(style, fn)
    local can = not (lugh and lugh.low_power)
    local function set(s)
        return pcall(hl.animation, {
            leaf = "workspaces", enabled = true,
            speed = M.anim.speed, bezier = M.anim.curve, style = s,
        })
    end
    if can then can = set(style) end
    fn()
    if can then set(M.anim.default) end
end

local function style_for(dir)
    return (dir == "up" or dir == "down") and "slidevert" or "slide"
end

local function active_id()
    local ws = hl.get_active_workspace()
    if not ws or ws.special or ws.id == nil or ws.id < 1 then return nil end
    return ws.id
end

-- Workspace `d` steps (+1 / -1) from `id` in grid order (row by row), or nil
-- at the grid's end without wrap. From a workspace beyond the grid, both
-- directions lead back into it: to its last workspace (or, wrapping forward,
-- to the first).
function M.step(id, d)
    local _, _, wrap = M.grid()
    local count = M.count()
    id = id or 1
    if id > count then
        if d > 0 and wrap then return 1 end
        return count
    end
    local target = id + d
    if target < 1 or target > count then
        if not wrap then return nil end
        target = (target - 1) % count + 1
    end
    if target == id then return nil end
    return target
end

-- Super+scroll: next / previous workspace in grid order.
function M.scroll(d)
    M.sync()
    local id = active_id()
    if not id then return end
    local target = M.step(id, d)
    if not target then return end
    hl.dispatch(hl.dsp.focus({ workspace = target }))
end

-- Super+Ctrl+arrow: show the neighbouring workspace.
function M.go(dir)
    M.sync()
    local id = active_id()
    if not id then return end
    local target = M.neighbour(id, dir)
    if not target then return end
    with_style(style_for(dir), function()
        hl.dispatch(hl.dsp.focus({ workspace = target }))
    end)
end

-- Super+Ctrl+Shift+arrow: move the focused window there and follow it.
function M.move(dir)
    M.sync()
    local id = active_id()
    if not id then return end
    local target = M.neighbour(id, dir)
    if not target then return end
    local win = hl.get_active_window()
    with_style(style_for(dir), function()
        if win then
            hl.dispatch(hl.dsp.window.move({ workspace = target, follow = true, window = win }))
        else
            hl.dispatch(hl.dsp.focus({ workspace = target }))
        end
    end)
end

-- Ctrl+N: workspace N, if it is in the grid.
function M.focus(n)
    M.sync()
    if n < 1 or n > M.count() then return end
    hl.dispatch(hl.dsp.focus({ workspace = n }))
end

-- Ctrl+Shift+N: move the focused window to workspace N, if it is in the grid.
function M.send(n)
    M.sync()
    if n < 1 or n > M.count() then return end
    hl.dispatch(hl.dsp.window.move({ workspace = n }))
end

-- Keep the grid's workspaces alive while empty (workspace 1 has its own rule
-- in 50-rules.lua). Hyprland 0.55's hl.workspace_rule returns no handle, so a
-- rule can't be removed: when the grid shrinks, the workspaces past it are
-- re-registered with persistent = false, which merges into their rule
-- (WorkspaceRuleManager::replaceOrAdd) and the refresh it schedules
-- downgrades the live workspaces; a grown grid makes them persistent again.
-- Windows left on them stay where they are, reachable from the overview's
-- "Other workspaces" strip (Super+Tab).
-- M.persistent[id] = true while the last rule registered for id is persistent.
M.persistent = {}
M.applied = 0           -- grid size the rules were last made for
function M.apply()
    local count = M.count()
    for id = 2, count do
        if not M.persistent[id] then
            hl.workspace_rule({ workspace = tostring(id), persistent = true })
            M.persistent[id] = true
        end
    end
    for id in pairs(M.persistent) do
        if id > count and M.persistent[id] then
            hl.workspace_rule({ workspace = tostring(id), persistent = false })
            M.persistent[id] = false
        end
    end
    M.applied = count
end

-- Re-apply the rules if the grid size changed since (called by every bind).
function M.sync()
    if M.count() ~= M.applied then pcall(M.apply) end
end

-- user.lua: lugh.workspaces.set_grid(rows, cols [, wrap])
function M.set_grid(rows, cols, wrap)
    M.rows = clamp(math.floor(tonumber(rows) or M.default_rows), 1, M.max_side)
    M.cols = clamp(math.floor(tonumber(cols) or M.default_cols), 1, M.max_side)
    if wrap ~= nil then M.wrap = wrap and true or false end
    M.apply()
end

if lugh then lugh.workspaces = M end
return M

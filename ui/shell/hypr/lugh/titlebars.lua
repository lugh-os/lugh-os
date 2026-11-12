-- Server-side title bars (hyprbars plugin, package lugh-hyprbars).
--
-- Hyprland 0.55 draws no title bars of its own but answers every
-- xdg-decoration request with "server side", so apps that rely on the
-- compositor for their frame (foot, kitty, Alacritty, mpv, Qt 5 apps such as
-- VLC, Qt 6 apps, Chromium with "use system title bar", X11 apps without a
-- frame of their own) had none. Lugh ships hyprbars built for the exact
-- Hyprland in the archive, patched to put a bar only on those windows:
-- GTK 3/4/libadwaita, Firefox and apps that ask for client-side decorations
-- (Chromium's own frame, frameless Electron apps) keep drawing their own,
-- so no window ever gets two bars (packaging/lugh-hyprbars/src/README.Lugh).
--
-- Look: 26 px, the theme's surface2/text colours (light or dark, from
-- desktop.toml), Inter 10, buttons on the right in the order of
-- `[shell] titlebarButtons` (lugh-shell.conf, default minimize,maximize,close)
-- like GTK's button-layout; top corners follow the window rounding (14).
--
-- Guards: without the plugin file, with a plugin built for another Hyprland
-- version, or with LUGH_TITLEBARS=0 nothing is loaded and apps decorate
-- themselves as before (00-env.lua keeps Qt on client-side then). A plugin
-- that fails to load only shows a Hyprland notification; the session goes on.

local M = {}

M.plugin  = os.getenv("LUGH_HYPRBARS") or "/usr/lib/lugh/hyprland/hyprbars.so"
M.height  = 26
M.buttons = { "minimize", "maximize", "close" } -- left to right

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

-- Value of `key` in `[section]` of an INI/TOML-ish file text, unquoted.
local function ini_value(text, section, key)
    if not text then return nil end
    local current
    for line in text:gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")
        local s = line:match("^%[(.-)%]$")
        if s then
            current = s
        elseif current == section then
            local k, v = line:match("^([%w_.]+)%s*=%s*(.-)$")
            if k == key then
                v = v:gsub("%s+#.*$", "")
                return (v:gsub('^"(.*)"$', "%1"))
            end
        end
    end
    return nil
end
M.ini_value = ini_value

-- The shell's own settings (QSettings INI), cached per config load.
function M.shell_conf()
    if M._shell_conf == nil then
        M._shell_conf = read(lugh.config_home .. "/lugh/lugh-shell.conf") or false
    end
    return M._shell_conf or nil
end

-- True when the plugin is installed and was built for this Hyprland.
function M.available()
    if M._available ~= nil then return M._available end
    local ok = os.getenv("LUGH_TITLEBARS") ~= "0" and lugh.file_exists(M.plugin)
    if ok then
        -- Written at build time next to the plugin: the Hyprland version
        -- whose headers it was compiled against (the ABI must match).
        local built = read(M.plugin:gsub("%.so$", "") .. ".hyprland-version")
        built = built and built:match("^%s*(.-)%s*$")
        local running = hl.version and hl.version() or nil
        if built and running and built ~= running then ok = false end
    end
    M._available = ok
    return ok
end

-- Dark theme? `[appearance] theme` of desktop.toml (auto counts as light,
-- like the appearance service), else the shell's `[shell] dark`.
function M.dark()
    local theme = ini_value(read(lugh.config_home .. "/lugh/desktop.toml"), "appearance", "theme")
    if theme then return theme == "dark" end
    return ini_value(M.shell_conf(), "shell", "dark") == "true"
end

-- Buttons from `[shell] titlebarButtons`: known names, once each, in order.
function M.button_order()
    local raw = ini_value(M.shell_conf(), "shell", "titlebarButtons")
    local out, seen = {}, {}
    for b in (raw or ""):gmatch("[^,%s]+") do
        if (b == "minimize" or b == "maximize" or b == "close") and not seen[b] then
            seen[b] = true
            out[#out + 1] = b
        end
    end
    if #out == 0 then return M.buttons end
    return out
end

-- Colours: DESIGN-SYSTEM surface2 / text, buttons a hover-like overlay.
M.palette = {
    light = { bar = "rgb(EEECE7)", text = "rgb(1C1B19)", button = "rgba(0000001A)", inactive = "rgba(00000000)" },
    dark  = { bar = "rgb(262522)", text = "rgb(EDEBE6)", button = "rgba(FFFFFF1F)", inactive = "rgba(00000000)" },
}

local actions = {
    close    = { icon = "×", cmd = [[hyprctl dispatch 'hl.dsp.window.close()']] },
    maximize = { icon = "□", cmd = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })']] },
    minimize = { icon = "–", cmd = [[hyprctl dispatch 'lugh.window.minimize']] },
}

-- Register the plugin (Hyprland loads it after this parse, then parses the
-- config again: that second pass finds hl.plugin.hyprbars and styles it).
function M.load()
    if not M.available() or not (hl.plugin and hl.plugin.load) then return false end
    local ok, err = pcall(hl.plugin.load, M.plugin)
    if not ok then
        print("lugh: hyprbars not loaded: " .. tostring(err))
        return false
    end
    return true
end

-- Style the bars and add the buttons. Without the plugin (first pass,
-- --verify-config, not installed) this does nothing.
function M.configure()
    local hb = hl.plugin and hl.plugin.hyprbars
    if type(hb) ~= "table" or type(hb.add_button) ~= "function" then return false end
    local c = M.dark() and M.palette.dark or M.palette.light
    local ok, err = pcall(function()
        hl.config({
            plugin = {
                hyprbars = {
                    enabled                    = true,
                    bar_height                 = M.height,
                    bar_color                  = c.bar,
                    ["col.text"]               = c.text,
                    bar_text_size              = 10,
                    bar_text_font              = "Inter",
                    bar_text_align             = "center",
                    bar_title_enabled          = true,
                    bar_buttons_alignment      = "right",
                    bar_padding                = 8,
                    bar_button_padding         = 6,
                    bar_part_of_window         = true,
                    bar_precedence_over_border = true,
                    bar_blur                   = false,
                    icon_on_hover              = false,
                    inactive_button_color      = c.inactive,
                    on_double_click            = actions.maximize.cmd,
                },
            },
        })
        -- hyprbars places the first button rightmost.
        local order = M.button_order()
        for i = #order, 1, -1 do
            local a = actions[order[i]]
            hb.add_button({ bg_color = c.button, fg_color = c.text, size = 16, icon = a.icon, action = a.cmd })
        end
    end)
    if not ok then print("lugh: hyprbars style not applied: " .. tostring(err)) end
    return ok
end

-- Called once per config load from 10-look.lua.
function M.setup()
    M._shell_conf = nil
    M.active = M.load()
    if M.active then M.configure() end
end

lugh.titlebars = M
return M

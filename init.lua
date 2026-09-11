-- ~/.hammerspoon/init.lua
--
-- Control panel. The widget dashboard — order, enabled, thresholds, colours,
-- which display(s), per-display offsets, wallpaper folder, intervals — now lives
-- in a JSON file, seeded automatically on first run:
--
--     ~/.hammerspoon/widgets.json
--
-- Edit that file (or, later, the HTML editor) and reload Hammerspoon. This file
-- just wires modules together and binds hotkeys. Modules live in their own dirs:
--   widgets/   youtube_checker/   perapp/

local HOME = os.getenv("HOME")

--============================================================================
-- WIRING
--============================================================================

-- Garbage collector tuning. LuaJIT starts a new cycle once the heap grows to
-- `setpause`% of its post-collection size (default 200). Lower = tighter heap.
collectgarbage("setpause", 125)
collectgarbage("setstepmul", 200)

-- Widgets: load the dashboard from widgets.json and start the stack.
local widgets = require("widgets")
local cfg = widgets.loadConfig()
widgets.start(cfg)

-- Widgets dashboard editor (webview) — opened with Hyper+E
local widgetsEditor = require("widgets.editor")





-- NetLimiter: bandwidth throttling menubar app (dnctl + pfctl via osascript).
-- Only loaded/started when enabled from the widget dashboard editor checkbox.
local netlimiter = nil
if cfg.netlimiter and cfg.netlimiter.enabled then
    netlimiter = require("netlimiter").start()
end



--============================================================================
-- HOTKEYS
--============================================================================

local HYPER = { "cmd", "alt", "ctrl" }

--hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "k", function() perapp.toggleUI() end)
hs.hotkey.bind(HYPER, "2", function() widgets.toggleVisible() end)
hs.hotkey.bind(HYPER, "F1", function() widgets.rearm() end) -- restore widget clicks
hs.hotkey.bind(HYPER, "4", function()
    widgets.toggleVisible()
end)
--hs.hotkey.bind(HYPER, "5", function() netlimiter.togglePanel() end) -- NetLimiter panel

-- List connected displays (index / name / UUID) so you know what to put in
-- widgets.json (display / offsets / wallpaper.display).
hs.hotkey.bind(HYPER, "9", function() widgets.listDisplays() end)

-- Open the widgets dashboard editor.
hs.hotkey.bind(HYPER, "e", function() widgetsEditor.toggle() end)

-- Memory readout: show the Lua heap, force a full GC, report what was reclaimed.
hs.hotkey.bind(HYPER, "0", function()
    local before = collectgarbage("count") -- KB
    collectgarbage("collect")
    local after = collectgarbage("count")
    hs.alert.show(string.format(
        "Lua heap: %.2f MB\nafter GC: %.2f MB (freed %.2f MB)",
        before / 1024, after / 1024, (before - after) / 1024))
end)

-- Wallpaper hotkeys (only when the widget is enabled)
if cfg.widgets and cfg.widgets.wallpaper and cfg.widgets.wallpaper.enabled then
    local wp = widgets.instances.wallpaper
    hs.hotkey.bind({ "cmd" }, "`", function() wp.setRandom() end)
    hs.hotkey.bind({ "cmd", "alt" }, "`", function() wp.choose() end)
end

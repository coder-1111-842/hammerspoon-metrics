-- ~/.hammerspoon/widgets/init.lua
--
-- Shared widget registry + orchestrator.
--
--   * Registry: every canvas widget registers here so they can be shown/hidden,
--     pushed on top / behind windows, and re-armed together.
--   * Orchestrator: M.start(config) loads and starts each widget module,
--     handing it the slice of config it needs (interval, script path, …).
--
-- Individual widgets live in ~/.hammerspoon/widgets/<name>/init.lua and expose
-- a single function:  start(registry, opts) -> handles
-- They must not do any work at require-time (no side effects on load).

local M = {
    canvases  = {},        -- every registered canvas (for show/hide/level/rearm)
    instances = {},        -- name -> whatever the widget's start() returned
    handles   = {},        -- every start() return, kept so timers aren't GC'd
    screens   = {},        -- resolved target display(s) for the widgets
    screenOffsets = {},    -- screen:id() -> { x=, y= } nudge for that display
    onTop     = true,
    visible   = true,
    display   = "primary", -- which screen(s) the widgets are shown on
}

-- ── Config persistence ───────────────────────────────────────────────────────
-- The widget dashboard lives in widgets.json (seeded from M.defaults on first
-- run). loadConfig() returns it; saveConfig() writes it back (for the editor).
M.configPath = hs.configdir .. "/widgets.json"

local CFGHOME = os.getenv("HOME")
local HEX_WHITE, HEX_RED, HEX_BLUE = "#ffffff", "#ff0000", "#0000ff"

-- Generic fallback config (kept environment-neutral: primary display, no
-- offsets). Real per-user settings live in widgets.json.
M.defaults = {
    layout     = { x = 20, baseY = 675, step = 55, h = 48 },
    display    = "primary",
    offsets    = {},
    pmUsage    = { script = hs.configdir .. "/scripts/pm-usage.sh", interval = 5 },
    -- Whether the NetLimiter menubar module is loaded at all. Toggled from
    -- the dashboard editor checkbox.
    netlimiter = { enabled = false },
    widgets = {
        cpu        = { enabled = true, order = 1, threshold = 80,
                       colors = { normal = HEX_WHITE, alert = HEX_RED } },
        gpu        = { enabled = true, order = 2, threshold = 80,
                       colors = { normal = HEX_WHITE, alert = HEX_RED } },
        ssd        = { enabled = true, order = 3, interval = 10,
                       script = hs.configdir .. "/scripts/usedSSDSpace.sh",
                       threshold = 70, colors = { normal = HEX_WHITE, alert = HEX_RED } },
        ram        = { enabled = true, order = 4, interval = 3,
                       script = hs.configdir .. "/scripts/ramSize.sh",
                       threshold = 75, colors = { normal = HEX_WHITE, alert = HEX_RED } },
        net        = { enabled = true, order = 5, interval = 2,
                       colors = { normal = HEX_WHITE, down = HEX_RED, up = HEX_BLUE } },
        --activeapps = { enabled = true, order = 6, interval = 2 },
        wallpaper  = { enabled = true, order = 7, interval = 90,
                       dir = CFGHOME .. "/Pictures", display = "all" },
        date       = { enabled = true, order = 8, interval = 60,
                       script = hs.configdir .. "/scripts/dateTime.sh" },
    },
}

function M.saveConfig(cfg)
    return hs.json.write(cfg or M.defaults, M.configPath, true, true) -- pretty, replace
end

function M.loadConfig()
    local data = hs.json.read(M.configPath)
    if type(data) ~= "table" then
        M.saveConfig(M.defaults) -- seed the file so it can be hand-edited
        return M.defaults
    end
    -- Fill any missing top-level section from defaults (partial files stay valid).
    for k, v in pairs(M.defaults) do
        if data[k] == nil then data[k] = v end
    end
    return data
end

-- ── Path resolution ──────────────────────────────────────────────────────────
-- Lets widgets.json stay portable across machines/usernames (so it can be
-- committed to a repo without baking in a home directory):
--   "/abs/path"  -> unchanged (already absolute)
--   "~/foo"      -> $HOME/foo
--   "foo/bar"    -> hs.configdir .. "/foo/bar"  (relative to ~/.hammerspoon)
function M.resolvePath(p)
    if type(p) ~= "string" or p == "" then return p end
    if p:sub(1, 1) == "/" then
        return p
    elseif p:sub(1, 2) == "~/" then
        return CFGHOME .. p:sub(2)
    else
        return hs.configdir .. "/" .. p
    end
end

-- ── Registry API ──────────────────────────────────────────────────────────────

function M.register(canvas)
    table.insert(M.canvases, canvas)
end

function M.toggleAll()
    M.onTop = not M.onTop
    local level = M.onTop and hs.canvas.windowLevels.floating
        or hs.canvas.windowLevels.desktopIcon
    for _, c in ipairs(M.canvases) do
        c:level(level)
    end
end

function M.toggleVisible()
    M.visible = not M.visible
    for _, c in ipairs(M.canvases) do
        if M.visible then c:show() else c:hide() end
    end
end

-- Re-establish mouse tracking for every registered canvas.
--
-- hs.canvas occasionally loses its invisible click-tracking areas across
-- system sleep/wake, display reconfiguration, and Space changes: the widget
-- still *draws* fine, but clicks stop registering. Reassigning the frame
-- forces the underlying tracking area to rebuild, which restores clicks.
function M.rearm()
    local level = M.onTop and hs.canvas.windowLevels.floating
        or hs.canvas.windowLevels.desktopIcon
    for _, c in ipairs(M.canvases) do
        c:frame(c:frame()) -- reassign current frame -> rebuilds tracking area
        c:level(level)
        if M.visible then c:show() end
    end
end

-- Re-arm after the events known to break canvas tracking. The short delay
-- lets the OS settle (displays wake, Spaces switch) before we rebuild.
M.sleepWatcher = hs.caffeinate.watcher.new(function(event)
    local w = hs.caffeinate.watcher
    if event == w.systemDidWake
        or event == w.screensDidWake
        or event == w.screensDidUnlock
        or event == w.sessionDidBecomeActive then
        hs.timer.doAfter(1, M.rearm)
    end
end)
M.sleepWatcher:start()

-- Snapshot of currently connected screens (by id), used to tell a real
-- connect/disconnect apart from other reconfiguration events (resolution
-- change, arrangement change, …) that hs.screen.watcher also fires for.
local function screenIdSet()
    local ids = {}
    for _, s in ipairs(hs.screen.allScreens()) do ids[s:id()] = true end
    return ids
end

local function sameScreenSet(a, b)
    for id in pairs(a) do if not b[id] then return false end end
    for id in pairs(b) do if not a[id] then return false end end
    return true
end

M._lastScreenIDs    = screenIdSet()
M._screenChangeTimer = nil

-- hs.screen.watcher fires repeatedly (and mid-transition) while a display is
-- being connected/disconnected, so debounce: only look once things settle.
M.screenWatcher = hs.screen.watcher.new(function()
    if M._screenChangeTimer then M._screenChangeTimer:stop() end
    M._screenChangeTimer = hs.timer.doAfter(1, function()
        local ids     = screenIdSet()
        local changed = not sameScreenSet(ids, M._lastScreenIDs)
        M._lastScreenIDs = ids

        if changed then
            -- A display was added/removed. Canvas positions were computed
            -- from screen frames at start time (e.g. the old primary frame),
            -- which can go stale once the display set changes -- that's what
            -- makes widgets look duplicated/mangled after unplugging a
            -- secondary display. A full reload cleanly rebuilds everything
            -- against the *current* screens (M.resolveScreens/M.start fall
            -- back to the primary display alone when a configured display is
            -- no longer present).
            hs.reload()
        else
            M.rearm()
        end
    end)
end)
M.screenWatcher:start()

-- Space changes can also drop tracking. hs.spaces.watcher isn't present in
-- every Hammerspoon version, so guard it to avoid breaking the config load.
if hs.spaces and hs.spaces.watcher then
    M.spaceWatcher = hs.spaces.watcher.new(function()
        hs.timer.doAfter(0.5, M.rearm)
    end)
    M.spaceWatcher:start()
end

-- ── Screen resolution ─────────────────────────────────────────────────────────

-- Resolve a display selector into a list of hs.screen objects. Accepts:
--   "all"      -> every connected display
--   "primary"  -> the main display only
--   <number>   -> the Nth display from hs.screen.allScreens()
--   <string>   -> case-insensitive substring of the display name, falling back
--                 to hs.screen.find (so a UUID also works)
--   <table>    -> a list of any of the above; the union of all matches
-- Returns a de-duplicated list (possibly empty).
function M.resolveScreens(sel)
    local acc, seen = {}, {}
    local function add(s)
        if s and not seen[s:id()] then seen[s:id()] = true; acc[#acc + 1] = s end
    end
    local function one(v)
        if v == "all" then
            for _, s in ipairs(hs.screen.allScreens()) do add(s) end
        elseif v == "primary" then
            add(hs.screen.primaryScreen())
        elseif type(v) == "number" then
            add(hs.screen.allScreens()[v])
        elseif type(v) == "string" then
            local needle, matched = v:lower(), false
            for _, s in ipairs(hs.screen.allScreens()) do
                if ((s:name() or ""):lower()):find(needle, 1, true) then add(s); matched = true end
            end
            if not matched then add(hs.screen.find(v)) end -- id / UUID / geometry
        end
    end
    if type(sel) == "table" then
        for _, v in ipairs(sel) do one(v) end
    else
        one(sel)
    end
    return acc
end

-- Discovery helper: list every connected display's index, name and UUID so you
-- know exactly what to put in the `display` config. Bound to a hotkey in init.
function M.listDisplays()
    local lines = {}
    for i, s in ipairs(hs.screen.allScreens()) do
        lines[#lines + 1] = string.format("%d: %s", i, s:name() or "?")
        lines[#lines + 1] = "   UUID " .. (s:getUUID() or "?")
    end
    local text = table.concat(lines, "\n")
    print("[widgets] displays:\n" .. text)
    hs.alert.show(text, 5)
    return text
end

-- Create one canvas per target display for a widget.
--
-- `base` is the canvas rect in primary-display coordinates ({x,y,w,h}); it is
-- translated onto each target screen. `build(canvas)` configures a single canvas
-- (level, behaviour, elements, mouseCallback, :show()). Returns the list of
-- canvases, all registered for show/hide/rearm.
--
-- This lets a widget poll ONCE and update every mirrored canvas, instead of
-- running an independent poll per display.
function M.mirror(base, build)
    local list = {}
    local pf = hs.screen.primaryScreen():frame()
    for _, screen in ipairs(M.screens) do
        local sf  = screen:frame()
        local off = M.screenOffsets[screen:id()] or { x = 0, y = 0 }
        local c = hs.canvas.new({
            x = base.x + (sf.x - pf.x) + off.x,
            y = base.y + (sf.y - pf.y) + off.y,
            w = base.w,
            h = base.h,
        })
        build(c)
        M.register(c)
        list[#list + 1] = c
    end
    return list
end

-- ── Colour helpers ───────────────────────────────────────────────────────────

-- "#rrggbb" or "#rrggbbaa" -> Hammerspoon colour table.
local function hexToColor(hex)
    hex = tostring(hex):gsub("^#", "")
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    local a = (#hex >= 8) and (tonumber(hex:sub(7, 8), 16) or 255) or 255
    return { red = r / 255, green = g / 255, blue = b / 255, alpha = a / 255 }
end

-- Convert every hex string in a { name = "#rrggbb", … } table to HS colours.
local function convertColors(colors)
    if type(colors) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(colors) do
        out[k] = (type(v) == "string") and hexToColor(v) or v
    end
    return out
end

-- ── Orchestrator ────────────────────────────────────────────────────────────

-- config = {
--   display = "primary" | "all" | <n> | "<name/UUID>" | { … },  -- screen(s) for the WIDGETS
--   offsets = { ["<selector>"] = { x=, y= }, … },              -- per-display nudge (+y = down)
--   layout  = { x=, baseY=, step=, h= },                       -- stack geometry
--   widgets = { <name> = { enabled=, order=, interval=, script=, … }, … },
--   pmUsage = { script=, interval= },                          -- shared cpu/gpu sampler
-- }
function M.start(config)
    config       = config or {}
    local wcfg   = config.widgets or {}
    local layout = config.layout or {}
    local x0     = layout.x or 20
    local baseY  = layout.baseY or 675
    local step   = layout.step or 55
    local hh     = layout.h or 48
    M.display    = config.display or "primary"

    -- Which display(s) to render the widgets on. Widgets read M.screens (via
    -- M.mirror) to place one canvas on each.
    M.screens = M.resolveScreens(M.display)
    if #M.screens == 0 then M.screens = { hs.screen.primaryScreen() } end

    -- Per-display nudges. config.offsets maps a display selector -> { x=, y= };
    -- resolve each to concrete screens so M.mirror can look up by screen id.
    -- Target screens default to no offset; primary stays put unless listed.
    M.screenOffsets = {}
    for _, s in ipairs(M.screens) do
        M.screenOffsets[s:id()] = { x = 0, y = 0 }
    end
    for sel, off in pairs(config.offsets or {}) do
        for _, s in ipairs(M.resolveScreens(sel)) do
            if M.screenOffsets[s:id()] then -- only nudge displays we actually render on
                M.screenOffsets[s:id()] = { x = off.x or 0, y = off.y or 0 }
            end
        end
    end

    -- Shared powermetrics provider: one `sudo powermetrics` sampler feeding the
    -- cpu + gpu widgets (instead of each polling it separately).
    local cpuOn = wcfg.cpu and wcfg.cpu.enabled
    local gpuOn = wcfg.gpu and wcfg.gpu.enabled
    if config.pmUsage and config.pmUsage.script and (cpuOn or gpuOn) then
        require("widgets.pmusage").start({
            cmd      = "sudo " .. M.resolvePath(config.pmUsage.script),
            interval = config.pmUsage.interval or 5,
        })
    end

    -- Collect enabled widgets and order them top -> bottom (ties broken by name).
    local ordered = {}
    for name, cfg in pairs(wcfg) do
        if cfg.enabled then ordered[#ordered + 1] = { name = name, cfg = cfg } end
    end
    table.sort(ordered, function(a, b)
        local oa, ob = a.cfg.order or math.huge, b.cfg.order or math.huge
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)

    -- Start each widget once, at its computed slot. A widget may override its
    -- slot with an explicit `y` in its config. Its whole config is forwarded as
    -- opts (plus x/y/h) so the widget reads whatever fields it needs.
    for rank, item in ipairs(ordered) do
        local cfg  = item.cfg
        local opts = {}
        for k, v in pairs(cfg) do opts[k] = v end
        opts.x = x0
        opts.y = cfg.y or (baseY + step * (rank - 1))
        opts.h = hh
        if cfg.colors then opts.colors = convertColors(cfg.colors) end
        if opts.script then opts.script = M.resolvePath(opts.script) end
        if opts.dir    then opts.dir    = M.resolvePath(opts.dir) end
        local inst = require("widgets." .. item.name).start(M, opts)
        M.instances[item.name] = inst
        M.handles[#M.handles + 1] = inst
    end

    return M
end

return M

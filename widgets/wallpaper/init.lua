-- ~/.hammerspoon/widgets/wallpaper/init.lua
--
-- Wallpaper widget + wallpaper control.
--   * Picks a random image from a directory and applies it to the configured
--     display(s) (M.display = which screen(s) get the IMAGE).
--   * Auto-rotates on a timer; click the widget to play/pause the rotation.
--   * M.setRandom() / M.choose() are exposed so init.lua can bind hotkeys.
--
-- The widget CANVAS is mirrored onto every target display via widgets.mirror,
-- so all copies share one timer and one state.

local M = {}

-- State
local canvases    = {}    -- one canvas per display the widget is mirrored on
local registry             -- widgets registry (for resolveScreens); set in start()
local dir                  -- wallpaper source directory
local currentName = ""     -- label shown on the widget
M.timerMode       = false
M.timer           = nil  -- kept referenced so it isn't GC'd
M.interval        = 90
M.display         = "all" -- which screen(s) get the IMAGE (independent of the
                          -- widget-position display handled by the registry)

-- Which screen(s) the wallpaper IMAGE should be applied to. Uses the shared
-- registry resolver; falls back to all screens if nothing matches.
local function imageScreens()
    local ss = registry and registry.resolveScreens(M.display) or {}
    if #ss == 0 then
        hs.alert.show("Wallpaper: display " .. hs.inspect(M.display) ..
            " not found — using all screens")
        ss = hs.screen.allScreens()
    end
    return ss
end

local function render()
    --   \u{25B6} (play)   \u{23F8} (pause)
    local mode = M.timerMode and "\u{25B6}" or "\u{23F8}"
    for _, cv in ipairs(canvases) do
        if M.timerMode == false then
            cv[2].text = currentName .. "\n" .. mode
        else
            cv[2].text = currentName .. "\n" .. mode .. "   " .. M.interval .. " seconds"
        end
    end
end

local function updateName(filename)
    local MAX = 20
    if #filename <= MAX then
        currentName = filename                        -- fits WITH extension
    else
        local base = filename:gsub("%.[^%.]+$", "")   -- too long: drop extension
        if #base > MAX then base = base:sub(1, MAX) end -- still too long: hard-cut to 20
        currentName = base
    end
    render()
end

-- Apply a random image from `dir` to the configured display(s).
function M.setRandom()
    local files = {}
    for file in hs.fs.dir(dir) do
        if file:match("%.jpg$") or file:match("%.png$") or file:match("%.jpeg$") then
            table.insert(files, file)
        end
    end
    if #files == 0 then
        hs.alert.show("No wallpapers found in: " .. dir)
        return
    end
    local choice   = files[math.random(#files)]
    local fullPath = dir .. "/" .. choice
    for _, screen in ipairs(imageScreens()) do
        screen:desktopImageURL("file://" .. fullPath)
    end
    updateName(choice)
end

-- Pick a wallpaper via the native file chooser.
function M.choose()
    local result = hs.dialog.chooseFileOrFolder(
        "Choose a wallpaper image",
        os.getenv("HOME") .. "/Pictures",
        true,  -- canChooseFiles
        false, -- canChooseDirectories
        false, -- allowsMultipleSelection
        { "public.image" }
    )
    if result and result["1"] then
        local path = result["1"]
        for _, screen in ipairs(imageScreens()) do
            screen:desktopImageURL("file://" .. path)
        end
        updateName(path:match("([^/]+)$") or path)
    end
end

-- Timer control
function M.startTimer()
    if M.timer then M.timer:stop() end
    M.timer     = hs.timer.doEvery(M.interval, M.setRandom)
    M.timerMode = true
    render()
end

function M.stopTimer()
    if M.timer then
        M.timer:stop()
        M.timer = nil
    end
    M.timerMode = false
    render()
end

function M.toggleTimer()
    if M.timerMode then M.stopTimer() else M.startTimer() end
end

function M.start(widgets, opts)
    registry   = widgets
    dir        = opts.dir
    M.interval = opts.interval or 90
    M.display  = opts.display or "all"

    local white = { white = 1, alpha = 1 }

    canvases = widgets.mirror({ x = opts.x or 20, y = opts.y or 1005, w = 160, h = opts.h or 48 }, function(c)
        c:level(hs.canvas.windowLevels.floating)
        c:behavior({ "canJoinAllSpaces", "stationary" })
        c:clickActivating(false)
        c[1] = {
            type             = "rectangle",
            action           = "fill",
            fillColor        = { alpha = 0.35, white = 0 },
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
            trackMouseUp     = true, -- receive clicks to toggle timer mode
        }
        c[2] = { type = "text", frame = { x = 10, y = 10, w = 170, h = 36 }, textSize = 11, textColor = white }
        c:show()
        -- Click any copy to toggle auto-rotate on/off.
        c:mouseCallback(function(_, event)
            if event == "mouseUp" then M.toggleTimer() end
        end)
    end)

    math.randomseed(os.time())
    --M.setRandom()  -- (left off: start without changing the current image)
    M.stopTimer()    -- start paused

    return M
end

return M

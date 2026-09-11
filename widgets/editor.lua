-- ~/.hammerspoon/widgets/editor.lua
--
-- Webview editor for widgets.json:
--   * drag to reorder the stack
--   * enable / disable each widget
--   * edit thresholds, colours (pickers), intervals
--   * pick the wallpaper folder (native chooser)
--   * edit layout (x / baseY / step / h)
--
-- "Save & Apply" writes widgets.json via the registry and reloads Hammerspoon
-- (a clean rebuild). Display / offsets / pmUsage round-trip untouched.

local M = {}

local HANDLER  = "widgetsEditor"
local registry = require("widgets")

local state = { webview = nil, ucc = nil, visible = false }

local function moduleDir()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:match("^(.*)/[^/]+$") or "."
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

-- Push the current config into the page (called when the page says it's ready).
local function pushConfig()
    if not state.webview then return end
    local json = hs.json.encode(registry.loadConfig())
    state.webview:evaluateJavaScript("window.loadConfig(" .. json .. ")")
end

-- Native folder chooser -> hand the path back to the page's field.
local function chooseFolder(key)
    local choice = hs.dialog.chooseFileOrFolder(
        "Choose folder", os.getenv("HOME") .. "/Pictures",
        false, true, false)
    if choice and choice["1"] and state.webview then
        local path = choice["1"]:gsub("\\", "\\\\"):gsub("'", "\\'")
        state.webview:evaluateJavaScript(
            "window.setFolder('" .. tostring(key) .. "', '" .. path .. "')")
    end
end

local function handleMessage(msg)
    local body   = (type(msg) == "table" and msg.body) or {}
    local action = body.action
    if action == "ready" then
        pushConfig()
    elseif action == "chooseFolder" then
        chooseFolder(body.key)
    elseif action == "save" then
        if body.config then
            registry.saveConfig(body.config)
            hs.reload() -- clean rebuild from the new widgets.json
        end
    elseif action == "close" then
        M.hide()
    end
end

function M.show()
    if not state.webview then
        state.ucc = hs.webview.usercontent.new(HANDLER)
        state.ucc:setCallback(handleMessage)

        local f = hs.screen.mainScreen():frame()
        local w, h = 580, 700
        local rect = { x = f.x + (f.w - w) / 2, y = f.y + (f.h - h) / 2, w = w, h = h }

        local wv = hs.webview.new(rect, { developerExtrasEnabled = false }, state.ucc)
        local wm = hs.webview.windowMasks
        -- No `resizable`: keeps the dashboard a fixed size (dragging the
        -- corners otherwise breaks the fixed-px HTML layout) and drops the
        -- green maximize/zoom button, which only appears when resizable.
        wv:windowStyle(wm.titled + wm.closable)
        wv:allowTextEntry(true)
        wv:closeOnEscape(true)
        wv:deleteOnClose(false)
        wv:windowCallback(function(action, webview, focused)
            if action == "closing" then
                state.visible = false
            elseif action == "focusChange" and focused == false then
                -- Hammerspoon runs as an accessory app, so macOS doesn't
                -- automatically drop this panel behind whatever window the
                -- user just clicked (as it would for a normal app's window).
                -- Order it to the back of its window level ourselves so it
                -- behaves like any other window instead of always-on-top.
                --
                -- Guard on state.visible: focusChange(false) also fires (async,
                -- on the next run loop tick) right after the window is closed
                -- or hidden. orderWindow:relativeTo: (which orderBelow wraps)
                -- re-shows an already-hidden window as a side effect of
                -- ordering it, so without this guard, closing the dashboard
                -- would immediately pop it back on screen.
                if state.visible then webview:orderBelow() end
            end
        end)
        wv:html(readFile(moduleDir() .. "/editor.html") or "<h1>editor.html missing</h1>")
        state.webview = wv
    end
    -- No bringToFront(true): that pins the window at NSScreenSaverWindowLevel,
    -- above literally everything (including other apps' windows, the Dock,
    -- and fullscreen spaces) forever after, which is why it never yielded to
    -- whatever window was clicked next. Showing it is enough: :show() already
    -- orders it to the front of its normal window level.
    state.webview:show()
    state.visible = true
    -- config is pushed when the page posts { action = "ready" }
end

function M.hide()
    if state.webview then state.webview:hide() end
    state.visible = false
end

function M.toggle()
    if state.visible then M.hide() else M.show() end
end

return M

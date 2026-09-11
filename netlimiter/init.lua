-- ~/.hammerspoon/netlimiter/init.lua
--
-- NetLimiter, ported from the SwiftUI app to Hammerspoon.
--
-- It throttles all network bandwidth using macOS's built-in BSD traffic
-- shaping tools (the same ones Apple's Network Link Conditioner uses):
--
--   dnctl  (dummynet)  - creates bandwidth-limited pipes
--   pfctl  (pf)        - routes all TCP/UDP traffic through those pipes
--
-- How it works (identical strategy to the original Swift NetworkLimiter):
--   * enable() builds one shell script that configures the pipes/rules, writes
--     its own PID to a file as a "success" signal, then sits in a polling loop
--     reading a command file every 0.2s.
--   * The whole script is run ONCE via `osascript ... with administrator
--     privileges`, so the admin password is asked for exactly once per session.
--   * Later speed changes don't re-prompt: we just write a new `dnctl` command
--     into /tmp/netlimiter_cmd and the still-running privileged loop eval's it.
--   * disable() writes "EXIT", which makes the loop restore /etc/pf.conf, flush
--     dnctl, clean up and exit.
--
-- The Swift version needed DispatchQueue to keep the blocking osascript call off
-- the UI thread and to hop results back to the main thread. Hammerspoon removes
-- all of that: hs.task launches osascript asynchronously and its callbacks
-- already run on the main Lua thread, so there is no thread juggling here.
--
-- UI: a menubar item (quick toggle + presets) plus an HTML control panel
-- rendered in an hs.webview (see ui.html).

local M = {}

----------------------------------------------------------------------
-- Config / constants
----------------------------------------------------------------------
M.cmdFile    = "/tmp/netlimiter_cmd"
M.pidFile    = "/tmp/netlimiter_pid"
M.configPath = hs.configdir .. "/netlimiter.json"
M.htmlPath   = hs.configdir .. "/netlimiter/ui.html"

-- Quick presets, matching the original app. { label, kbps }
local PRESETS = {
  { "512K",  512 },
  { "1M",    1000 },
  { "10M",   10000 },
  { "100M",  100000 },
  { "500M",  500000 },
  { "1G",    1000000 },
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
M.enabled      = false
M.busy         = false          -- true while waiting on the auth prompt
M.downloadKbps = 100000
M.uploadKbps   = 100000
M.lastError    = nil

M.bar          = nil            -- hs.menubar
M.webview      = nil            -- hs.webview control panel
M.ucc          = nil            -- hs.webview.usercontent controller
M.helperTask   = nil            -- the running osascript hs.task
M._pollTimer   = nil            -- polls for the pid file after enable()
M._attempts    = 0

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function fileExists(p)
  return hs.fs.attributes(p) ~= nil
end

local function readFile(p)
  local f = io.open(p, "r")
  if not f then return "" end
  local c = f:read("*a")
  f:close()
  return c
end

-- Escape a string for embedding inside an AppleScript "..." literal.
local function aesc(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  return s
end

-- formatBandwidth() from the Swift version: kbps -> dnctl bandwidth token.
local function fmtBw(kbps)
  kbps = math.floor(kbps)
  if kbps >= 1000 then
    return tostring(math.floor(kbps / 1000)) .. "Mbit/s"
  end
  return tostring(kbps) .. "Kbit/s"
end

-- Human-readable speed for the menu / status (formatSpeed() in the Swift UI).
local function fmtSpeed(kbps)
  if kbps >= 1000000 then
    return string.format("%.2f Gbps", kbps / 1000000)
  elseif kbps >= 1000 then
    return string.format("%.1f Mbps", kbps / 1000)
  end
  return string.format("%.0f Kbps", kbps)
end

----------------------------------------------------------------------
-- Persistence (remember last speeds across reloads)
----------------------------------------------------------------------
function M.load()
  local d = hs.json.read(M.configPath)
  if type(d) == "table" then
    M.downloadKbps = tonumber(d.download) or M.downloadKbps
    M.uploadKbps   = tonumber(d.upload)   or M.uploadKbps
  end
end

function M.save()
  hs.json.write({ download = M.downloadKbps, upload = M.uploadKbps },
    M.configPath, true, true)
end

----------------------------------------------------------------------
-- The privileged helper shell script (verbatim logic from Swift)
----------------------------------------------------------------------
-- Pipe 1 = download (in), Pipe 2 = upload (out).
local function buildHelper(dlBw, ulBw)
  return table.concat({
    "/usr/sbin/dnctl pipe 1 config bw " .. dlBw,
    "/usr/sbin/dnctl pipe 2 config bw " .. ulBw,
    "echo 'dummynet in proto { tcp, udp } from any to any pipe 1",
    "dummynet out proto { tcp, udp } from any to any pipe 2' | /sbin/pfctl -f -",
    "/sbin/pfctl -e 2>/dev/null || true",
    "echo $$ > " .. M.pidFile,
    "while true; do",
    "    if [ -s " .. M.cmdFile .. " ]; then",
    "        cmd=$(cat " .. M.cmdFile .. ")",
    "        > " .. M.cmdFile,
    '        if [ "$cmd" = "EXIT" ]; then',
    "            /sbin/pfctl -f /etc/pf.conf 2>/dev/null || true",
    "            /usr/sbin/dnctl -q flush",
    "            rm -f " .. M.cmdFile .. " " .. M.pidFile,
    "            exit 0",
    "        fi",
    '        eval "$cmd" 2>/dev/null',
    "    fi",
    "    sleep 0.2",
    "done",
  }, "\n")
end

----------------------------------------------------------------------
-- File-based command channel to the running privileged loop
----------------------------------------------------------------------
-- Atomic write: write to a temp file then rename, so the loop never reads a
-- half-written command (matches Swift's `write(atomically: true)`).
function M.sendCommand(cmd)
  local tmp = M.cmdFile .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(cmd)
  f:close()
  os.rename(tmp, M.cmdFile)
end

----------------------------------------------------------------------
-- Enable / disable / update
----------------------------------------------------------------------
function M.enable()
  if M.enabled or M.busy then return end

  local dlBw = fmtBw(M.downloadKbps)
  local ulBw = fmtBw(M.uploadKbps)

  -- Clean up any previous state, then create an empty command file.
  os.remove(M.cmdFile)
  os.remove(M.pidFile)
  local f = io.open(M.cmdFile, "w")
  if f then f:close() end

  local apple = 'do shell script "' .. aesc(buildHelper(dlBw, ulBw))
    .. '" with administrator privileges'

  M.busy = true
  M.lastError = nil
  M.refresh()
  M.pushState()

  -- Launch osascript asynchronously. Because the helper loops forever, this
  -- task's completion callback only fires on disable / EXIT / auth-cancel.
  M.helperTask = hs.task.new("/usr/bin/osascript", function(_code, _out, _err)
    M.helperTask = nil
    -- If it exited before we ever confirmed success, the user likely cancelled.
    if M.busy and not M.enabled then
      if M._pollTimer then M._pollTimer:stop(); M._pollTimer = nil end
      M.busy = false
      M.lastError = "Authentication cancelled"
      M.refresh()
      M.pushState()
    end
  end, { "-e", apple })
  M.helperTask:start()

  -- Wait (non-blocking) for the helper to write its PID = success signal.
  --
  -- IMPORTANT: do NOT impose a short wall-clock timeout here. This poll starts
  -- the moment osascript is launched, which is *while the admin password dialog
  -- is still open*. Entering a password routinely takes longer than a couple of
  -- seconds, so a short cap would fire mid-typing, stop polling, and then miss
  -- the PID file once the helper finally runs -- leaving the connection limited
  -- but the UI stuck on OFF. Genuine failure (the user cancelling the auth
  -- dialog) is detected by the osascript task exiting, handled in the task
  -- callback above. The large cap below is only a safety valve so the timer
  -- can't run forever.
  M._attempts = 0
  if M._pollTimer then M._pollTimer:stop() end
  M._pollTimer = hs.timer.doEvery(0.1, function()
    M._attempts = M._attempts + 1
    if fileExists(M.pidFile) then
      M._pollTimer:stop(); M._pollTimer = nil
      M.enabled = true
      M.busy = false
      M.lastError = nil
      M.save()
      M.refresh()
      M.pushState()
    elseif M._attempts >= 3000 then    -- ~5 min safety valve only
      M._pollTimer:stop(); M._pollTimer = nil
      if not M.enabled then
        M.busy = false
        M.refresh()
        M.pushState()
      end
    end
  end)
end

function M.disable()
  M.sendCommand("EXIT")
  M.enabled = false
  M.busy = false
  M.lastError = nil
  M.refresh()
  M.pushState()

  -- Give the loop time to clean up gracefully, then force-terminate.
  hs.timer.doAfter(1.0, function()
    if M.helperTask and M.helperTask:isRunning() then
      M.helperTask:terminate()
    end
    M.helperTask = nil
    os.remove(M.cmdFile)
    os.remove(M.pidFile)
  end)
end

-- Live-update both pipes without re-prompting for a password.
function M.updateBoth()
  if not M.enabled then return end
  M.sendCommand(string.format(
    "/usr/sbin/dnctl pipe 1 config bw %s; /usr/sbin/dnctl pipe 2 config bw %s",
    fmtBw(M.downloadKbps), fmtBw(M.uploadKbps)))
end

-- Set speeds (from UI/menu) and, if running, apply them live.
function M.setSpeeds(dl, ul)
  if dl then M.downloadKbps = math.max(100, math.min(1000000, dl)) end
  if ul then M.uploadKbps   = math.max(100, math.min(1000000, ul)) end
  M.save()
  if M.enabled then M.updateBoth() end
  M.refresh()
  M.pushState()
end

function M.applyPreset(kbps)
  M.setSpeeds(kbps, kbps)
end

-- Force everything back to normal even if we lost track of the helper.
function M.forceReset()
  M.sendCommand("EXIT")
  if M.helperTask and M.helperTask:isRunning() then M.helperTask:terminate() end
  M.helperTask = nil
  M.enabled = false
  M.busy = false
  M.lastError = nil
  hs.timer.doAfter(0.5, function()
    os.remove(M.cmdFile)
    os.remove(M.pidFile)
  end)
  M.refresh()
  M.pushState()
  hs.alert.show("NetLimiter: rules cleaned up")
end

----------------------------------------------------------------------
-- HTML control panel (hs.webview)
----------------------------------------------------------------------
function M.onMessage(body)
  if type(body) ~= "table" then return end
  local t = body.type
  if t == "ready" then
    M.pushState()
  elseif t == "enable" then
    M.downloadKbps = tonumber(body.download) or M.downloadKbps
    M.uploadKbps   = tonumber(body.upload)   or M.uploadKbps
    M.enable()
  elseif t == "disable" then
    M.disable()
  elseif t == "apply" then
    M.setSpeeds(tonumber(body.download), tonumber(body.upload))
  elseif t == "open" and body.url then
    hs.urlevent.openURL(body.url)
  end
end

function M.pushState()
  if not M.webview then return end
  local payload = hs.json.encode({
    enabled  = M.enabled,
    busy     = M.busy,
    download = M.downloadKbps,
    upload   = M.uploadKbps,
    error    = M.lastError or false,
  })
  M.webview:evaluateJavaScript(
    "window.NL && window.NL.applyState(" .. payload .. ")")
end

local function ensureWebview()
  if M.webview then return M.webview end

  M.ucc = hs.webview.usercontent.new("netlimiter")
  M.ucc:setCallback(function(message) M.onMessage(message.body) end)

  local w, h = 360, 560
  local sf = hs.screen.mainScreen():frame()
  local rect = hs.geometry.rect(sf.x + sf.w - w - 24, sf.y + 40, w, h)

  local masks = hs.webview.windowMasks
  local wv = hs.webview.new(rect, {}, M.ucc)
  wv:windowStyle(masks.titled + masks.closable + masks.utility)
  wv:windowTitle("NetLimiter")
  wv:allowTextEntry(true)
  wv:closeOnEscape(true)
  wv:deleteOnClose(false)
  wv:level(hs.drawing.windowLevels.floating)
  wv:shadow(true)
  wv:html(readFile(M.htmlPath))

  M.webview = wv
  return wv
end

function M.showPanel()
  ensureWebview()
  M.webview:show()
  M.webview:bringToFront(true)
  M.pushState()
end

----------------------------------------------------------------------
-- Menubar
----------------------------------------------------------------------
local ICON_SIZE = { w = 18, h = 18 }
local rabbitIcon = hs.image.imageFromPath(hs.configdir .. "/icons/rabbit.pdf"):setSize(ICON_SIZE)
local turtleIcon = hs.image.imageFromPath(hs.configdir .. "/icons/turtle.pdf"):setSize(ICON_SIZE)

function M.refresh()
  if not M.bar then return end
  M.bar:setIcon(M.enabled and turtleIcon or rabbitIcon)
end

function M.buildMenu()
  local menu = {}

  local status
  if M.busy then
    status = "◐ Working…"
  elseif M.enabled then
    status = string.format("● Limiting   ↓ %s   ↑ %s",
      fmtSpeed(M.downloadKbps), fmtSpeed(M.uploadKbps))
  else
    status = "○ Not limiting"
  end
  table.insert(menu, { title = status, disabled = true })
  table.insert(menu, { title = "-" })

  table.insert(menu, {
    title = M.enabled and "Disable limiting" or "Enable limiting",
    disabled = M.busy,
    fn = function()
      if M.enabled then M.disable() else M.enable() end
    end,
  })
  table.insert(menu, { title = "Open Control Panel…", fn = function() M.showPanel() end })
  table.insert(menu, { title = "-" })

  local pre = {}
  for _, p in ipairs(PRESETS) do
    local isCurrent = math.abs(M.downloadKbps - p[2]) < 1 and math.abs(M.uploadKbps - p[2]) < 1
    table.insert(pre, {
      title = p[1],
      checked = isCurrent,
      fn = function() M.applyPreset(p[2]) end,
    })
  end
  table.insert(menu, { title = "Presets", menu = pre })
  table.insert(menu, { title = "-" })

  if M.lastError then
    table.insert(menu, { title = "⚠ " .. M.lastError, disabled = true })
    table.insert(menu, { title = "-" })
  end

  table.insert(menu, { title = "Reset / Clean up rules", fn = function() M.forceReset() end })
  return menu
end

----------------------------------------------------------------------
-- Public: toggle the panel (handy for a hotkey)
----------------------------------------------------------------------
function M.togglePanel()
  if M.webview and M.webview:hswindow() and M.webview:hswindow():isVisible() then
    M.webview:hide()
  else
    M.showPanel()
  end
end

----------------------------------------------------------------------
-- Start
----------------------------------------------------------------------
function M.start(opts)
  opts = opts or {}
  M.load()

  -- If a previous session's helper is still alive (e.g. Hammerspoon was
  -- reloaded while limiting), adopt that state so the UI is accurate. We can
  -- still steer/stop it through the command file even without the task handle.
  if fileExists(M.pidFile) then
    M.enabled = true
  end

  M.bar = hs.menubar.new()
  M.refresh()
  M.bar:setMenu(function() return M.buildMenu() end)

  return M
end

return M

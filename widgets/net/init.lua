-- ~/.hammerspoon/widgets/net/init.lua
-- Shows live download/upload throughput for whichever interface currently
-- owns the default route. The interface is auto-detected (via `route -n get
-- default`) rather than hardcoded, since macOS renumbers en* names across
-- reinstalls, dock/adapter changes, VPN connects, Wi-Fi <-> Ethernet, etc.

local M = {}

function M.start(widgets, opts)
    local interval = opts.interval or 2

    local normal   = (opts.colors and opts.colors.normal) or { white = 1, alpha = 1 }
    local down     = (opts.colors and opts.colors.down) or { red = 1, alpha = 1 }
    local up       = (opts.colors and opts.colors.up) or { blue = 1, alpha = 1 }

    local lastIn, lastOut, lastT
    local iface                     -- currently tracked default-route interface
    local ticksSinceIfaceCheck = 0
    -- Re-resolve roughly every 15s regardless of `interval`, so switching
    -- Wi-Fi <-> Ethernet or connecting a VPN is picked up promptly without
    -- forking `route` on every single tick.
    local IFACE_RECHECK_TICKS = math.max(1, math.floor(15 / interval))

    -- Ask the routing table which interface currently owns the default
    -- route. A few ms per call, cheap but not free -- see IFACE_RECHECK_TICKS.
    local function detectIface()
        local out = hs.execute("/sbin/route -n get default 2>/dev/null")
        return out:match("interface:%s*(%S+)")
    end

    local function readCounters()
        local out = hs.execute("/usr/sbin/netstat -ibn")
        for line in out:gmatch("[^\n]+") do
            if line:match("^" .. iface .. "%s") and line:match("<Link#") then
                local f = {}
                for tok in line:gmatch("%S+") do f[#f + 1] = tok end
                return tonumber(f[7]), tonumber(f[10]) -- Ibytes, Obytes (Link# row)
            end
        end
    end

    local function human(bps)
        local u, i, v = { "B/s", "KB/s", "MB/s", "GB/s" }, 1, bps
        while v >= 1024 and i < #u do v, i = v / 1024, i + 1 end
        return string.format("%5.1f %s", v, u[i])
    end

    local canvases = widgets.mirror({ x = opts.x or 20, y = opts.y or 895, w = 110, h = opts.h or 48 }, function(c)
        c:level(hs.canvas.windowLevels.floating)
        c:behavior({ "canJoinAllSpaces", "stationary" })
        c:clickActivating(false)
        c[1] = {
            type = "rectangle",
            action = "fill",
            fillColor = { alpha = 0.35, white = 0 },
            roundedRectRadii = { xRadius = 10, yRadius = 10 }
        }
        c[2] = { type = "text", frame = { x = 10, y = 4, w = 110, h = 22 }, textSize = 14, textColor = normal }
        c[3] = { type = "text", frame = { x = 10, y = 26, w = 110, h = 22 }, textSize = 14, textColor = normal }
        c:show()
    end)

    -- No default route (or the tracked interface vanished) -- show N/A
    -- instead of leaving the last real reading frozen on screen.
    local function showNA()
        for _, c in ipairs(canvases) do
            c[2].text = "↓   N/A"; c[2].textColor = normal
            c[3].text = "↑   N/A"; c[3].textColor = normal
        end
    end

    local function tick()
        -- Re-resolve the default-route interface at startup, periodically,
        -- and whenever the previously tracked one goes quiet (see below).
        -- Reset the running delta across a switch so we don't diff counters
        -- from two different interfaces.
        if not iface or ticksSinceIfaceCheck >= IFACE_RECHECK_TICKS then
            local detected = detectIface()
            if detected ~= iface then
                iface = detected
                lastIn, lastOut, lastT = nil, nil, nil
            end
            ticksSinceIfaceCheck = 0
        end
        ticksSinceIfaceCheck = ticksSinceIfaceCheck + 1

        if not iface then
            -- `route -n get default` returned no interface: no network path
            -- at all (cable pulled with no Wi-Fi fallback, etc).
            showNA()
            return
        end

        local nin, nout = readCounters()
        if nin == nil then
            -- Tracked interface vanished from netstat (link down, adapter
            -- unplugged, VPN torn down, …) -- force a re-check next tick.
            ticksSinceIfaceCheck = IFACE_RECHECK_TICKS
            lastIn, lastOut, lastT = nil, nil, nil
            showNA()
            return
        end

        local now = hs.timer.secondsSinceEpoch()
        if lastIn and now > lastT then
            local dt     = now - lastT
            local dkbps  = human(math.max(0, (nin - lastIn) / dt))
            local ukbps  = human(math.max(0, (nout - lastOut) / dt))
            local dColor = (dkbps:match("MB/s$") or dkbps:match("GB/s$")) and down or normal
            local uColor = (ukbps:match("MB/s$") or ukbps:match("GB/s$")) and up or normal
            for _, c in ipairs(canvases) do
                c[2].text = "↓ " .. dkbps; c[2].textColor = dColor
                c[3].text = "↑ " .. ukbps; c[3].textColor = uColor
            end
        elseif not lastIn then
            -- First sample after (re)connecting -- nothing to diff against yet.
            showNA()
        end
        lastIn, lastOut, lastT = nin, nout, now
    end

    local timer = hs.timer.new(interval, tick)
    timer:start(); tick()

    return { canvases = canvases, timer = timer }
end

return M

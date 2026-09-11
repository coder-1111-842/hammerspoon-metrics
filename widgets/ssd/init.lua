-- ~/.hammerspoon/widgets/ssd/init.lua
-- Shows SSD usage percentage; turns red above 70%.
-- Polls once and updates every mirrored canvas.

local M = {}

function M.start(widgets, opts)
    local interval = opts.interval or 10
    local script   = opts.script

    local threshold = opts.threshold or 70
    local normal    = (opts.colors and opts.colors.normal) or { white = 1, alpha = 1 }
    local alert     = (opts.colors and opts.colors.alert) or { red = 1, alpha = 1 }

    local canvases = widgets.mirror({ x = opts.x or 20, y = opts.y or 785, w = 110, h = opts.h or 48 }, function(c)
        c:level(hs.canvas.windowLevels.floating)
        c:behavior({ "canJoinAllSpaces", "stationary" })
        c:clickActivating(false)
        c[1] = { type = "rectangle", action = "fill",
            fillColor = { alpha = 0.35, white = 0 },
            roundedRectRadii = { xRadius = 10, yRadius = 10 } }
        c[2] = { type = "text", frame = { x = 10, y = 15, w = 110, h = 40 }, textSize = 14, textColor = normal }
        c:show()
    end)

    local function tick()
        local out   = hs.execute(script):gsub("%s+$", "")
        local color = (tonumber(out) and tonumber(out) > threshold) and alert or normal
        for _, c in ipairs(canvases) do
            c[2].textColor = color
            c[2].text      = "SSD: " .. out .. " %"
        end
    end

    local timer = hs.timer.new(interval, tick)
    timer:start(); tick()

    return { canvases = canvases, timer = timer }
end

return M

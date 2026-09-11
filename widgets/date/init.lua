-- ~/.hammerspoon/widgets/date/init.lua
-- Shows the current date/time from the date script.
-- Polls once and updates every mirrored canvas.

local M = {}



function M.start(widgets, opts)
    local interval = opts.interval or 60
    local script   = opts.script

    local white = { white = 1, alpha = 1 }

    local canvases = widgets.mirror({ x = opts.x or 20, y = opts.y or 1060, w = 160, h = opts.h or 48 }, function(c)
        c:level(hs.canvas.windowLevels.floating)
        c:behavior({ "canJoinAllSpaces", "stationary" })
        c:clickActivating(false)
        c[1] = { type = "rectangle", action = "fill",
            fillColor = { alpha = 0.35, white = 0 },
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
            trackMouseUp = true }
        c[2] = { type = "text", frame = { x = 10, y = 10, w = 150, h = 36 }, textSize = 11, textColor = white }
        c:show()


    end)

    local function tick()
        local out = hs.execute(script)
        for _, c in ipairs(canvases) do
            c[2].text = "" .. out
        end
    end

    local timer = hs.timer.new(interval, tick)
    timer:start(); tick()

    return { canvases = canvases, timer = timer }
end

return M

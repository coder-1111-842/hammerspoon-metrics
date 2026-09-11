-- ~/.hammerspoon/widgets/gpu/init.lua
-- GPU usage (HW active residency), from the shared powermetrics provider.
-- Turns red above 80%. Mirrored across displays.

local M = {}

function M.start(widgets, opts)
    local threshold = opts.threshold or 80
    local normal    = (opts.colors and opts.colors.normal) or { white = 1, alpha = 1 }
    local alert     = (opts.colors and opts.colors.alert) or { red = 1, alpha = 1 }

    local canvases = widgets.mirror({ x = opts.x or 20, y = opts.y or 730, w = 110, h = opts.h or 48 }, function(c)
        c:level(hs.canvas.windowLevels.floating)
        c:behavior({ "canJoinAllSpaces", "stationary" })
        c:clickActivating(false)
        c[1] = { type = "rectangle", action = "fill",
            fillColor = { alpha = 0.35, white = 0 },
            roundedRectRadii = { xRadius = 10, yRadius = 10 } }
        c[2] = { type = "text", frame = { x = 10, y = 15, w = 110, h = 40 }, textSize = 14, textColor = normal }
        c:show()
    end)

    local function render(gpu)
        local color = (gpu and gpu > threshold) and alert or normal
        local text  = gpu and string.format("GPU: %.0f %%", gpu) or "GPU: N/A"
        for _, c in ipairs(canvases) do
            c[2].textColor = color
            c[2].text      = text
        end
    end

    -- Read from the shared provider (started by the orchestrator).
    require("widgets.pmusage").subscribe(function(_, gpu) render(gpu) end)

    return { canvases = canvases }
end

return M

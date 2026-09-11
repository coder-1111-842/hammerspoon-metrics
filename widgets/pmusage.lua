-- ~/.hammerspoon/widgets/pmusage.lua
--
-- Shared powermetrics provider.
--
-- `powermetrics` needs root and each sample takes ~1s, so we run it ONCE per
-- interval here and hand the parsed values to every subscriber (the cpu and gpu
-- widgets). This avoids running the heavy `sudo powermetrics` sampler twice.
--
-- Requires passwordless sudo for the script (NOPASSWD in /etc/sudoers.d/…),
-- otherwise the sampler fails silently and subscribers get nil (shown as N/A).

local P = {
    cmd      = nil,
    interval = 5,
    subs     = {},   -- list of fn(cpuPct, gpuPct)
    cpu      = nil,  -- latest mean CPU % (nil = unknown / N/A)
    gpu      = nil,  -- latest GPU % (nil = unknown / N/A)
    timer    = nil,
    task     = nil,
    started  = false,
}

-- Parse powermetrics output.
--   CPU: mean of every "CPU N active residency: X%" (per-core) line.
--   GPU: the "GPU HW active residency: X%" value.
local function parse(output)
    local sum, n = 0, 0
    for line in output:gmatch("[^\r\n]+") do
        local pct = line:match("^%s*[Cc][Pp][Uu]%s+%d+%s+active residency:%s*([%d%.]+)%%")
        if pct then
            sum = sum + tonumber(pct)
            n   = n + 1
        end
    end
    local cpu = (n > 0) and (sum / n) or nil

    local gpu = output:match("GPU HW active residency:%s*([%d%.]+)%%")
    gpu = gpu and tonumber(gpu) or nil

    return cpu, gpu
end

local function notify()
    for _, fn in ipairs(P.subs) do fn(P.cpu, P.gpu) end
end

local function poll()
    if P.task and P.task:isRunning() then return end -- previous sample still running
    P.task = hs.task.new("/bin/sh", function(exitCode, stdOut, _)
        if exitCode == 0 and stdOut then
            P.cpu, P.gpu = parse(stdOut)
        else
            P.cpu, P.gpu = nil, nil
        end
        notify()
    end, { "-c", P.cmd })
    P.task:start()
end

-- Register a subscriber. Called immediately with the latest values (if any),
-- then on every subsequent poll.
function P.subscribe(fn)
    P.subs[#P.subs + 1] = fn
    fn(P.cpu, P.gpu)
end

function P.start(opts)
    if P.started then return P end
    P.started  = true
    P.cmd      = opts.cmd
    P.interval = opts.interval or 5
    P.timer    = hs.timer.new(P.interval, poll)
    P.timer:start()
    poll()
    return P
end

return P

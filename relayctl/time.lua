-- time.lua (ascii only)

local util = require("relayctl.util")

local M = {}

-- Returns a stable local monotonic time in ms (based on os.clock)
function M.uptimeMs()
  return math.floor((os.clock() or 0) * 1000)
end

-- Returns epoch UTC ms/sec (can "freeze" if server breaks time; we also fallback)
function M.epochUtcMs()
  local ok, v = pcall(os.epoch, "utc")
  if ok and type(v) == "number" then return v end
  return nil
end

function M.epochIngameMs()
  local ok, v = pcall(os.epoch, "ingame")
  if ok and type(v) == "number" then return v end
  return nil
end

function M.timeUtc()
  local ok, v = pcall(os.time, "utc")
  if ok then return v end
  return nil
end

function M.timeIngame()
  local ok, v = pcall(os.time, "ingame")
  if ok then return v end
  return nil
end

-- World time source:
--   - default: epochUTC seconds (updates every tick)
--   - optional modulo_seconds
--
-- We also detect "frozen epoch" and fallback to monotonic uptime-based progression.
local lastEpochMs = nil
local lastUptimeMs = nil
local frozenCount = 0

local function applyModuloSec(sec, mod)
  if type(mod) == "number" and mod > 0 then
    return sec % mod
  end
  return sec
end

-- Returns worldNowSec, flags:
--   worldSyncOk: true if epoch is not frozen, else false (fallback)
function M.worldNow(hwTimeCfg)
  local mod = hwTimeCfg and hwTimeCfg.modulo_seconds or nil

  local nowUp = M.uptimeMs()
  local nowEp = M.epochUtcMs()

  if type(nowEp) == "number" then
    if lastEpochMs ~= nil and nowEp == lastEpochMs then
      frozenCount = frozenCount + 1
    else
      frozenCount = 0
    end
    lastEpochMs = nowEp
    lastUptimeMs = nowUp

    local sec = math.floor(nowEp / 1000)
    return applyModuloSec(sec, mod), (frozenCount < 10), "epochUTC"
  end

  -- fallback if epoch unavailable
  if lastUptimeMs == nil then lastUptimeMs = nowUp end
  local delta = nowUp - lastUptimeMs
  if delta < 0 then delta = 0 end

  -- approximate sec by uptime only
  local sec = math.floor(nowUp / 1000)
  return applyModuloSec(sec, mod), false, "uptime"
end

-- Signed drift between new and estimated values with modulo support
function M.signedDrift(newV, estV, mod)
  if type(mod) == "number" and mod > 0 then
    local d = (newV - estV) % mod
    if d > mod / 2 then d = d - mod end
    return d
  end
  return newV - estV
end

function M.diffSec(nowV, thenV, mod)
  if thenV == nil then return 0 end
  if type(mod) == "number" and mod > 0 then
    return (nowV - thenV) % mod
  end
  return nowV - thenV
end

return M
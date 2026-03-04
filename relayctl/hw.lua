-- hw.lua (ascii only)
-- Redstone relays + link mapping + read/write helpers.

local util = require("relayctl.util")

local M = {}

M.relaysByAlias = {}
M.linksByAlias = {}

function M.init(hw)
  M.relaysByAlias = {}
  M.linksByAlias = {}

  for _, r in ipairs((hw and hw.redstone_relays) or {}) do
    if r.alias and r.name and peripheral.isPresent(r.name) then
      M.relaysByAlias[r.alias] = peripheral.wrap(r.name)
    else
      M.relaysByAlias[r.alias] = nil
    end
  end

  for _, l in ipairs((hw and hw.redstone_links) or {}) do
    if l.alias and l.host_relay and l.relay_side then
      M.linksByAlias[l.alias] = { relayAlias = l.host_relay, side = l.relay_side }
    end
  end
end

local function getRelayForLink(linkAlias)
  local link = M.linksByAlias[linkAlias]
  if not link then return nil, nil end
  return M.relaysByAlias[link.relayAlias], link.side
end

function M.setLinkSignal(linkAlias, signal)
  local relay, side = getRelayForLink(linkAlias)
  if not relay then return false, "relay missing for link " .. tostring(linkAlias) end

  if type(signal) == "boolean" then
    local ok = util.safeCall(relay, "setOutput", side, signal)
    if ok then return true end
    local v = signal and 15 or 0
    local ok2 = util.safeCall(relay, "setAnalogOutput", side, v)
    if ok2 then return true end
    return false, "no supported output methods"
  elseif type(signal) == "number" then
    local v = util.clamp(math.floor(signal + 0.5), 0, 15)
    local ok = util.safeCall(relay, "setAnalogOutput", side, v)
    if ok then return true end
    local ok2 = util.safeCall(relay, "setOutput", side, v > 0)
    if ok2 then return true end
    return false, "no supported output methods"
  else
    return false, "unsupported signal type: " .. type(signal)
  end
end

function M.readLinkAnalog(linkAlias)
  local relay, side = getRelayForLink(linkAlias)
  if not relay then return nil, "relay missing" end

  local ok, v = util.safeCall(relay, "getAnalogInput", side)
  if ok then return tonumber(v) or 0 end

  local ok2, b = util.safeCall(relay, "getInput", side)
  if ok2 then return (b and 15 or 0) end

  return nil, "no supported input methods"
end

function M.ensureAllSafeZero()
  for alias, _ in pairs(M.linksByAlias) do
    pcall(M.setLinkSignal, alias, 0)
  end
end

return M
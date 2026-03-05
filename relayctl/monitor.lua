-- monitor.lua (ascii only)
-- Strict cfg-only wrap + alias mapping for double-connected monitors.

local util = require("util")

local M = {}

M.mon = nil
M.monName = nil
M.monCanonical = nil
M.monAliases = {}

local function isMonitorType(t)
  return t == "monitor" or t == "advanced_monitor"
end

local function tryWrap(name)
  local ok, p = pcall(peripheral.wrap, name)
  if ok and p then return p end
  return nil
end

local function reset()
  M.mon = nil
  M.monName = nil
  M.monCanonical = nil
  M.monAliases = {}
end

local function buildAliases()
  M.monAliases = {}
  if not M.mon then return end

  local okCanon, canon = pcall(peripheral.getName, M.mon)
  if okCanon and type(canon) == "string" and canon ~= "" then
    M.monCanonical = canon
  else
    M.monCanonical = M.monName
  end

  if M.monName then M.monAliases[M.monName] = true end
  if M.monCanonical then M.monAliases[M.monCanonical] = true end

  for _, n in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(n)
    if isMonitorType(t) then
      local p = tryWrap(n)
      if p then
        local okN, cn = pcall(peripheral.getName, p)
        if okN and cn == M.monCanonical then
          M.monAliases[n] = true
        end
      end
    end
  end
end

function M.init(hw)
  reset()

  local name = hw and hw.monitor_name or nil
  if not name or name == "" then
    -- requirement: no cfg => do nothing
    return false
  end

  -- strict cfg-only
  if peripheral.isPresent(name) then
    local t = peripheral.getType(name)
    if not isMonitorType(t) then return false end
    M.mon = peripheral.wrap(name)
    M.monName = name
  else
    -- allow wrap attempt, but do not auto-find
    local t = peripheral.getType(name)
    if not isMonitorType(t) then return false end
    local p = tryWrap(name)
    if not p then return false end
    M.mon = p
    M.monName = name
  end

  if M.mon and type(M.mon.setTextScale) == "function" then
    pcall(M.mon.setTextScale, hw.monitor_text_scale or 0.5)
  end

  buildAliases()
  return true
end

function M.rebuildAliases()
  buildAliases()
end

function M.acceptTouch(sourceName)
  if not M.mon then return false end
  return M.monAliases[tostring(sourceName or "")] == true
end

function M.set(bg, fg)
  if not M.mon then return end
  pcall(M.mon.setBackgroundColor, bg)
  pcall(M.mon.setTextColor, fg)
end

function M.writeAt(x, y, text)
  if not M.mon then return end
  pcall(M.mon.setCursorPos, x, y)
  M.mon.write(tostring(text or ""))
end

function M.fill(x1, y1, x2, y2, ch)
  if not M.mon then return end
  local w, h = M.mon.getSize()
  x1 = util.clamp(x1, 1, w); x2 = util.clamp(x2, 1, w)
  y1 = util.clamp(y1, 1, h); y2 = util.clamp(y2, 1, h)
  if x2 < x1 or y2 < y1 then return end
  local s = string.rep(ch or " ", x2 - x1 + 1)
  for y = y1, y2 do
    M.writeAt(x1, y, s)
  end
end

function M.clear(bg, fg)
  if not M.mon then return end
  M.set(bg or colors.black, fg or colors.white)
  pcall(M.mon.clear)
  pcall(M.mon.setCursorPos, 1, 1)
end

function M.size()
  if not M.mon then return 0, 0 end
  return M.mon.getSize()
end

return M
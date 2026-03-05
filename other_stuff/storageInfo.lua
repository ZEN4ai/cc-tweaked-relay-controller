-- storageInfo.lua

-- wget https://raw.githubusercontent.com/ZEN4ai/cc-tweaked-relay-controller/other_stuff/other_stuff/storageInfo.lua

-- Storage dashboard: fullness + items sorted by count + per-item container usage %
-- Config supports: side OR peripheral name for BOTH monitor and storage.
-- Threads: collector + renderer + input
-- NO timers, NO os.clock(): sleep only.

local CFG = {
  storageSideOrName = "create:item_vault_2",
  monitorSideOrName = "bottom", -- nil = auto-find first monitor

  refreshSeconds = 1.0,
  autoScroll = true,
  autoScrollEverySeconds = 1.0,
  monitorTextScale = 0.5,
}

------------------------------------------------
-- Persistence
------------------------------------------------
local STATE_PATH = "/.dashboard_state"

local function loadState()
  if not fs.exists(STATE_PATH) then return end
  local h = fs.open(STATE_PATH, "r")
  if not h then return end
  local s = h.readAll()
  h.close()
  if not s or s == "" then return end
  local ok, t = pcall(textutils.unserialize, s)
  if not ok or type(t) ~= "table" then return end

  if type(t.autoScroll) == "boolean" then CFG.autoScroll = t.autoScroll end
  -- scroll will be applied after we create scroll var (below)
  return t
end

local function saveState(autoScroll, scroll)
  local t = { autoScroll = autoScroll, scroll = scroll }
  local h = fs.open(STATE_PATH, "w")
  if not h then return end
  h.write(textutils.serialize(t))
  h.close()
end

------------------------------------------------
-- Helpers: robust peripheral resolution
------------------------------------------------
local function isSide(s)
  return s == "left" or s == "right" or s == "top" or s == "bottom" or s == "front" or s == "back"
end

local function safeGetType(id)
  if not id then return nil end
  local ok, t = pcall(peripheral.getType, id)
  if ok then return t end
  return nil
end

local function safeWrap(id)
  if not id then return nil end
  local ok, p = pcall(peripheral.wrap, id)
  if ok then return p end
  return nil
end

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function resolvePeripheral(sideOrName)
  if not sideOrName then return nil end

  if isSide(sideOrName) then
    if peripheral.isPresent(sideOrName) then
      return safeWrap(sideOrName), sideOrName, safeGetType(sideOrName)
    end
    return nil
  end

  local t = safeGetType(sideOrName)
  if t then
    return safeWrap(sideOrName), sideOrName, t
  end

  return nil
end

local function resolveMonitor()
  if CFG.monitorSideOrName then
    local p, id, t = resolvePeripheral(CFG.monitorSideOrName)
    if p and t == "monitor" then return p, id end
    return nil, nil
  end

  local m = peripheral.find("monitor")
  if not m then return nil, nil end

  local names = peripheral.getNames()
  for i = 1, #names do
    if safeGetType(names[i]) == "monitor" then
      local w = safeWrap(names[i])
      if w == m then
        return m, names[i]
      end
    end
  end

  return m, nil
end

local function resolveStorage()
  local p, id, t = resolvePeripheral(CFG.storageSideOrName)
  if not p then return nil, nil, nil end

  if type(p.list) ~= "function" or type(p.size) ~= "function" then
    if type(p.list) ~= "function" or (type(p.size) ~= "function" and type(p.getInventorySize) ~= "function") then
      return nil, nil, t
    end
  end

  return p, id, t
end

------------------------------------------------
-- Output selection
------------------------------------------------
local mon, monId = resolveMonitor()
local OUT = mon or term
if mon and CFG.monitorTextScale and mon.setTextScale then
  mon.setTextScale(CFG.monitorTextScale)
end

local function isColor(out)
  return out and out.isColor and out.isColor() or false
end

local COLOR = {
  bg = colors.black,
  headerBg = colors.blue,
  headerFg = colors.white,
  text = colors.white,
  dim = colors.lightGray,
  accent = colors.lime,
  warn = colors.orange,
  bad = colors.red,
  barBg = colors.gray,
}

if not isColor(OUT) then
  COLOR.headerBg = colors.black
  COLOR.dim = colors.white
  COLOR.accent = colors.white
  COLOR.warn = colors.white
  COLOR.bad = colors.white
  COLOR.barBg = colors.black
end

------------------------------------------------
-- Storage selection
------------------------------------------------
local storage, storageId, storageType = resolveStorage()
if not storage then
  term.setTextColor(colors.red)
  term.clear()
  term.setCursorPos(1, 1)
  print("Error: storage not found / not inventory-like.")
  print("CFG.storageSideOrName = " .. tostring(CFG.storageSideOrName))
  if storageType then print("Detected type: " .. tostring(storageType)) end
  return
end

------------------------------------------------
-- Console help (if monitor used)
------------------------------------------------
if mon then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("Dashboard running on monitor" .. (monId and (" (" .. monId .. ")") or "") .. ".")
  print("Storage: " .. tostring(storageId or CFG.storageSideOrName) .. (storageType and (" (" .. storageType .. ")") or ""))
  print("")
  print("Controls (keyboard):")
  print("A - Toggle Auto-Scroll")
  print("R - Force refresh now")
  print("Q - Quit program")
  print("")
end

------------------------------------------------
-- Inventory helpers (accept size/getInventorySize)
------------------------------------------------
local function invSize()
  if storage.size then return storage.size() end
  if storage.getInventorySize then return storage.getInventorySize() end
  return 0
end

local function invList()
  if storage.list then return storage.list() end
  return {}
end

local function itemDetail(slot)
  if storage.getItemDetail then return storage.getItemDetail(slot) end
  return nil
end

------------------------------------------------
-- Shared state
------------------------------------------------
local DATA = {
  totalSlots = 0,
  usedSlots = 0,
  percent = 0,
  items = {},
  capacity = 0,
  error = nil,
  seq = 0,
}

------------------------------------------------
-- Refresh logic (FAST): cache details per item name
------------------------------------------------
local detailCache = {} -- [itemName] = { displayName=..., maxCount=... }

local function doRefresh()
  local totalSlots = invSize()
  local lst = invList()

  local agg = {}
  local usedSlots = 0
  local fullness = 0
  local capacity = totalSlots * 64

  for slot, it in pairs(lst) do
    if it and it.count and it.count > 0 and it.name then
      usedSlots = usedSlots + 1

      local a = agg[it.name]
      if not a then
        a = { name = it.name, displayName = it.name, count = 0, percent = 0 }
        agg[it.name] = a
      end
      a.count = a.count + it.count

      local c = detailCache[it.name]
      if not c then
        local det = itemDetail(slot)
        c = {
          displayName = (det and det.displayName) or it.name,
          maxCount = (det and det.maxCount) or 64,
        }
        if not c.maxCount or c.maxCount <= 0 then c.maxCount = 64 end
        detailCache[it.name] = c
      end

      a.displayName = c.displayName
      fullness = fullness + (it.count / c.maxCount)
    end
  end

  local percent = 0
  if totalSlots > 0 then
    percent = (fullness / totalSlots) * 100
  end

  local items = {}
  for _, v in pairs(agg) do
    if capacity > 0 then v.percent = (v.count / capacity) * 100 else v.percent = 0 end
    table.insert(items, v)
  end

  table.sort(items, function(a, b)
    if a.count == b.count then
      return (a.displayName or a.name) < (b.displayName or b.name)
    end
    return a.count > b.count
  end)

  DATA.totalSlots = totalSlots
  DATA.usedSlots = usedSlots
  DATA.percent = percent
  DATA.items = items
  DATA.capacity = capacity
  DATA.error = nil
  DATA.seq = DATA.seq + 1
end

------------------------------------------------
-- Collector thread (polling + "force refresh")
------------------------------------------------
local forceRefresh = true

local function collector()
  while true do
    local ok, err = pcall(doRefresh)
    if not ok then DATA.error = tostring(err) end

    local remaining = CFG.refreshSeconds
    local slice = 0.05
    while remaining > 0 do
      if forceRefresh then break end
      local s = slice
      if s > remaining then s = remaining end
      sleep(s)
      remaining = remaining - s
    end

    if forceRefresh then
      forceRefresh = false
    end
  end
end

------------------------------------------------
-- UI helpers
------------------------------------------------
local scroll = 0

local function writeAt(x, y, text, fg, bg)
  if bg then OUT.setBackgroundColor(bg) end
  if fg then OUT.setTextColor(fg) end
  OUT.setCursorPos(x, y)
  OUT.write(text)
end

local function clearLine(y, bg)
  local w, _ = OUT.getSize()
  writeAt(1, y, string.rep(" ", w), nil, bg)
end

local function centerText(y, text, fg, bg)
  local w, _ = OUT.getSize()
  local x = math.floor((w - #text) / 2) + 1
  writeAt(x, y, text, fg, bg)
end

local function drawBar(y, pct)
  local w, _ = OUT.getSize()
  local width = w - 2
  if width < 1 then return end

  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end

  local fill = math.floor((pct / 100) * width + 0.5)

  local fg = COLOR.accent
  if pct >= 90 then fg = COLOR.bad
  elseif pct >= 75 then fg = COLOR.warn end

  writeAt(2, y, string.rep(" ", width), nil, COLOR.barBg)
  if fill > 0 then
    writeAt(2, y, string.rep(" ", fill), nil, fg)
  end
end

local function formatCount(n)
  if n >= 1000000 then
    return string.format("%.1fm", n / 1000000)
  elseif n >= 10000 then
    return string.format("%.1fk", n / 1000)
  else
    return tostring(n)
  end
end

local function getListGeometry()
  local w, h = OUT.getSize()
  local listTop = 5
  local listH = h - listTop + 1
  if listH < 0 then listH = 0 end
  return w, h, listTop, listH
end

local function computeColumnWidths(items, maxRows)
  local maxCountW = 1
  local maxPctW = 4
  local scan = math.min(#items, math.max(50, (maxRows or 0) * 3))

  for i = 1, scan do
    local it = items[i]
    local c = formatCount(it.count)
    if #c > maxCountW then maxCountW = #c end
    local p = string.format("%.2f%%", it.percent)
    if #p > maxPctW then maxPctW = #p end
  end

  return maxPctW, maxCountW
end

local function render()
  local w, h, listTop, listH = getListGeometry()

  OUT.setBackgroundColor(COLOR.bg)
  OUT.setTextColor(COLOR.text)
  OUT.clear()

  clearLine(1, COLOR.headerBg)
  centerText(1, "Storage Dashboard", COLOR.headerFg, COLOR.headerBg)

  clearLine(2, COLOR.bg)
  local left = string.format("Container Fullness: %.1f%%", DATA.percent)
  writeAt(2, 2, left, COLOR.text, COLOR.bg)

  local right = string.format("%d/%d", DATA.usedSlots, DATA.totalSlots)
  writeAt(w - #right - 1, 2, right, COLOR.dim, COLOR.bg)

  clearLine(3, COLOR.bg)
  drawBar(3, DATA.percent)

  clearLine(4, COLOR.bg)
  local mode = CFG.autoScroll and "Auto-Scroll: ON" or "Auto-Scroll: OFF"
  writeAt(2, 4, "Items (sorted by count)", COLOR.dim, COLOR.bg)
  writeAt(w - #mode - 1, 4, mode, COLOR.dim, COLOR.bg)

  if DATA.error then
    clearLine(4, COLOR.bg)
    local err = "Storage error: " .. DATA.error
    if #err > w - 2 then err = err:sub(1, w - 2) end
    writeAt(2, 4, err, COLOR.bad, COLOR.bg)
  end

  local items = DATA.items
  local maxScroll = math.max(0, #items - listH)
  scroll = clamp(scroll, 0, maxScroll)

  local pctW, countW = computeColumnWidths(items, listH)

  local countStart = w - countW - 1
  local pctStart = countStart - pctW - 2
  local nameMax = pctStart - 3
  if nameMax < 1 then nameMax = 1 end

  for i = 0, listH - 1 do
    local idx = scroll + i + 1
    local y = listTop + i
    clearLine(y, COLOR.bg)

    local it = items[idx]
    if it then
      local name = it.displayName or it.name
      if #name > nameMax then name = name:sub(1, nameMax) end

      local pctStr = string.format("%.2f%%", it.percent)
      local cntStr = formatCount(it.count)

      writeAt(2, y, name, COLOR.text, COLOR.bg)

      writeAt(pctStart, y, string.rep(" ", pctW), COLOR.dim, COLOR.bg)
      writeAt(pctStart + (pctW - #pctStr), y, pctStr, COLOR.dim, COLOR.bg)

      writeAt(countStart, y, string.rep(" ", countW), COLOR.accent, COLOR.bg)
      writeAt(countStart + (countW - #cntStr), y, cntStr, COLOR.accent, COLOR.bg)
    end
  end
end

------------------------------------------------
-- Renderer thread (smooth render + autoscroll)
------------------------------------------------
local function renderer()
  local tick = 0.10
  local acc = 0

  while true do
    render()
    sleep(tick)

    if CFG.autoScroll then
      acc = acc + tick
      if acc >= CFG.autoScrollEverySeconds then
        acc = 0
        local _, _, _, listH = getListGeometry()
        local maxScroll = math.max(0, #DATA.items - listH)
        if maxScroll > 0 then
          scroll = scroll + 1
          if scroll > maxScroll then scroll = 0 end
        else
          scroll = 0
        end
        -- persist current scroll while autoscrolling
        saveState(CFG.autoScroll, scroll)
      end
    else
      acc = 0
    end
  end
end

------------------------------------------------
-- Input thread (A toggle + persistence + "scroll to top on disable")
------------------------------------------------
local function input()
  while true do
    local ev = { os.pullEventRaw() }
    local e = ev[1]

    if e == "terminate" then
      saveState(CFG.autoScroll, scroll)
      error("Terminated")
    elseif e == "key" then
      local k = ev[2]

      if k == keys.a then
        CFG.autoScroll = not CFG.autoScroll

        if not CFG.autoScroll then
          -- When turning OFF autoscroll: jump to top so biggest items are at the top.
          scroll = 0
        end

        saveState(CFG.autoScroll, scroll)

      elseif k == keys.r then
        forceRefresh = true
        saveState(CFG.autoScroll, scroll)

      elseif k == keys.up then
        scroll = scroll - 1
        saveState(CFG.autoScroll, scroll)

      elseif k == keys.down then
        scroll = scroll + 1
        saveState(CFG.autoScroll, scroll)

      elseif k == keys.pageUp then
        scroll = scroll - 10
        saveState(CFG.autoScroll, scroll)

      elseif k == keys.pageDown then
        scroll = scroll + 10
        saveState(CFG.autoScroll, scroll)

      elseif k == keys.q then
        saveState(CFG.autoScroll, scroll)
        error("Quit")
      end

    elseif e == "monitor_touch" then
      local y = ev[4]
      if y == 1 then
        CFG.autoScroll = not CFG.autoScroll
        if not CFG.autoScroll then scroll = 0 end
        saveState(CFG.autoScroll, scroll)
      end
    end
  end
end

------------------------------------------------
-- Load persisted state (before first refresh)
------------------------------------------------
local st = loadState()

------------------------------------------------
-- First refresh BEFORE UI starts
------------------------------------------------
pcall(function()
  doRefresh()
  forceRefresh = false
end)

-- Apply saved scroll after we know variables exist
if type(st) == "table" and type(st.scroll) == "number" then
  scroll = math.floor(st.scroll)
end

-- If autoscroll is OFF at boot, enforce "top"
if not CFG.autoScroll then
  scroll = 0
end

-- Persist once on boot to normalize state
saveState(CFG.autoScroll, scroll)

------------------------------------------------
-- Run parallel
------------------------------------------------
parallel.waitForAny(collector, renderer, input)


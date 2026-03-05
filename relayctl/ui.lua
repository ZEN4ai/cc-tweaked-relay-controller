-- ui.lua (ascii only)
-- UI layout + word wrap + deterministic buttons.

local util = require("util")
local mon  = require("monitor")
local tim  = require("time")

local M = {}

local ui = {
  modeScroll = 0,
  maxScroll  = 0,
  buttons = {},
  order = {}
}

function M.getState()
  return ui
end

local function splitWords(s)
  local words = {}
  for w in tostring(s):gmatch("%S+") do table.insert(words, w) end
  if #words == 0 then table.insert(words, "") end
  return words
end

local function wrapLine(s, maxW)
  s = tostring(s or "")
  if maxW <= 0 then return {} end
  if #s <= maxW then return { s } end

  local words = splitWords(s)
  local out, cur = {}, ""

  local function push()
    table.insert(out, cur)
    cur = ""
  end

  for _, w in ipairs(words) do
    if cur == "" then
      if #w <= maxW then
        cur = w
      else
        local i = 1
        while i <= #w do
          table.insert(out, w:sub(i, i + maxW - 1))
          i = i + maxW
        end
      end
    else
      if #cur + 1 + #w <= maxW then
        cur = cur .. " " .. w
      else
        push()
        if #w <= maxW then
          cur = w
        else
          local i = 1
          while i <= #w do
            table.insert(out, w:sub(i, i + maxW - 1))
            i = i + maxW
          end
        end
      end
    end
  end

  if cur ~= "" then push() end
  return out
end

local function btnReset()
  ui.buttons = {}
  ui.order = {}
end

local function btnAdd(id, x1, y1, x2, y2, label, bg, fg)
  ui.buttons[id] = { x1=x1, y1=y1, x2=x2, y2=y2, label=label, bg=bg, fg=fg }
  table.insert(ui.order, id)
end

function M.hit(x, y)
  for i = #ui.order, 1, -1 do
    local id = ui.order[i]
    local b = ui.buttons[id]
    if b and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
      return id
    end
  end
  return nil
end

local function drawButton(id)
  local b = ui.buttons[id]
  if not b then return end
  mon.set(b.bg, b.fg)
  mon.fill(b.x1, b.y1, b.x2, b.y2, " ")

  local w = b.x2 - b.x1 + 1
  local text = tostring(b.label or "")
  if #text > w then text = text:sub(1, w) end
  local tx = b.x1 + math.floor((w - #text) / 2)
  local ty = b.y1 + math.floor((b.y2 - b.y1) / 2)
  mon.writeAt(tx, ty, text)
end

local function drawLineColored(x, y, w, text, fg)
  mon.set(colors.black, fg)
  local s = tostring(text or "")
  if #s > w then s = s:sub(1, w) end
  mon.writeAt(x, y, (s .. string.rep(" ", w)):sub(1, w))
end

local function drawConsole(x1, y1, x2, y2, lines, meta)
  local w = x2 - x1 + 1
  local h = y2 - y1 + 1
  mon.set(colors.black, colors.white)
  mon.fill(x1, y1, x2, y2, " ")

  local out = {}
  local outFg = {}

  for i, l in ipairs(lines) do
    local fg = (meta and meta[i] and meta[i].fg) or colors.white
    local parts = wrapLine(l, w)
    for _, p in ipairs(parts) do
      table.insert(out, p)
      table.insert(outFg, fg)
      if #out >= h then break end
    end
    if #out >= h then break end
  end

  for i = 1, math.min(#out, h) do
    drawLineColored(x1, y1 + i - 1, w, out[i], outFg[i] or colors.white)
  end
end

local function drawFooter2Rows(st, w, y1, y2)
  local gap = 1
  local pad = 2
  local usableW = w - (pad * 2)
  local cols = 4
  local colW = math.floor((usableW - (cols - 1) * gap) / cols)
  if colW < 6 then colW = 6 end

  local function colX(c)
    local x1c = pad + (c - 1) * (colW + gap)
    local x2c = x1c + colW - 1
    return x1c, x2c
  end

  local rowA = y1
  local rowB = y1 + 1
  if rowB > y2 then rowB = y2 end

  local function placeAt(id, c, y, label, bg, fg)
    local x1c, x2c = colX(c)
    x2c = util.clamp(x2c, 1, w)
    x1c = util.clamp(x1c, 1, w)
    if x2c < x1c then return end
    btnAdd(id, x1c, y, x2c, y, label, bg, fg)
    drawButton(id)
  end

  placeAt("STOP", 1, rowA, "STOP", colors.red, colors.white)

  if st.paused then
    placeAt("PAUSE_TOGGLE", 2, rowA, "RESUME", colors.green, colors.black)
  else
    placeAt("PAUSE_TOGGLE", 2, rowA, "PAUSE", colors.orange, colors.black)
  end

  placeAt("STEP", 3, rowA, "STEP", colors.lime, colors.black)

  if st.show_debug then
    placeAt("TOGGLE_DEBUG", 4, rowA, "HIDE", colors.lightGray, colors.black)
  else
    placeAt("TOGGLE_DEBUG", 4, rowA, "SHOW", colors.lightGray, colors.black)
  end

  placeAt("RELOAD", 1, rowB, "RELOAD", colors.cyan, colors.black)
  placeAt("UP",     2, rowB, "UP", colors.lightBlue, colors.black)
  placeAt("DOWN",   3, rowB, "DOWN", colors.lightBlue, colors.black)
  placeAt("NOP",    4, rowB, "", colors.gray, colors.gray)
end

function M.draw(hw, modesErr, modeList, st, ctx, ruleLines, ruleMeta, errLines)
  if not mon.mon then return end
  local w, h = mon.size()

  btnReset()
  mon.clear(colors.black, colors.white)

  local headerH = 3
  local footerH = 4
  if h < 10 then footerH = 3 end

  local listW = math.max(18, math.floor(w * 0.40))
  listW = util.clamp(listW, 18, w - 14)

  local xList1, xList2 = 1, listW
  local xMain1, xMain2 = listW + 1, w

  local yHeader1, yHeader2 = 1, headerH
  local yBody1, yBody2 = headerH + 1, h - footerH
  local yFooter1, yFooter2 = h - footerH + 1, h

  -- header
  mon.set(colors.gray, colors.white)
  mon.fill(1, yHeader1, w, yHeader2, " ")
  mon.writeAt(2, 2, "Relay Controller (DSL)")

  local chip = st.paused and "PAUSED" or "RUNNING"
  local chipBg = st.paused and colors.orange or colors.green
  mon.set(chipBg, colors.black)
  local chipX2 = w - 2
  local chipX1 = util.clamp(chipX2 - (#chip + 3), 1, w)
  mon.fill(chipX1, 2, chipX2, 2, " ")
  mon.writeAt(chipX1 + 2, 2, chip)

  -- left list
  mon.set(colors.lightGray, colors.black)
  mon.fill(xList1, yBody1, xList2, yBody2, " ")
  mon.set(colors.gray, colors.white)
  mon.fill(xList1, yBody1, xList2, yBody1, " ")
  mon.writeAt(xList1 + 2, yBody1, "Modes")

  local listTop = yBody1 + 1
  local listBottom = yBody2
  local visible = math.max(1, listBottom - listTop + 1)
  ui.maxScroll = math.max(0, #modeList - visible)
  ui.modeScroll = util.clamp(ui.modeScroll, 0, ui.maxScroll)

  local startIdx = 1 + ui.modeScroll
  for rowY = listTop, listBottom do
    local idx = startIdx + (rowY - listTop)
    if idx > #modeList then break end

    local name = modeList[idx]
    local selected = (st.mode == name)

    if selected then
      mon.set(colors.blue, colors.white)
      mon.fill(xList1, rowY, xList2, rowY, " ")
    else
      mon.set(colors.lightGray, colors.black)
      mon.fill(xList1, rowY, xList2, rowY, " ")
    end

    local text = tostring(name)
    local maxLen = (xList2 - xList1 + 1) - 2
    if #text > maxLen then text = text:sub(1, maxLen - 1) .. "." end
    mon.writeAt(xList1 + 2, rowY, text)

    btnAdd("MODE_" .. tostring(idx), xList1, rowY, xList2, rowY, "", colors.black, colors.white)
  end

  -- footer
  mon.set(colors.gray, colors.white)
  mon.fill(1, yFooter1, w, yFooter2, " ")
  mon.writeAt(2, yFooter1, "Tap modes or buttons")

  local btnRow1 = yFooter1 + 1
  drawFooter2Rows(st, w, btnRow1, yFooter2)

  -- main console
  local padTop = 2
  local contentX1 = xMain1 + 2
  local contentX2 = xMain2 - 2
  local contentY1 = yBody1 + padTop
  local contentY2 = yBody2 - 1
  if contentY2 < contentY1 then contentY2 = contentY1 end

  local lines, meta = {}, {}

  table.insert(lines, "Mode: " .. tostring(st.mode)); meta[#lines] = { fg = colors.cyan }
  table.insert(lines, "Action: " .. tostring(st.seq_action or "(none)")); meta[#lines] = { fg = colors.lightBlue }

  local mod = (hw.time or {}).modulo_seconds
  local wt = tostring(ctx.worldNow)
  local src = tostring(ctx.worldSource or "")
  local syncTag = ctx.worldSyncOk and "[ok]" or "[fallback]"
  if type(mod) == "number" and mod > 0 then
    table.insert(lines, "World: " .. wt .. " (mod " .. tostring(mod) .. ") " .. syncTag .. " " .. src)
  else
    table.insert(lines, "World: " .. wt .. " " .. syncTag .. " " .. src)
  end
  meta[#lines] = { fg = colors.white }

  table.insert(lines, "Uptime(ms): " .. tostring(ctx.uptimeMs or 0)); meta[#lines] = { fg = colors.white }
  table.insert(lines, "EpochUTC(ms): " .. tostring(ctx.epochUtcMs or "nil")); meta[#lines] = { fg = colors.white }
  table.insert(lines, "Drift sec: " .. tostring(ctx.driftSec or 0)); meta[#lines] = { fg = colors.white }

  if st.action_entered_world then
    local passed = tim.diffSec(ctx.worldNow, st.action_entered_world, ctx.worldModulo)
    table.insert(lines, "In action sec: " .. tostring(passed)); meta[#lines] = { fg = colors.white }
  end

  if st.paused then
    table.insert(lines, "ENGINE: PAUSED"); meta[#lines] = { fg = colors.red }
  end

  if modesErr then
    table.insert(errLines, "DSL error: " .. tostring(modesErr))
  end

  if #errLines > 0 then
    table.insert(lines, ""); meta[#lines] = { fg = colors.white }
    table.insert(lines, "Errors:"); meta[#lines] = { fg = colors.red }
    for _, e in ipairs(errLines) do
      table.insert(lines, e)
      meta[#lines] = { fg = colors.red }
    end
  end

  if st.show_debug and #ruleLines > 0 then
    table.insert(lines, ""); meta[#lines] = { fg = colors.white }
    table.insert(lines, "Rules:"); meta[#lines] = { fg = colors.yellow }
    for i, rl in ipairs(ruleLines) do
      table.insert(lines, rl)
      meta[#lines] = ruleMeta[i] or { fg = colors.white }
    end
  end

  drawConsole(contentX1, contentY1, contentX2, contentY2, lines, meta)
end

return M
-- engine.lua (ascii only)

local util = require("relayctl.util")
local hwio = require("relayctl.hw")
local tim  = require("relayctl.time")

local M = {}

local function isRangeObj(v)
  return type(v) == "table" and type(v.min) == "number" and type(v.max) == "number"
end

local function cmpNum(a, op, b)
  if op == "==" then return a == b end
  if op == "!=" then return a ~= b end
  if op == ">"  then return a >  b end
  if op == ">=" then return a >= b end
  if op == "<"  then return a <  b end
  if op == "<=" then return a <= b end
  return false
end

local function matchSignal(actualAnalog, leaf)
  local expected = leaf.signal
  local op = leaf.op or "=="

  if op == "in" then
    if not isRangeObj(expected) then return false end
    return actualAnalog >= expected.min and actualAnalog <= expected.max
  end

  if type(expected) == "boolean" then
    local actualBool = actualAnalog > 0
    if op == "==" then return actualBool == expected end
    if op == "!=" then return actualBool ~= expected end
    return false
  end

  if type(expected) == "number" then
    local v = util.clamp(math.floor(expected + 0.5), 0, 15)
    return cmpNum(actualAnalog, op, v)
  end

  if isRangeObj(expected) then
    return actualAnalog >= expected.min and actualAnalog <= expected.max
  end

  return false
end

local function evalCondNode(node, ctx)
  if type(node) ~= "table" then return false end

  if type(node.if_and) == "table" then
    for _, c in ipairs(node.if_and) do
      if not evalCondNode(c, ctx) then return false end
    end
    return true
  end

  if type(node.if_or) == "table" then
    for _, c in ipairs(node.if_or) do
      if evalCondNode(c, ctx) then return true end
    end
    return false
  end

  if type(node.time_passed) == "number" then
    local passed = tim.diffSec(ctx.worldNow, ctx.actionEnteredWorld or ctx.worldNow, ctx.worldModulo)
    local need = math.max(0, math.floor(node.time_passed + 0.5))
    local op = node.op or ">="
    return cmpNum(passed, op, need)
  end

  if type(node.redstone_links) == "string" and node.signal ~= nil then
    local link = node.redstone_links
    local v, err = hwio.readLinkAnalog(link)
    if v == nil then
      ctx.lastError = "readLink failed: " .. tostring(err)
      return false
    end

    -- latch: if expecting true, allow latched signal
    if type(node.signal) == "boolean" and node.signal == true then
      if ctx.latched and ctx.latched[link] then
        return true
      end
    end

    return matchSignal(v, node)
  end

  return false
end

local function evalCondNodeTrace(node, ctx, out, depth)
  depth = depth or 0
  local pref = string.rep("  ", util.clamp(depth, 0, 6))

  if type(node) ~= "table" then
    table.insert(out, pref .. "COND invalid")
    return false
  end

  if type(node.if_and) == "table" then
    table.insert(out, pref .. "AND:")
    local allOk = true
    for _, c in ipairs(node.if_and) do
      local ok = evalCondNodeTrace(c, ctx, out, depth + 1)
      if not ok then allOk = false end
    end
    table.insert(out, pref .. "AND => " .. (allOk and "OK" or "NO"))
    return allOk
  end

  if type(node.if_or) == "table" then
    table.insert(out, pref .. "OR:")
    local anyOk = false
    for _, c in ipairs(node.if_or) do
      local ok = evalCondNodeTrace(c, ctx, out, depth + 1)
      if ok then anyOk = true end
    end
    table.insert(out, pref .. "OR => " .. (anyOk and "OK" or "NO"))
    return anyOk
  end

  if type(node.time_passed) == "number" then
    local passed = tim.diffSec(ctx.worldNow, ctx.actionEnteredWorld or ctx.worldNow, ctx.worldModulo)
    local need = math.max(0, math.floor(node.time_passed + 0.5))
    local op = node.op or ">="
    local ok = cmpNum(passed, op, need)
    table.insert(out, pref .. ("time_passed " .. op .. " " .. need .. " (now=" .. passed .. ") => " .. (ok and "OK" or "NO")))
    return ok
  end

  if type(node.redstone_links) == "string" and node.signal ~= nil then
    local link = node.redstone_links
    local v, err = hwio.readLinkAnalog(link)
    if v == nil then
      table.insert(out, pref .. (link .. " => READ FAIL: " .. tostring(err)))
      return false
    end

    local lat = (ctx.latched and ctx.latched[link]) and true or false
    local ok = false

    if type(node.signal) == "boolean" and node.signal == true and lat then
      ok = true
    else
      ok = matchSignal(v, node)
    end

    local op = node.op or "=="
    local exp = node.signal
    local expStr
    if type(exp) == "boolean" then expStr = tostring(exp)
    elseif type(exp) == "number" then expStr = tostring(exp)
    elseif isRangeObj(exp) then expStr = tostring(exp.min) .. ".." .. tostring(exp.max); op = "in"
    else expStr = "<bad>" end

    local latS = lat and " latched" or ""
    table.insert(out, pref .. (link .. " (now=" .. tostring(v) .. ")" .. latS .. " " .. op .. " " .. expStr .. " => " .. (ok and "OK" or "NO")))
    return ok
  end

  table.insert(out, pref .. "COND unknown")
  return false
end

local function buildModeIndex(modesCfg)
  local byName = {}
  for _, m in ipairs(modesCfg.all_modes or {}) do
    if m.mode_name then byName[m.mode_name] = m end
  end
  return byName
end

local function buildModeList(modesCfg)
  local lst = {}
  for _, m in ipairs(modesCfg.all_modes or {}) do
    if m.mode_name then table.insert(lst, m.mode_name) end
  end
  table.sort(lst, function(a,b) return tostring(a) < tostring(b) end)
  return lst
end

local function buildActionIndex(mode)
  local byId = {}
  for idx, step in ipairs(mode.sequence or {}) do
    if step.action then byId[step.action] = { idx = idx, step = step } end
  end
  return byId
end

function M.defaultState(modesCfg)
  return {
    mode = modesCfg.default_mode or "stop",
    seq_action = nil,
    seq_index = 1,
    action_initialized = false,
    action_entered_world = nil,
    paused = false,
    show_debug = true,
    last_ui_hit = nil,
    latched = {},
  }
end

function M.enterStop(st)
  st.mode = "stop"
  st.seq_action = nil
  st.seq_index = 1
  st.action_initialized = false
  st.action_entered_world = nil
  st.paused = false
  st.latched = {}
end

function M.switchModePaused(st, modesByName, modeName, worldNow)
  if modeName == "stop" then
    M.enterStop(st)
    return true
  end
  if not modesByName[modeName] then return false end

  st.mode = modeName
  st.seq_action = nil
  st.seq_index = 1
  st.action_initialized = false
  st.action_entered_world = worldNow
  st.paused = true
  st.latched = {}
  return true
end

local function applyActionInit(step)
  if type(step.action_initialization) ~= "table" then return true end
  for _, op in ipairs(step.action_initialization) do
    if type(op.redstone_links) == "string" then
      local ok, err = hwio.setLinkSignal(op.redstone_links, op.signal)
      if not ok then return false, err end
    end
  end
  return true
end

local function gotoAction(mode, actionIndex, st, targetActionId, worldNow)
  local info = actionIndex[targetActionId]
  if not info then
    hwio.ensureAllSafeZero()
    M.enterStop(st)
    return
  end
  st.seq_action = targetActionId
  st.seq_index = info.idx
  st.action_initialized = false
  st.action_entered_world = worldNow
  st.latched = {} -- consume latch on action change
end

-- Latch selected inputs (impulses)
function M.latchInputs(st, latchList)
  st.latched = st.latched or {}
  if type(latchList) ~= "table" then return end
  for _, link in ipairs(latchList) do
    if type(link) == "string" then
      local v = hwio.readLinkAnalog(link)
      if v ~= nil and v > 0 then
        st.latched[link] = true
      end
    end
  end
end

-- Engine tick (call from scheduler)
function M.tick(hw, modesErr, modesByName, st, ctx)
  if st.mode == "stop" or modesErr then
    hwio.ensureAllSafeZero()
    M.enterStop(st)
    return
  end

  local mode = modesByName[st.mode]
  if not mode then
    hwio.ensureAllSafeZero()
    M.enterStop(st)
    return
  end

  local seq = mode.sequence or {}
  if #seq == 0 then
    hwio.ensureAllSafeZero()
    M.enterStop(st)
    return
  end

  st.seq_index = util.clamp(tonumber(st.seq_index) or 1, 1, #seq)
  local step = seq[st.seq_index]

  if not st.seq_action then
    st.seq_action = step.action
    st.action_initialized = false
    st.action_entered_world = ctx.worldNow
  end

  if step.action ~= st.seq_action then
    local found = nil
    for idx, s in ipairs(seq) do
      if s.action == st.seq_action then found = idx break end
    end
    if found then
      st.seq_index = found
      step = seq[found]
    else
      hwio.ensureAllSafeZero()
      M.enterStop(st)
      return
    end
  end

  if not st.action_initialized then
    local ok, err = applyActionInit(step)
    if not ok then
      ctx.lastError = "Init failed: " .. tostring(err)
      st.paused = true
      return
    end
    st.action_initialized = true
    if not st.action_entered_world then st.action_entered_world = ctx.worldNow end
  end

  if type(step.goto_rules) == "table" then
    local actionIndex = buildActionIndex(mode)
    local entered = st.action_entered_world or ctx.worldNow
    local passed = tim.diffSec(ctx.worldNow, entered, ctx.worldModulo)
    local ctxEval = {
      worldNow = ctx.worldNow,
      actionEnteredWorld = entered,
      lastError = nil,
      worldModulo = ctx.worldModulo,
      latched = st.latched,
    }

    for _, rule in ipairs(step.goto_rules) do
      local wait = tonumber(rule.waiting_time) or 0
      if passed >= wait then
        local okCond = evalCondNode(rule.cond, ctxEval)
        if okCond and type(rule.goto_action) == "string" then
          gotoAction(mode, actionIndex, st, rule.goto_action, ctx.worldNow)
          break
        end
      end
    end

    if ctxEval.lastError then ctx.lastError = ctxEval.lastError end
  end
end

-- Debug rules builder
function M.buildRulesDebug(hw, modesErr, modesByName, st, ctx)
  local ruleLines, ruleMeta = {}, {}

  if modesErr or st.mode == "stop" then
    return ruleLines, ruleMeta
  end

  local mode = modesByName[st.mode]
  if not mode or type(mode.sequence) ~= "table" or #mode.sequence == 0 then
    return ruleLines, ruleMeta
  end

  local seq = mode.sequence
  local step = nil
  if st.seq_action then
    for _, s in ipairs(seq) do
      if s.action == st.seq_action then step = s break end
    end
  end
  if not step then step = seq[util.clamp(tonumber(st.seq_index) or 1, 1, #seq)] end
  if not step or type(step.goto_rules) ~= "table" then
    return ruleLines, ruleMeta
  end

  local entered = st.action_entered_world or ctx.worldNow
  local passed = tim.diffSec(ctx.worldNow, entered, ctx.worldModulo)
  local ctxEval = {
    worldNow = ctx.worldNow,
    actionEnteredWorld = entered,
    lastError = nil,
    worldModulo = ctx.worldModulo,
    latched = st.latched,
  }

  for ri, rule in ipairs(step.goto_rules) do
    local wait = tonumber(rule.waiting_time) or 0
    local waitOk = (passed >= wait)

    local trace = {}
    local condOk = evalCondNodeTrace(rule.cond, ctxEval, trace, 0)

    local head = string.format("#%d goto %s after %ds => WAIT:%s COND:%s",
      ri, tostring(rule.goto_action), wait,
      waitOk and "OK" or "NO",
      condOk and "OK" or "NO"
    )
    table.insert(ruleLines, head)

    if waitOk and condOk then
      ruleMeta[#ruleLines] = { fg = colors.lime }
    elseif waitOk and not condOk then
      ruleMeta[#ruleLines] = { fg = colors.yellow }
    else
      ruleMeta[#ruleLines] = { fg = colors.lightGray }
    end

    for ti = 1, math.min(#trace, 12) do
      table.insert(ruleLines, "  " .. trace[ti])
      local t = trace[ti]
      if t:find("=> OK", 1, true) then
        ruleMeta[#ruleLines] = { fg = colors.lime }
      elseif t:find("=> NO", 1, true) then
        ruleMeta[#ruleLines] = { fg = colors.red }
      else
        ruleMeta[#ruleLines] = { fg = colors.white }
      end
    end
    if #trace > 12 then
      table.insert(ruleLines, "  ...")
      ruleMeta[#ruleLines] = { fg = colors.lightGray }
    end
  end

  if ctxEval.lastError then
    ctx.lastError = tostring(ctxEval.lastError)
  end

  return ruleLines, ruleMeta
end

function M.buildModeIndex(modesCfg) return buildModeIndex(modesCfg) end
function M.buildModeList(modesCfg) return buildModeList(modesCfg) end

return M
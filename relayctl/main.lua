-- main.lua (ascii only)

local util = require("relayctl.util")
local tim  = require("relayctl.time")
local mon  = require("relayctl.monitor")
local hwio = require("relayctl.hw")
local dsl  = require("relayctl.dsl")
local eng  = require("relayctl.engine")
local ui   = require("relayctl.ui")

local PATH_HW    = "cfg_hardware.json"
local PATH_MODES = "cfg_modes.dsl"
local PATH_STATE = "tmp_state.json"

local hw = util.loadJsonOrDefault(PATH_HW, {})

-- init monitor (strict cfg-only)
mon.init(hw)

-- init hw mapping
hwio.init(hw)

-- load DSL
local modesCfg, modesErr = dsl.loadModesDslOrStop(PATH_MODES)
local modesByName = eng.buildModeIndex(modesCfg)
local modeList = eng.buildModeList(modesCfg)

-- state
local st = util.loadJsonOrDefault(PATH_STATE, eng.defaultState(modesCfg))
if st.show_debug == nil then st.show_debug = true end
if st.latched == nil then st.latched = {} end
if not st.mode then st.mode = modesCfg.default_mode or "stop" end
if st.mode ~= "stop" and not modesByName[st.mode] then st.mode = "stop" end

-- timings
local uiRefresh = tonumber(hw.ui_refresh_seconds) or tonumber(hw.refresh_seconds) or 0.2
local engineTick = tonumber(hw.engine_tick_seconds) or 0.2
if uiRefresh < 0.05 then uiRefresh = 0.05 end
if engineTick < 0.05 then engineTick = 0.05 end

-- latch list
local latchList = ((hw.time and hw.time.latch_inputs) or hw.latch_inputs) or {}

local ctx = {
  worldNow = 0,
  worldSyncOk = false,
  worldSource = "",
  driftSec = 0,
  lastError = nil,
  worldModulo = (hw.time or {}).modulo_seconds,
  uptimeMs = 0,
  epochUtcMs = nil,
}

local function saveState()
  util.saveJsonAtomic(PATH_STATE, st)
end

local function reloadDsl()
  local cfg, err = dsl.loadModesDslOrStop(PATH_MODES)
  modesCfg = cfg
  modesErr = err
  modesByName = eng.buildModeIndex(modesCfg)
  modeList = eng.buildModeList(modesCfg)

  local uiState = ui.getState()
  uiState.modeScroll = util.clamp(uiState.modeScroll, 0, uiState.maxScroll or 0)

  if st.mode ~= "stop" and not modesByName[st.mode] then
    hwio.ensureAllSafeZero()
    eng.enterStop(st)
  end
  saveState()
end

local function doStop()
  hwio.ensureAllSafeZero()
  eng.enterStop(st)
  saveState()
end

local function togglePause()
  st.paused = not st.paused
  saveState()
end

local function stepOnce()
  -- run one tick even if paused
  eng.tick(hw, modesErr, modesByName, st, ctx)
  saveState()
end

local function selectModeByIndex(idx)
  local name = modeList[idx]
  if not name then return end
  if eng.switchModePaused(st, modesByName, name, ctx.worldNow) then
    saveState()
  end
end

-- scheduler timers
local uiTimer = os.startTimer(uiRefresh)
local engineTimer = os.startTimer(engineTick)

local function updateTimeContext()
  ctx.uptimeMs = tim.uptimeMs()
  ctx.epochUtcMs = tim.epochUtcMs()

  local wNow, ok, source = tim.worldNow(hw.time or {})
  ctx.worldNow = wNow
  ctx.worldSyncOk = ok
  ctx.worldSource = source
  ctx.worldModulo = (hw.time or {}).modulo_seconds
end

local function drawFrame()
  local errLines = {}
  if ctx.lastError then table.insert(errLines, tostring(ctx.lastError)) end

  local ruleLines, ruleMeta = {}, {}
  if st.show_debug then
    ruleLines, ruleMeta = eng.buildRulesDebug(hw, modesErr, modesByName, st, ctx)
  end

  if mon.mon then
    ui.draw(hw, modesErr, modeList, st, ctx, ruleLines, ruleMeta, errLines)
  end
end

while true do
  updateTimeContext()
  drawFrame()

  local ev, p1, p2, p3 = os.pullEvent()

  if ev == "timer" and p1 == uiTimer then
    uiTimer = os.startTimer(uiRefresh)
    -- just redraw in next loop iteration

  elseif ev == "timer" and p1 == engineTimer then
    engineTimer = os.startTimer(engineTick)

    -- rebuild monitor aliases periodically (double-connect alias changes after relog)
    if mon.mon then
      mon.rebuildAliases()
    end

    -- latch impulses before tick
    eng.latchInputs(st, latchList)

    if not st.paused then
      eng.tick(hw, modesErr, modesByName, st, ctx)
      saveState()
    end

  elseif ev == "monitor_touch" then
    -- event: monitor_touch, monitorName, x, y
    if mon.mon and mon.acceptTouch(p1) then
      local x = tonumber(p2)
      local y = tonumber(p3)
      if x and y then
        local hit = ui.hit(x, y)
        if hit then
          st.last_ui_hit = hit
          saveState()

          if hit == "STOP" then
            doStop()
          elseif hit == "PAUSE_TOGGLE" then
            togglePause()
          elseif hit == "STEP" then
            stepOnce()
          elseif hit == "TOGGLE_DEBUG" then
            st.show_debug = not st.show_debug
            saveState()
          elseif hit == "RELOAD" then
            reloadDsl()
          elseif hit == "UP" then
            local u = ui.getState()
            u.modeScroll = util.clamp(u.modeScroll - 1, 0, u.maxScroll)
          elseif hit == "DOWN" then
            local u = ui.getState()
            u.modeScroll = util.clamp(u.modeScroll + 1, 0, u.maxScroll)
          else
            local idxStr = hit:match("^MODE_(%d+)$")
            if idxStr then
              selectModeByIndex(tonumber(idxStr))
            end
          end
        end
      end
    end

  elseif ev == "key" then
    local keyCode = p1
    if keyCode == keys.s then doStop() end
    if keyCode == keys.p then togglePause() end
    if keyCode == keys.r then reloadDsl() end
    if keyCode == keys.t then stepOnce() end
    if keyCode == keys.h then st.show_debug = not st.show_debug; saveState() end

  elseif ev == "peripheral" or ev == "peripheral_detach" then
    -- after relog peripherals can rebind names
    if mon.mon then mon.rebuildAliases() end
    hwio.init(hw)
  end
end
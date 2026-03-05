-- ultra_parallel_mover.lua
-- CC:Tweaked (ASCII only)
-- Parallel workers: each worker owns a stride of slots (i, i+W, i+2W, ...).
-- Workers run until a pass finishes or they error. They return true regardless (per your request).
-- No os.sleep() except:
--  1) missing container
--  2) right full / cannot accept
--  3) left empty
-- Only ONE print at end of pass or when sleep reason changes.
-- Peripherals may disappear; script must not crash.

----------------------------
-- Config
----------------------------
local CFG = {
  left  = "left",
  right = "right",

  sleepMissing = 0.2,
  sleepEmpty   = 0.2,
  sleepFull    = 0.2,

  workers = 8, -- set as you want (1..16 typically)
}

----------------------------
-- Cache + wrap
----------------------------
local cache = {
  leftP=nil, leftName=nil, leftId=nil,
  rightP=nil, rightName=nil, rightId=nil,
}

local function invalidate()
  cache.leftP, cache.leftName, cache.leftId = nil, nil, nil
  cache.rightP, cache.rightName, cache.rightId = nil, nil, nil
end

local function tryWrap(id)
  if not id then return nil end
  if not peripheral.isPresent(id) then return nil end
  local ok, p = pcall(peripheral.wrap, id)
  if ok and p then return p end
  return nil
end

local function getInvCached(id, which)
  if which == "left" then
    if cache.leftP and cache.leftId == id and peripheral.isPresent(id) then
      return cache.leftP, cache.leftName
    end
    local p = tryWrap(id)
    if not p then
      cache.leftP, cache.leftName, cache.leftId = nil, nil, nil
      return nil
    end
    local name = peripheral.getName(p)
    cache.leftP, cache.leftName, cache.leftId = p, name, id
    return p, name
  else
    if cache.rightP and cache.rightId == id and peripheral.isPresent(id) then
      return cache.rightP, cache.rightName
    end
    local p = tryWrap(id)
    if not p then
      cache.rightP, cache.rightName, cache.rightId = nil, nil, nil
      return nil
    end
    local name = peripheral.getName(p)
    cache.rightP, cache.rightName, cache.rightId = p, name, id
    return p, name
  end
end

----------------------------
-- Parallel pass
----------------------------
-- Returns movedTotal, sawAny, anyRejected, errMsgOrNil
local function parallelPass(leftInv, rightName, workers)
  local items = leftInv.list()
  if not items then return 0, false, false, nil end

  -- Build dense slot list once (so all workers share it)
  local slots = {}
  local n = 0
  for slot, _ in pairs(items) do
    n = n + 1
    slots[n] = slot
  end
  if n == 0 then
    return 0, false, false, nil
  end

  if workers < 1 then workers = 1 end
  if workers > n then workers = n end

  local movedBy = {}
  local rejBy = {}
  for i = 1, workers do
    movedBy[i] = 0
    rejBy[i] = false
  end

  -- Each worker: stride pattern, runs until done or crash; returns true anyway.
  local function makeWorker(i)
    return function()
      local moved = 0
      local rej = false

      local ok, _err = pcall(function()
        for idx = i, n, workers do
          local slot = slots[idx]
          local m = leftInv.pushItems(rightName, slot)
          if m and m > 0 then
            moved = moved + m
          else
            rej = true
          end
        end
      end)

      movedBy[i] = moved
      rejBy[i] = rej

      -- Per your request: always return true, even if crashed.
      return true
    end
  end

  local fns = {}
  for i = 1, workers do
    fns[i] = makeWorker(i)
  end

  -- If any worker errors internally, it is swallowed by its pcall and still returns true.
  parallel.waitForAll(table.unpack(fns))

  local total = 0
  local anyRejected = false
  for i = 1, workers do
    total = total + movedBy[i]
    if rejBy[i] then anyRejected = true end
  end

  return total, true, anyRejected, nil
end

----------------------------
-- Main loop
----------------------------
local lastSleepReason = nil

while true do
  local l, r, rName = nil, nil, nil

  local okWrap = pcall(function()
    l = getInvCached(CFG.left, "left")
    r, rName = getInvCached(CFG.right, "right")
  end)

  if (not okWrap) or (not l) or (not r) then
    invalidate()
    local reason = "SLEEP: missing inventory"
    if reason ~= lastSleepReason then
      print(reason)
      lastSleepReason = reason
    end
    os.sleep(CFG.sleepMissing)
  else
    local movedTotal, sawAny, anyRejected = 0, false, false
    local errMsg = nil

    local okPass, passErr = pcall(function()
      movedTotal, sawAny, anyRejected, errMsg = parallelPass(l, rName, CFG.workers)
    end)

    if not okPass then
      errMsg = tostring(passErr)
      invalidate()
      movedTotal, sawAny, anyRejected = 0, false, false
    end

    if not sawAny then
      local reason = "SLEEP: left is empty"
      if reason ~= lastSleepReason then
        print(reason)
        lastSleepReason = reason
      end
      os.sleep(CFG.sleepEmpty)

    elseif movedTotal == 0 and anyRejected then
      local reason = "SLEEP: right is full or cannot accept items"
      if reason ~= lastSleepReason then
        print(reason)
        lastSleepReason = reason
      end
      os.sleep(CFG.sleepFull)

    else
      local msg
      if errMsg then
        msg = ("PASS: moved=%d, itemsSeen=%s, note=error:%s"):format(movedTotal, tostring(sawAny), errMsg)
      else
        msg = ("PASS: moved=%d, itemsSeen=%s"):format(movedTotal, tostring(sawAny))
      end
      print(msg)
      lastSleepReason = nil
      -- no sleep
    end
  end
end
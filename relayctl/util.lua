-- util.lua (ascii only)

local M = {}

function M.clamp(n, a, b)
  if n < a then return a end
  if n > b then return b end
  return n
end

function M.fileExists(p)
  return fs.exists(p) and not fs.isDir(p)
end

function M.readAll(p)
  local f = fs.open(p, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

function M.writeAll(p, s)
  local f = fs.open(p, "w")
  if not f then return false end
  f.write(s or "")
  f.close()
  return true
end

function M.saveJsonAtomic(path, obj)
  local tmp = path .. ".tmp"
  local bak = path .. ".bak"
  local data = textutils.serializeJSON(obj, { pretty = true })

  if fs.exists(tmp) then fs.delete(tmp) end
  if not M.writeAll(tmp, data) then return false end

  if fs.exists(path) then
    if fs.exists(bak) then fs.delete(bak) end
    pcall(fs.copy, path, bak)
    pcall(fs.delete, path)
  end

  fs.move(tmp, path)
  return true
end

function M.loadJsonOrDefault(path, def)
  if not M.fileExists(path) then return def end
  local s = M.readAll(path)
  if not s then return def end
  local ok, obj = pcall(textutils.unserializeJSON, s)
  if not ok or obj == nil then return def end
  return obj
end

function M.safeCall(periph, method, ...)
  if not periph then return false, "nil peripheral" end
  if type(periph[method]) ~= "function" then
    return false, "missing method: " .. tostring(method)
  end
  local ok, res = pcall(periph[method], ...)
  if not ok then return false, res end
  return true, res
end

return M
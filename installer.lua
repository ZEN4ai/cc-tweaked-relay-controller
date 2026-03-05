-- installer.lua (ascii only)
-- Overwrites project files. Does NOT touch user configs by default.
-- Version tracking stored in relayctl/.install_meta.json.
-- Config is only URLs and simple flags.

----------------------------
-- Config
----------------------------
local REPO_RAW_BASE = "https://raw.githubusercontent.com/ZEN4ai/cc-tweaked-relay-controller/main"
-- Optional: GitHub API commit SHA for version tracking (set nil to disable).
local VERSION_URL   = "https://api.github.com/repos/ZEN4ai/cc-tweaked-relay-controller/commits/main"

local OVERWRITE_FILES  = true
local WRITE_STARTUP    = false
local INSTALL_CONFIGS  = false -- keep your local cfg untouched by default

local META_PATH = "relayctl/.install_meta.json"

----------------------------
-- Files  { "path remote",  "path local" }
----------------------------
local FILES_CORE = {
  { "relayctl/util.lua",    "relayctl/util.lua"    },
  { "relayctl/time.lua",    "relayctl/time.lua"    },
  { "relayctl/monitor.lua", "relayctl/monitor.lua" },
  { "relayctl/hw.lua",      "relayctl/hw.lua"      },
  { "relayctl/dsl.lua",     "relayctl/dsl.lua"     },
  { "relayctl/engine.lua",  "relayctl/engine.lua"  },
  { "relayctl/ui.lua",      "relayctl/ui.lua"      },
  { "relayctl/main.lua",    "relayctl/main.lua"    },
}

local FILES_CFG = {
  { "cfg_hardware.json", "cfg_hardware.json" },
  { "cfg_modes.dsl",     "cfg_modes.dsl"     },
}

----------------------------
-- Helpers
----------------------------
local function die(msg) error(msg, 0) end

local function httpGet(url, headers)
  if not http then die("http API not available") end
  if http.checkURL and http.checkURL(url) == false then
    die("URL blocked by http whitelist: " .. url)
  end

  local ok, resp = pcall(http.get, url, headers)
  if not ok or not resp then die("http.get failed: " .. url) end

  local code = resp.getResponseCode and resp.getResponseCode() or nil
  local body = resp.readAll()
  resp.close()

  if code and code ~= 200 then
    die("http status " .. tostring(code) .. " for " .. url)
  end
  if body == nil then die("empty response: " .. url) end
  return body
end

local function ensureDir(path)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

local function writeFile(path, data)
  ensureDir(path)
  local f = fs.open(path, "w")
  if not f then die("cannot write: " .. path) end
  f.write(data)
  f.close()
end

local function loadMeta()
  local s = readFile(META_PATH)
  if not s then return nil end
  local ok, obj = pcall(textutils.unserializeJSON, s)
  if not ok or type(obj) ~= "table" then return nil end
  return obj
end

local function saveMeta(meta)
  writeFile(META_PATH, textutils.serializeJSON(meta))
end

local function getRemoteSha()
  if not VERSION_URL then return nil end
  local headers = { ["User-Agent"] = "CC-Tweaked-Installer", ["Accept"] = "application/vnd.github+json" }
  local ok, body = pcall(httpGet, VERSION_URL, headers)
  if not ok or not body then return nil end
  local ok2, obj = pcall(textutils.unserializeJSON, body)
  if not ok2 or type(obj) ~= "table" then return nil end
  local sha = obj.sha
  if type(sha) ~= "string" or #sha < 7 then return nil end
  return sha
end

local function installList(list)
  for _, it in ipairs(list) do
    local remote = it[1]
    local localPath = it[2]
    local url = REPO_RAW_BASE .. "/" .. remote
    local data = httpGet(url)

    if OVERWRITE_FILES then
      writeFile(localPath, data)
    else
      if not fs.exists(localPath) then
        writeFile(localPath, data)
      end
    end
  end
end

local function maybeWriteStartup()
  if not WRITE_STARTUP then return end
  local startup = [[
-- auto-generated startup.lua
shell.run("relayctl/main.lua")
]]
  if OVERWRITE_FILES then
    writeFile("startup.lua", startup)
  else
    if not fs.exists("startup.lua") then writeFile("startup.lua", startup) end
  end
end

----------------------------
-- Main
----------------------------
local prev = loadMeta()
local prevSha = prev and prev.commit_sha or "none"

installList(FILES_CORE)
if INSTALL_CONFIGS then
  installList(FILES_CFG)
end
maybeWriteStartup()

local sha = nil
local okSha, resSha = pcall(getRemoteSha)
if okSha then sha = resSha end

saveMeta({
  repo_raw_base = REPO_RAW_BASE,
  commit_sha = sha,
  installed_utc_ms = (os.epoch and os.epoch("utc")) or nil,
  overwrite_files = OVERWRITE_FILES,
  write_startup = WRITE_STARTUP,
  install_configs = INSTALL_CONFIGS,
})

local newSha = sha or "unknown"
print("Installed. Version: " .. prevSha .. " -> " .. newSha)
-- installer.lua (ascii only)

----------------------------
-- Config
----------------------------
local REPO_RAW_BASE = "https://raw.githubusercontent.com/ZEN4ai/cc-tweaked-relay-controller/main"

local OVERWRITE_FILES = true
local INSTALL_CONFIGS_IF_MISSING = true


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
local function die(msg)
  error(msg, 0)
end

local function httpGet(url)
  if not http then die("http API not available") end
  if http.checkURL and http.checkURL(url) == false then
    die("URL blocked: " .. url)
  end

  local ok, resp = pcall(http.get, url)
  if not ok or not resp then
    die("http.get failed: " .. url)
  end

  local data = resp.readAll()
  resp.close()

  if not data then
    die("empty response: " .. url)
  end

  return data
end

local function ensureDir(path)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

local function writeFile(path, data)
  ensureDir(path)
  local f = fs.open(path, "w")
  if not f then die("cannot write: " .. path) end
  f.write(data)
  f.close()
end

----------------------------
-- Install
----------------------------
local downloaded = 0
local skipped = 0

local function installList(list, overwrite)
  for _, it in ipairs(list) do
    local remote = it[1]
    local localPath = it[2]

    if not overwrite and fs.exists(localPath) then
      skipped = skipped + 1
    else
      local url = REPO_RAW_BASE .. "/" .. remote
      local data = httpGet(url)
      writeFile(localPath, data)
      downloaded = downloaded + 1
    end
  end
end

-- core files
installList(FILES_CORE, OVERWRITE_FILES)

-- configs only if missing
if INSTALL_CONFIGS_IF_MISSING then
  installList(FILES_CFG, false)
end

print("Install done. downloaded=" .. downloaded .. " skipped=" .. skipped)
print("Run: relayctl/main.lua")
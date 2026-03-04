-- installer.lua (ascii only)
-- Downloads relay controller project from GitHub into /relayctl and creates startup.lua.

local REPO_RAW_BASE = "https://raw.githubusercontent.com/ZEN4ai/cc-tweaked-relay-controller/main"

local FILES = {
  { "relayctl/util.lua",    "relayctl/util.lua"    },
  { "relayctl/time.lua",    "relayctl/time.lua"    },
  { "relayctl/monitor.lua", "relayctl/monitor.lua" },
  { "relayctl/hw.lua",      "relayctl/hw.lua"      },
  { "relayctl/dsl.lua",     "relayctl/dsl.lua"     },
  { "relayctl/engine.lua",  "relayctl/engine.lua"  },
  { "relayctl/ui.lua",      "relayctl/ui.lua"      },
  { "relayctl/main.lua",    "relayctl/main.lua"    },
}

local function die(msg)
  error(msg, 0)
end

local function httpGet(url)
  if not http then die("http API not available") end
  if http.checkURL and http.checkURL(url) == false then
    die("URL blocked by http whitelist: " .. url)
  end
  local ok, resp = pcall(http.get, url)
  if not ok or not resp then die("http.get failed: " .. url) end
  local body = resp.readAll()
  resp.close()
  return body
end

local function ensureDir(path)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
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

local function install()
  for _, it in ipairs(FILES) do
    local remote = it[1]
    local localPath = it[2]
    local url = REPO_RAW_BASE .. "/" .. remote
    local data = httpGet(url)
    writeFile(localPath, data)
  end

  -- create startup.lua (overwrite is ok for installer; change if you want strict no-touch)
  local startup = [[
-- auto-generated startup.lua
shell.run("relayctl/main.lua")
]]
  writeFile("startup.lua", startup)
end

install()
print("Installed. Reboot or run: relayctl/main.lua")
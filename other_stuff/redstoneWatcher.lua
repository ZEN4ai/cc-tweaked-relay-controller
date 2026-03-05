-- config
-- wget https://raw.githubusercontent.com/ZEN4ai/cc-tweaked-relay-controller/other_stuff/other_stuff/redstoneWatcher.lua

local container = "left"     -- container side or peripheral name
local redstoneSide = "right" -- redstone output side

local inv = peripheral.wrap(container)

while true do
    local hasItem = false

    local items = inv.list()
    for _, item in pairs(items) do
        if item then
            hasItem = true
            break
        end
    end

    redstone.setOutput(redstoneSide, hasItem)

    os.sleep(0.5)
end
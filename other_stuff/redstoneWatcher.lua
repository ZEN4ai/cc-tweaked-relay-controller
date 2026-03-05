-- config
local container = "right"     -- container side or peripheral name
local redstoneSide = "top" -- redstone output side

local inv = peripheral.wrap(container)

while true do
    redstone.setOutput(redstoneSide, false)
    local items = inv.list()
    for _, item in pairs(items) do
        if item then
            redstone.setOutput(redstoneSide, true)
            break
        end
    end
    os.sleep(0.5)
end
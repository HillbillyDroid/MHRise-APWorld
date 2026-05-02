-- Multiplayer detection. v1 disables AP checks when the player is in a
-- multiplayer quest (>1 hunter) to sidestep host/guest license-state desync.
-- Soft gate at hook time: hunts in MP quests fire the death hook normally
-- but the check is dropped before sending.
local Session = {}

local lobby_manager = nil
local get_player_count_method = nil

local function resolve()
    if lobby_manager and get_player_count_method then return true end
    if not lobby_manager then
        lobby_manager = sdk.get_managed_singleton("snow.LobbyManager")
    end
    if not get_player_count_method then
        local td = sdk.find_type_definition("snow.LobbyManager")
        if td then get_player_count_method = td:get_method("getQuestPlayerCount") end
    end
    return lobby_manager ~= nil and get_player_count_method ~= nil
end

-- Returns: solo (bool), player_count (int|nil). Defaults solo=true on lookup
-- failure (fail-open: don't accidentally disable during normal play).
function Session.IsSolo()
    if not resolve() then return true, nil end
    local ok, count = pcall(function() return get_player_count_method:call(lobby_manager) end)
    if not ok or type(count) ~= "number" then return true, nil end
    return count <= 1, count
end

return Session

-- Tracks which items the player has received from the AP server.
-- v1 only cares about license items (one per huntable monster) and the
-- Victory item, but this module is the central place to handle any future
-- item types (filler, key items, etc.).
--
-- Soft gate: holding a license enables checks for that monster's hunt
-- locations. Hunting an unlicensed monster does nothing (the death hook
-- silently drops the event).
local Items = {}

-- Set of license item names the player holds. Keys are item names like
-- "Rathian License"; values are always true.
Items.held = {}

Items.has_victory = false

function Items.Reset()
    Items.held = {}
    Items.has_victory = false
end

function Items.Has(item_name)
    return Items.held[item_name] == true
end

local function send_chat(text)
    local chatman = sdk.get_managed_singleton("snow.gui.ChatManager")
    if not chatman then return end
    chatman:setChatNetworkInfomation(tostring(text), 0, 0, 3, false)
end

-- Called from the AP on_items_received callback. `items` is a list of
-- received item objects from APClientPP, each exposing :get_name().
-- AP occasionally re-sends items the player already holds (reconnect /
-- catch-up); the chat notification is suppressed in that case so the
-- player only sees a "Received" line for genuinely new items.
--
-- `silent`: when true, state still updates but no chat lines are
-- emitted. Used by the catch-up window right after slot_connect so the
-- chat doesn't get flooded with one "[AP] Received: X" per held item.
function Items.Receive(items, ap_client, silent)
    if type(items) ~= "table" then return 0 end
    local count = 0
    for _, item in ipairs(items) do
        local name = nil
        local ok, err = pcall(function()
            -- APClientPP item objects expose item id; resolve to name via
            -- the connected client's data package.
            local item_id = item.item or item:get_item()
            if ap_client and item_id then
                name = ap_client:get_item_name(item_id, ap_client:get_game())
            end
        end)
        if not ok then
            log.info("[Items] failed to resolve item name: " .. tostring(err))
        end
        if name then
            local is_new
            if name == "Victory" then
                is_new = not Items.has_victory
                Items.has_victory = true
            else
                is_new = not Items.held[name]
                Items.held[name] = true
            end
            if is_new then
                if not silent then
                    send_chat("[AP] Received: " .. name)
                end
                count = count + 1
            end
        end
    end
    return count
end

return Items

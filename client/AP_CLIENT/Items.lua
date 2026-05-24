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

-- Raw item IDs that arrived before APClientPP had the data package
-- ready to resolve them to names. The very first on_items_received
-- batch on a freshly-opened socket (which is where precollected items
-- like the starter unlock land) can fire before the package sync, in
-- which case get_item_name returns the literal "Unknown" string.
-- Without retry, the starter quest's `Unlock:` item never enters
-- Items.held and the tracker's Available section is empty. We stash
-- the raw ids here and re-resolve on on_data_package_changed and at
-- the start of every subsequent Items.Receive call.
Items.pending_ids = {}

function Items.Reset()
    Items.held = {}
    Items.has_victory = false
    Items.pending_ids = {}
end

function Items.Has(item_name)
    return Items.held[item_name] == true
end

local function send_chat(text)
    local chatman = sdk.get_managed_singleton("snow.gui.ChatManager")
    if not chatman then return end
    chatman:setChatNetworkInfomation(tostring(text), 0, 0, 3, false)
end

local function extract_item_id(item)
    local item_id = nil
    pcall(function() item_id = item.item or item:get_item() end)
    return item_id
end

local function resolve_id_to_name(ap_client, item_id)
    if not (ap_client and item_id) then return nil end
    local name = nil
    pcall(function()
        name = ap_client:get_item_name(item_id, ap_client:get_game())
    end)
    -- "Unknown" is APClientPP's unresolved-id sentinel — the data
    -- package hasn't caught up to this id yet.
    if name == "Unknown" then return nil end
    return name
end

-- Apply a successfully-resolved name to the held set. Returns true if
-- this was new state (i.e. worth a chat notification).
local function apply_resolved(name)
    if name == "Victory" then
        if Items.has_victory then return false end
        Items.has_victory = true
        return true
    end
    if Items.held[name] then return false end
    Items.held[name] = true
    return true
end

-- Retry name resolution for any ids that came in before APClientPP's
-- data package was ready. Called from on_data_package_changed (when
-- the package syncs after slot_connect) and at the head of every
-- subsequent Items.Receive call (belt-and-suspenders — a later batch
-- arriving with the same package update would also re-prime the
-- cache). Returns the number of newly-resolved items.
function Items.ResolvePending(ap_client, silent)
    if not ap_client then return 0 end
    if next(Items.pending_ids) == nil then return 0 end
    local count = 0
    local still_pending = {}
    for _, item_id in ipairs(Items.pending_ids) do
        local name = resolve_id_to_name(ap_client, item_id)
        if name then
            if apply_resolved(name) then
                if not silent then send_chat("[AP] Received: " .. name) end
                count = count + 1
            end
        else
            still_pending[#still_pending + 1] = item_id
        end
    end
    Items.pending_ids = still_pending
    if count > 0 then
        log.info(string.format(
            "[Items] resolved %d previously-pending item(s); %d still pending",
            count, #still_pending))
    end
    return count
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
    -- Retry any leftover ids before processing the new batch — a fresh
    -- batch can mean the data package just synced.
    Items.ResolvePending(ap_client, silent)
    local count = 0
    local deferred = 0
    for _, item in ipairs(items) do
        local item_id = extract_item_id(item)
        local name = resolve_id_to_name(ap_client, item_id)
        if name then
            if apply_resolved(name) then
                if not silent then send_chat("[AP] Received: " .. name) end
                count = count + 1
            end
        elseif item_id then
            -- Data package not yet ready for this id. Stash it; we'll
            -- resolve in on_data_package_changed or on the next batch.
            Items.pending_ids[#Items.pending_ids + 1] = item_id
            deferred = deferred + 1
        end
    end
    if deferred > 0 then
        log.info(string.format(
            "[Items] %d item(s) deferred pending data package sync", deferred))
    end
    return count
end

return Items

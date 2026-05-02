-- Caches per-session lookup tables built from slot_data on slot connect.
-- The apworld ships `monster_em_type_map` (item_name -> em_type); we
-- precompute the reverse (em_type -> item_name) so the death hook can
-- resolve a hunted monster's em_type back to a license item name in O(1).
local Lookups = {}

local Weapons = require("AP_CLIENT/Weapons")

Lookups.connected = false
Lookups.starting_monster = nil
Lookups.goal_monster = nil

-- item_name -> em_type (e.g. "Rathian License" -> 1)
Lookups.item_name_to_em_type = {}

-- em_type -> item_name (e.g. "1" -> "Rathian License").
-- KEYS ARE STRINGS, not integers. REFramework's Lua VM has been
-- observed to throw "invalid key to 'next'" when iterating int-keyed
-- tables, and `t[int]` lookups have likewise been observed to miss
-- entries that were stored via int-key assignment. String-keying both
-- writes and reads sidesteps both bugs.
Lookups.em_type_to_item_name = {}

function Lookups.Reset()
    Lookups.connected = false
    Lookups.starting_monster = nil
    Lookups.goal_monster = nil
    Lookups.item_name_to_em_type = {}
    Lookups.em_type_to_item_name = {}
    -- Reset Weapons cache too — kept on the Weapons module rather than
    -- here so Lookups stays monster-focused, but cleared in lockstep.
    Weapons.enabled = false
    Weapons.weapon_type_to_item_name = {}
    Weapons.starting_weapon = nil
end

-- Called from the on_slot_connected callback. slot_data contains:
--   monster_em_type_map:        {[item_name]: em_type}
--   starting_monster:           string
--   goal_monster:               string
--   include_sunbreak:           bool
--   include_weapons:            bool
--   weapon_type_to_item_name:   {[weapon_type]: item_name}  (when enabled)
--   starting_weapon:            string                        (when enabled)
function Lookups.Load(slot_data)
    Lookups.Reset()
    if type(slot_data) ~= "table" then
        return false, "slot_data is not a table"
    end

    local em_map = slot_data.monster_em_type_map
    if type(em_map) ~= "table" then
        return false, "slot_data.monster_em_type_map missing"
    end

    -- Forward map (string-keyed by license name) keeps em_type as a
    -- number for its consumers. Reverse map keys by tostring(em_type)
    -- to keep all REFramework-Lua tables string-keyed (see comment on
    -- Lookups.em_type_to_item_name above).
    for item_name, em_type in pairs(em_map) do
        local n = type(em_type) == "number" and em_type or tonumber(em_type)
        if n ~= nil then
            Lookups.item_name_to_em_type[item_name] = n
            Lookups.em_type_to_item_name[tostring(n)] = item_name
        end
    end

    Lookups.starting_monster = slot_data.starting_monster
    Lookups.goal_monster = slot_data.goal_monster

    if slot_data.include_weapons then
        Weapons.enabled = true
        local wmap = slot_data.weapon_type_to_item_name
        if type(wmap) == "table" then
            -- Store with string keys (see comment on
            -- Lookups.em_type_to_item_name above for why). JSON keys
            -- arrive as strings already; just pass them through.
            for k, v in pairs(wmap) do
                Weapons.weapon_type_to_item_name[tostring(k)] = v
            end
        end
        Weapons.starting_weapon = slot_data.starting_weapon
    end

    Lookups.connected = true
    return true
end

function Lookups.GetItemNameByEmType(em_type)
    -- String-keyed reverse map; coerce to string for lookup.
    return Lookups.em_type_to_item_name[tostring(em_type)]
end

function Lookups.GetEmTypeByItemName(item_name)
    return Lookups.item_name_to_em_type[item_name]
end

return Lookups

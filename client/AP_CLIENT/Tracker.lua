-- In-game tracker UI. Imgui window divided into four sections:
--   Available Monsters / Available Weapons (when enabled) /
--   Hunted Monsters / Locked Monsters.
--
-- Visibility is owned by Tracker.visible. Auto-flipped to true on
-- successful slot_connect (see MHRiseAP.lua), reset to false on
-- disconnect. The user can also toggle via a REFramework overlay
-- checkbox.
local Tracker = {}

local Items = require("AP_CLIENT/Items")
local Lookups = require("AP_CLIENT/Lookups")
local Weapons = require("AP_CLIENT/Weapons")

Tracker.visible = false
-- Per-slot check ledger: monster_name -> { ["1"] = true, ["2"] = true }.
-- A monster only counts as hunted when BOTH slots are present. Each
-- monster has two AP locations — Hunt X (1/2) and Hunt X (2/2) — that
-- need to be checked individually. A single check (e.g. another world
-- releasing one of our locations to us) does NOT make the monster
-- hunted; only when both locations have been registered, by any
-- combination of self-hunt + release, does it move into Hunted.
--
-- Two paths populate this ledger:
--   1. Self-hunts: Tracker.MarkHunted(monster_name) marks BOTH slots
--      at once, called from Monsters.lua after a successful
--      LocationChecks send. AP doesn't reliably echo our own checks
--      back via on_location_checked, so the local mark is the
--      authoritative path for self-hunts.
--   2. Other-world releases: Tracker.NoteLocationChecked(loc_id)
--      marks one slot at a time, called from on_location_checked.
--      This handles the case where another player's release sends
--      one of our hunt locations back to us.
--
-- (String-keyed inner sets per the int-keyed-table gotcha in
-- CLAUDE.md.)
Tracker.checked = {}

local function license_to_name(item_name)
    return item_name:match("^(.*) License$") or item_name
end

local function note_check(monster, slot)
    if type(monster) ~= "string" or monster == "" then return end
    if type(slot) ~= "string" or slot == "" then return end
    local entry = Tracker.checked[monster]
    if not entry then
        entry = {}
        Tracker.checked[monster] = entry
    end
    entry[slot] = true
end

local function is_fully_hunted(monster)
    local entry = Tracker.checked[monster]
    return entry ~= nil and entry["1"] == true and entry["2"] == true
end

function Tracker.NoteLocationChecked(loc_id)
    local AP_REF = _G.AP_REF
    if not AP_REF or not AP_REF.APClient then return end
    local game = AP_REF.APClient:get_game()
    local ok, loc_name = pcall(function()
        return AP_REF.APClient:get_location_name(loc_id, game)
    end)
    if not ok or type(loc_name) ~= "string" then return end
    local monster, slot = loc_name:match("^Hunt (.*) %((%d+)/%d+%)$")
    if monster and slot then note_check(monster, slot) end
end

function Tracker.MarkHunted(monster_name)
    if type(monster_name) ~= "string" or monster_name == "" then return end
    -- A self-hunt sends both (1/2) and (2/2) in the same LocationChecks
    -- call, so mark both slots in one shot.
    note_check(monster_name, "1")
    note_check(monster_name, "2")
end

function Tracker.Reset()
    Tracker.checked = {}
    Tracker.visible = false
end

-- Build the four section lists. Cheap (≤72 monsters + 14 weapons) so
-- it's fine to recompute every frame; no caching needed in v1.
local function build_sections()
    local available_monsters = {}
    local available_weapons = {}
    local hunted = {}
    local locked = {}

    -- Iterate the string-keyed forward map (item_name -> em_type)
    -- rather than the int-keyed reverse map. REFramework's Lua VM
    -- has been observed to throw "invalid key to 'next'" when
    -- iterating int-keyed tables here; string keys traverse cleanly.
    for license_name, _ in pairs(Lookups.item_name_to_em_type) do
        local name = license_to_name(license_name)
        if is_fully_hunted(name) then
            hunted[#hunted + 1] = name
        elseif Items.Has(license_name) or name == Lookups.starting_monster then
            available_monsters[#available_monsters + 1] = name
        else
            locked[#locked + 1] = name
        end
    end

    if Weapons.enabled then
        -- Iterate the string-keyed Items.held set. Anything in there
        -- that isn't a known monster license is a weapon license.
        -- Then add the precollected starter weapon (which doesn't
        -- arrive via items_received).
        local saw_starter = false
        for license_name, _ in pairs(Items.held) do
            if Lookups.item_name_to_em_type[license_name] == nil then
                local name = license_to_name(license_name)
                if name == Weapons.starting_weapon then saw_starter = true end
                available_weapons[#available_weapons + 1] = name
            end
        end
        if Weapons.starting_weapon and not saw_starter then
            available_weapons[#available_weapons + 1] = Weapons.starting_weapon
        end
    end

    table.sort(available_monsters)
    table.sort(available_weapons)
    table.sort(hunted)
    table.sort(locked)
    return available_monsters, available_weapons, hunted, locked
end

local function draw_section(label, items)
    imgui.text(label)
    imgui.separator()
    if #items == 0 then
        imgui.text("  (none)")
    else
        for _, item in ipairs(items) do
            imgui.text("  " .. item)
        end
    end
    imgui.text("")  -- blank line between sections
end

local logged_draw_error = false
function Tracker.Draw()
    if not Tracker.visible then return end
    if not Lookups.connected then return end
    -- Only render while the REFramework overlay is open. Mirrors the
    -- gate AP_REF/core.lua uses for its own window via UpdateBehavior.
    if not reframework:is_drawing_ui() then return end

    -- Build sections OUTSIDE the imgui begin/end pair so a bad table
    -- iteration can't leave imgui in a half-open state.
    local av_m, av_w, hu, lo
    local build_ok, build_err = pcall(function()
        av_m, av_w, hu, lo = build_sections()
    end)
    if not build_ok then
        if not logged_draw_error then
            log.info("[Tracker] build_sections error: " .. tostring(build_err))
            logged_draw_error = true
        end
        return
    end

    local ok, err = pcall(function()
        imgui.set_next_window_size(Vector2f.new(320, 500), 4)
        Tracker.visible = imgui.begin_window("MH Rise AP Tracker", Tracker.visible, nil)
        if Tracker.visible then
            draw_section("Available Monsters", av_m)
            if Weapons.enabled then
                draw_section("Available Weapons", av_w)
            end
            draw_section("Hunted Monsters", hu)
            draw_section("Locked Monsters", lo)
        end
        imgui.end_window()
    end)
    if not ok and not logged_draw_error then
        log.info("[Tracker] draw error: " .. tostring(err))
        logged_draw_error = true
    end
end

return Tracker

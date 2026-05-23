-- Quest randomizer mode. Three hooks:
--
-- 1. snow.QuestManager.initQuestDataDictionary (post): walk
--    Lookups.quest_swaps and mutate each affected QuestData's
--    _BossEmType[0] / _TgtEmType[0] via array:call("Set", 0, em_type)
--    (RiseQuestLoader idiom validated by Probe 3).
-- 2. snow.progress.quest.ProgressQuestManager.checkUnlockCondition
--    (pre+post): rewrite the bool return per the AP unlock state so
--    locked quests disappear from the village board.
-- 3. snow.QuestManager.setQuestClear (no args, post): on a successful
--    clear, send the matching `Clear: <name>` location to AP.
--
-- All three are gated on Lookups.mode == "quest_rando".
--
-- See QUEST.md "Stage 1 spike — *" sections for the per-hook research
-- and QUEST_PLAN.md "Stage 2" for the integration plan.
local Quests = {}

local Lookups = require("AP_CLIENT/Lookups")
local Items = require("AP_CLIENT/Items")
local Session = require("AP_CLIENT/Session")
local Tracker = require("AP_CLIENT/Tracker")

Quests.hooks_installed = false
Quests.swaps_applied = false
Quests.swap_attempts = 0
Quests.last_swap_log = {}  -- recent (qn, em) entries, capped
Quests.completion_log = {} -- recent cleared quest_nos, capped

-- checkUnlockCondition pre-hook captures the queried quest_no into
-- this slot; post-hook reads it. Same single-threaded UI path Probe 2b
-- used. Reset on each pre fire.
local last_check_unlock_qn = nil

local function send_chat(text)
    local chatman = sdk.get_managed_singleton("snow.gui.ChatManager")
    if not chatman then return end
    chatman:setChatNetworkInfomation(tostring(text), 0, 0, 3, false)
end

-- ---------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------

-- Walk a NormalQuestData/Kohaku _Param array on QuestManager, calling
-- visitor(elem, quest_no) for every element. Stops early if visitor
-- returns true.
local function visit_param_array(field_name, visitor)
    local qm = sdk.get_managed_singleton("snow.QuestManager")
    if not qm then return false end
    local container = nil
    pcall(function() container = qm:get_field(field_name) end)
    if not container then return false end
    local arr = nil
    pcall(function() arr = container:get_field("_Param") end)
    if not arr then return false end
    local count = nil
    pcall(function() count = arr:read_dword(0x1c) end)
    if not count or count <= 0 then return false end
    for i = 0, count - 1 do
        local elem = nil
        pcall(function() elem = arr:call("get_Item", i) end)
        if elem then
            local qn = nil
            pcall(function() qn = elem:get_field("_QuestNo") end)
            if qn and visitor(elem, qn) then return true end
        end
    end
    return false
end

local function apply_swap_to_param(param, em_type, quest_no)
    local boss = nil
    local tgt = nil
    pcall(function() boss = param:get_field("_BossEmType") end)
    pcall(function() tgt = param:get_field("_TgtEmType") end)
    if not boss or not tgt then
        log.info(string.format(
            "[Quests] qn=%d: missing _BossEmType / _TgtEmType", quest_no))
        return false
    end
    local ok_boss = pcall(function() boss:call("Set", 0, em_type) end)
    local ok_tgt = pcall(function() tgt:call("Set", 0, em_type) end)
    if not ok_boss or not ok_tgt then
        -- Fallback to direct dword write (legacy path; Probe 3 noted
        -- this isn't needed on current builds but keep as belt-and-
        -- suspenders).
        pcall(function() boss:write_dword(0x20, em_type) end)
        pcall(function() tgt:write_dword(0x20, em_type) end)
    end
    return true
end

-- Apply every (quest_no, em_type) in Lookups.quest_swaps to the
-- in-memory QuestData entries. Walks the normal catalog first
-- (base + HR), then Kohaku (MR) so quests from either source are
-- reachable.
function Quests.ApplySwaps()
    if Lookups.mode ~= "quest_rando" then return 0 end
    Quests.swap_attempts = Quests.swap_attempts + 1

    -- Build a lookup of quest_no -> em_type. quest_swaps is keyed by
    -- string in slot_data; coerce keys to numbers once here so the
    -- in-game _QuestNo number lookups land directly.
    local pending = {}
    local total = 0
    for qn_str, em in pairs(Lookups.quest_swaps or {}) do
        local n = tonumber(qn_str)
        local em_n = type(em) == "number" and em or tonumber(em)
        if n and em_n then
            pending[n] = em_n
            total = total + 1
        end
    end
    if total == 0 then return 0 end

    local applied = 0
    Quests.last_swap_log = {}
    for _, container_name in ipairs({"_normalQuestData", "_nomalQuestDataKohaku"}) do
        visit_param_array(container_name, function(elem, qn)
            local em = pending[qn]
            if em then
                if apply_swap_to_param(elem, em, qn) then
                    applied = applied + 1
                    Quests.last_swap_log[#Quests.last_swap_log + 1] =
                        string.format("  qn=%d em=%d", qn, em)
                    pending[qn] = nil
                end
            end
            return false
        end)
    end

    Quests.swaps_applied = applied == total
    log.info(string.format(
        "[Quests] applied %d/%d swaps (attempt %d)",
        applied, total, Quests.swap_attempts))
    if applied < total then
        local missing = {}
        for qn, _ in pairs(pending) do missing[#missing + 1] = tostring(qn) end
        log.info("[Quests] missing quest_nos: " .. table.concat(missing, ", "))
    end
    return applied
end

-- Convenience for the catch-up flow: if the QuestManager singleton is
-- already initialized when we receive slot_data (typical case — slot
-- connect happens after the player has loaded a save), apply swaps
-- immediately instead of waiting for initQuestDataDictionary to refire.
function Quests.ApplySwapsIfReady()
    local qm = sdk.get_managed_singleton("snow.QuestManager")
    if not qm then return end
    Quests.ApplySwaps()
end

-- ---------------------------------------------------------------
-- Completion -> AP location send
-- ---------------------------------------------------------------

-- Returns the current active quest's quest_no (the catalog _QuestNo
-- the slot_data quest_swaps and quest_unlocks tables are keyed by).
-- Probe 1b validated this matches the catalog. Returns nil if no
-- active quest.
local function get_active_quest_no()
    local qm = sdk.get_managed_singleton("snow.QuestManager")
    if not qm then return nil end
    local qd = nil
    pcall(function() qd = qm:call("getActiveQuestData") end)
    if not qd then return nil end
    local qn = nil
    pcall(function() qn = qd:call("getQuestNo") end)
    if type(qn) == "number" then return qn end
    return nil
end

local function on_quest_cleared()
    if Lookups.mode ~= "quest_rando" then return end
    -- Solo gate, same defensive check as Monsters.lua. Village quests
    -- are solo by design so this should almost always be true.
    local solo, count = Session.IsSolo()
    if not solo then
        log.info(string.format(
            "[Quests] skipped clear-check (multiplayer quest, %d players)",
            count or -1))
        return
    end

    local qn = get_active_quest_no()
    if not qn then
        log.info("[Quests] setQuestClear fired but no active quest_no")
        return
    end

    -- Only quests in the seed have a Clear: <name> location. Hub /
    -- rampage / event quests fire the same hook but aren't in
    -- slot_data — silently drop.
    local unlock_name = Lookups.quest_unlocks[tostring(qn)]
    if not unlock_name then
        log.info(string.format(
            "[Quests] cleared qn=%d not in seed — skipping", qn))
        return
    end
    local quest_display_name = Lookups.quest_names[tostring(qn)] or tostring(qn)
    local loc_name = "Clear: " .. quest_display_name

    local AP_REF = _G.AP_REF
    if not AP_REF or not AP_REF.APClient then return end
    local game = AP_REF.APClient:get_game()
    local loc_id = AP_REF.APClient:get_location_id(loc_name, game)
    if not loc_id or loc_id <= 0 then
        log.info(string.format(
            "[Quests] no location id for '%s'", loc_name))
        return
    end

    local ok = AP_REF.APClient:LocationChecks({loc_id})
    if ok then
        Tracker.MarkQuestCleared(qn)
        Quests.completion_log[#Quests.completion_log + 1] = qn
        send_chat(string.format("[AP] Sent check: Clear %s", quest_display_name))
        log.info(string.format(
            "[Quests] sent clear check for qn=%d (%s) id=%d",
            qn, quest_display_name, loc_id))
    else
        log.info(string.format(
            "[Quests] LocationChecks failed for qn=%d", qn))
    end
end

-- ---------------------------------------------------------------
-- Hook install
-- ---------------------------------------------------------------

local function install_init_dict_hook()
    local td = sdk.find_type_definition("snow.QuestManager")
    if not td then return false, "QuestManager type not found" end
    local method = td:get_method("initQuestDataDictionary")
    if not method then return false, "initQuestDataDictionary not found" end
    local ok, err = pcall(function()
        sdk.hook(method,
            function(args) end,
            function(retval)
                local hok, herr = pcall(Quests.ApplySwaps)
                if not hok then
                    log.info("[Quests] initQuestDataDictionary post error: " .. tostring(herr))
                end
                return retval
            end)
    end)
    if not ok then return false, tostring(err) end
    return true
end

local function install_check_unlock_hook()
    local td = sdk.find_type_definition("snow.progress.quest.ProgressQuestManager")
    if not td then return false, "ProgressQuestManager type not found" end
    local method = td:get_method("checkUnlockCondition(snow.quest.QuestNo)")
    if not method then return false, "checkUnlockCondition not found" end
    local ok, err = pcall(function()
        sdk.hook(method,
            function(args)
                -- args[1]=this, args[2]=quest_no enum (i32-backed).
                -- Coerce to Lua int IN the pre — the raw pointer
                -- isn't safe across function return.
                local qn = nil
                pcall(function() qn = sdk.to_int64(args[3]) end)
                last_check_unlock_qn = qn
            end,
            function(retval)
                local qn = last_check_unlock_qn
                if qn == nil or Lookups.mode ~= "quest_rando" then
                    return retval
                end
                local unlock_name = Lookups.quest_unlocks[tostring(qn)]
                if unlock_name == nil then
                    -- Not in seed — let the engine answer normally.
                    return retval
                end
                -- In-seed quest: visibility = unlock-item held OR
                -- this is the precollected starter quest.
                local held = Items.Has(unlock_name)
                local is_starter = (qn == Lookups.starting_quest)
                if held or is_starter then
                    return sdk.to_ptr(1)
                end
                return sdk.to_ptr(0)
            end)
    end)
    if not ok then return false, tostring(err) end
    return true
end

local function install_completion_hook()
    local td = sdk.find_type_definition("snow.QuestManager")
    if not td then return false, "QuestManager type not found" end
    local method = td:get_method("setQuestClear")
    if not method then return false, "setQuestClear not found" end
    local ok, err = pcall(function()
        sdk.hook(method,
            function(args)
                local hok, herr = pcall(on_quest_cleared)
                if not hok then
                    log.info("[Quests] setQuestClear pre error: " .. tostring(herr))
                end
            end,
            function(retval) return retval end)
    end)
    if not ok then return false, tostring(err) end
    return true
end

function Quests.InstallHooks()
    if Quests.hooks_installed then return end

    local ok1, err1 = install_init_dict_hook()
    log.info("[Quests] initQuestDataDictionary hook: " ..
        (ok1 and "ok" or ("fail — " .. tostring(err1))))

    local ok2, err2 = install_check_unlock_hook()
    log.info("[Quests] checkUnlockCondition hook: " ..
        (ok2 and "ok" or ("fail — " .. tostring(err2))))

    local ok3, err3 = install_completion_hook()
    log.info("[Quests] setQuestClear hook: " ..
        (ok3 and "ok" or ("fail — " .. tostring(err3))))

    Quests.hooks_installed = ok1 and ok2 and ok3

    -- If the player is already in-game when slot connects (typical
    -- flow — connect happens after save load), the
    -- initQuestDataDictionary hook won't fire again at load. Apply
    -- swaps immediately so the player doesn't need to title-screen
    -- back out.
    Quests.ApplySwapsIfReady()
end

return Quests

-- MRSpike — research spike for Sunbreak (Master Rank) accessibility on a
-- fresh save (gh #24). Split out from QuestRandoSpike.lua (already too
-- big); same conventions, self-contained.
--
-- Question: what minimal engine writes let a FRESH save reach the Elgado
-- Outpost (kohaku hub) and take/clear Master Rank quests? Two gates:
--   1. story/rank progression (HR->MR transition flags), and
--   2. AREA access (Elgado is a separate hub a fresh save can't travel to).
--
-- Prior art (Silvris/MHRSArchipelago SaveHooks.cs): on registerDataOnSave
-- it forces ProgressQuestManager.setClear(QN010702 /*end of HR*/, true)
-- plus ProgressEventFlag _VillageEndStoryFlag / _HallEndStoryFlag. No
-- Elgado/area code exists in any prior art — Probe C is the real unknown.
--
-- Probes:
--   A — Baseline state dump (READ-ONLY). Run on fresh / post-HR / mid-MR
--       saves; diff reveals which bits flip on the real HR->MR transition.
--   B — Rank/quest unlock WRITES (throwaway save): the Silvris recipe,
--       applied incrementally, re-dumping after each.
--   C — Elgado / area access: reflect for the hub/travel manager + flags,
--       write candidates, verify travel in-game. THE main unknown.
--   D — MR quest clear + swap viability sanity (read-only observation).
--
-- WRITES ARE DESTRUCTIVE. Throwaway save only — back it up first.
--
-- Dev-only. Drop into <install>/reframework/autorun/. No AP connection
-- needed. Never bundled into the player client zip (release workflow's
-- AUTORUN_FILES allow-list excludes debug_tools/).
-- Output: <install>/reframework/data/mr_spike_*.json
--
-- Trigger: REFramework overlay button "MHRise MR Spike".

if reframework:get_game_name() ~= "mhrise" then return end

log.info("[mr-spike] Loading...")

local LOG_TAG = "[mr-spike] "
local function log_info(msg) log.info(LOG_TAG .. msg) end

local function safe_str(v)
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "<tostring error>"
end

local state = { is_window_open = false }

-- Lowest EnemyLv.Master quest_no in ap_world/data/quests.py — the sample
-- "is an MR quest takeable yet?" probe target. QuestNo is i32-backed so a
-- raw int is accepted by REFramework's coercion.
local MR_SAMPLE_QUEST_NO = 315100  -- "Uninvited Guest" (QL1 Master)
-- End-of-HR urgent; clearing it is Silvris's HR->MR trigger.
local HR_END_QUEST_NO = 10702      -- QN010702 "Serpent Goddess of Thunder"

-- Candidate types to reflect for the Elgado/MR hub gate (consumed by both
-- Probe A's snapshot and Probe C's drilldown). Refined as the spike runs.
local PROBEC_TYPES = {
    "snow.progress.ProgressEventFlag",
    "snow.progress.quest.ProgressQuestManager",
    "snow.SnowGameStateManager",
    "snow.stage.StageManager",
    "snow.stage.StageDef",
    "snow.gui.fsm.MenuFunctions",
}

-- =====================================================================
-- Shared reflection helpers
-- =====================================================================

local function get_singleton(name)
    return sdk.get_managed_singleton(name)
end

-- Enumerate every field {name, is_literal, value?} on a type. For static
-- literals we read the value; instance fields just record the name (their
-- per-object value is read separately against a live singleton).
local function dump_type_fields(type_name)
    local out = {}
    local td = sdk.find_type_definition(type_name)
    if not td then return out, false end
    local fields = nil
    pcall(function() fields = td:get_fields() end)
    if not fields then return out, true end
    for _, f in ipairs(fields) do
        local entry = { name = "?" }
        pcall(function() entry.name = f:get_name() end)
        pcall(function() entry.is_static = f:is_static() end)
        pcall(function() entry.is_literal = f:is_literal() end)
        pcall(function()
            local ft = f:get_type()
            if ft then entry.type = ft:get_full_name() end
        end)
        if entry.is_literal then
            pcall(function()
                local v = f:get_data(nil)
                if type(v) == "number" or type(v) == "boolean" then
                    entry.literal_value = v
                end
            end)
        end
        out[#out + 1] = entry
    end
    return out, true
end

-- Read an instance field value off a live object (handles non-primitive
-- by recording its tostring). Returns value or nil.
local function read_instance_field(obj, field_name)
    if not obj then return nil end
    local v = nil
    local ok = pcall(function() v = obj:get_field(field_name) end)
    if not ok then return nil end
    return v
end

local function list_methods_matching(type_name, substr)
    local out = {}
    local td = sdk.find_type_definition(type_name)
    if not td then return out end
    local methods = nil
    pcall(function() methods = td:get_methods() end)
    if not methods then return out end
    local low = substr:lower()
    for _, m in ipairs(methods) do
        local nm = nil
        pcall(function() nm = m:get_name() end)
        if nm and nm:lower():find(low, 1, true) then
            out[#out + 1] = nm
        end
    end
    return out
end

-- =====================================================================
-- Probe A — Baseline state dump (READ-ONLY)
-- =====================================================================
--
-- Captures, for diffing fresh-vs-progressed saves:
--   ProgressEventFlag : every field + (where resolvable) live getFlag value
--   ProgressQuestManager : calc*Progress() values, getQuestClearCount,
--                          isClear(HR end), isUnlock/checkUnlock(MR sample)
--   candidate area/hub manager fields (see PROBEC_TYPES)
-- Tag each dump with a free-text save label so the JSON files are
-- self-identifying when diffed later.

local probeA = {
    log = {},
    last = nil,
    save_label = "unlabeled",  -- editable in code; describe the save state
}

local function probeA_push(s)
    probeA.log[#probeA.log + 1] = s
    log_info(s)
end

-- ProgressEventFlag: resolve the getFlag/setFlag methods once. The flag
-- fields are instance fields holding flag handles; getFlag takes the
-- handle and returns its bool. We snapshot every *StoryFlag/*Flag field by
-- reading the handle off the singleton then calling getFlag on it.
local function probeA_progress_event_flag()
    local out = { fields = {}, flags = {} }
    local type_name = "snow.progress.ProgressEventFlag"
    local fields, found = dump_type_fields(type_name)
    out.type_found = found
    out.fields = fields

    local sing = get_singleton(type_name)
    out.singleton_available = sing ~= nil
    if not sing then return out end

    local td = sdk.find_type_definition(type_name)
    local get_flag = nil
    if td then
        pcall(function() get_flag = td:get_method("getFlag") end)
    end
    out.get_flag_resolved = get_flag ~= nil

    -- For every field whose name looks like a flag handle, read the handle
    -- and try getFlag on it.
    for _, f in ipairs(fields) do
        local nm = f.name
        if nm and nm:find("Flag") then
            local handle = read_instance_field(sing, nm)
            local val = nil
            if handle ~= nil and get_flag then
                pcall(function() val = get_flag:call(sing, handle) end)
            end
            out.flags[nm] = {
                handle = (type(handle) == "number") and handle or safe_str(handle),
                value = val,
            }
        end
    end

    -- ProgressFlags is a TalkFlag[] — the bulk story-flag table. TalkFlag is
    -- a managed type wrapping an int flag-id; getFlag wants that INT (the
    -- individual _*StoryFlag fields read as ints — 45/46/108 — and getFlag
    -- on those worked). Array GetValue returns the TalkFlag object, so we
    -- pull the int id out of it first. Dump TalkFlag's fields once so we
    -- know the id accessor, then per element: read id, call getFlag(id).
    out.talkflag_fields = ({ dump_type_fields("snow.npc.TalkFlag") })[1]
    out.progress_flags_array = {}
    local arr = read_instance_field(sing, "ProgressFlags")
    if arr ~= nil then
        local n = nil
        pcall(function() n = arr:call("get_Length") end)
        if type(n) ~= "number" then pcall(function() n = arr:read_dword(0x1c) end) end
        out.progress_flags_count = (type(n) == "number") and n or "unreadable"
        if type(n) == "number" and n > 0 and n < 5000 then
            for i = 0, n - 1 do
                local el = nil
                pcall(function() el = arr:call("GetValue", i) end)
                if el == nil then pcall(function() el = arr:get_element(i) end) end
                local id, vv = nil, nil
                if el ~= nil then
                    -- el may already be an int (unboxed) or a TalkFlag object.
                    if type(el) == "number" then
                        id = el
                    else
                        -- try common id field names; record whichever reads.
                        for _, fn in ipairs({ "_Value", "value__", "_Id",
                            "_Flag", "_FlagId", "m_value" }) do
                            local v = nil
                            pcall(function() v = el:get_field(fn) end)
                            if type(v) == "number" then id = v; break end
                        end
                        -- fallback: read first dword of the object payload.
                        if id == nil then
                            pcall(function() id = el:read_dword(0x10) end)
                        end
                    end
                    if get_flag and id ~= nil then
                        pcall(function() vv = get_flag:call(sing, id) end)
                    end
                    -- also try passing the object straight through.
                    if vv == nil and get_flag then
                        pcall(function() vv = get_flag:call(sing, el) end)
                    end
                end
                out.progress_flags_array[#out.progress_flags_array + 1] =
                    { i = i, id = id, value = vv }
            end
        end
    end
    return out
end

local function probeA_progress_quest_manager()
    local out = {}
    local type_name = "snow.progress.quest.ProgressQuestManager"
    local sing = get_singleton(type_name)
    out.singleton_available = sing ~= nil
    out.calc_progress_methods = list_methods_matching(type_name, "Progress")
    if not sing then return out end

    local td = sdk.find_type_definition(type_name)
    local function call0(method_name)
        local m = nil
        pcall(function() m = td:get_method(method_name) end)
        if not m then return nil end
        local v = nil
        pcall(function() v = m:call(sing) end)
        return v
    end
    local function call1(method_name, arg)
        local m = nil
        pcall(function() m = td:get_method(method_name) end)
        if not m then return nil end
        local v = nil
        pcall(function() v = m:call(sing, arg) end)
        return v
    end

    out.calcVillageProgress = call0("calcVillageProgress")
    -- HR hub / MR progress analogs — names guessed; whichever resolves
    -- non-nil is the real one (recorded for the writeup).
    out.calcHallProgress = call0("calcHallProgress")
    out.calcKohakuProgress = call0("calcKohakuProgress")
    out.calcMasterRankProgress = call0("calcMasterRankProgress")
    out.getQuestClearCount = call0("getQuestClearCount")

    -- isClear read false even on a full MR save with the UInt32 overload;
    -- try the QuestNo-enum overload too (and record which one answered).
    out.isClear_HR_end_u32 = call1("isClear(System.UInt32)", HR_END_QUEST_NO)
    out.isClear_HR_end_qn = call1("isClear(snow.quest.QuestNo)", HR_END_QUEST_NO)
    out.isUnlock_MR_sample = call1("isUnlock(System.UInt32)", MR_SAMPLE_QUEST_NO)
    out.checkUnlock_MR_sample =
        call1("checkUnlockCondition(snow.quest.QuestNo)", MR_SAMPLE_QUEST_NO)
    -- MR tier oracle directly (whatever QuestCategory MR uses, swept in B).
    return out
end

local function probeA_area_managers()
    -- Snapshot every candidate area/hub/travel type's fields (read-only).
    local out = {}
    for _, tn in ipairs(PROBEC_TYPES) do
        local fields, found = dump_type_fields(tn)
        out[tn] = {
            type_found = found,
            singleton_available = get_singleton(tn) ~= nil,
            field_count = #fields,
            kohaku_fields = {},   -- name-matched hits (kohaku/elgado/master/...)
            all_fields = {},      -- full field list (capped) for eyeballing
        }
        for _, f in ipairs(fields) do
            local nm = f.name or ""
            local low = nm:lower()
            if low:find("kohaku") or low:find("elgado") or low:find("master")
                or low:find("outpost") or low:find("unlock") or low:find("open")
                or low:find("release") or low:find("warp") or low:find("travel") then
                out[tn].kohaku_fields[#out[tn].kohaku_fields + 1] = f
            end
            if #out[tn].all_fields < 200 then
                out[tn].all_fields[#out[tn].all_fields + 1] =
                    string.format("%s : %s%s%s", nm, f.type or "?",
                        f.is_literal and (" [lit=" .. safe_str(f.literal_value) .. "]") or "",
                        f.is_static and " [static]" or "")
            end
        end
    end
    return out
end

local function probeA_capture()
    local payload = {
        source = "MRSpike.lua / Probe A baseline (READ-ONLY)",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        save_label = probeA.save_label,
        progress_event_flag = probeA_progress_event_flag(),
        progress_quest_manager = probeA_progress_quest_manager(),
        area_managers = probeA_area_managers(),
    }
    probeA.last = payload
    probeA_push("Captured baseline (label=" .. probeA.save_label .. ")")
    return payload
end

local function probeA_dump()
    if not probeA.last then probeA_capture() end
    local fname = "mr_spike_baseline_" ..
        (probeA.save_label:gsub("[^%w]", "_")) .. ".json"
    local ok = json.dump_file(fname, probeA.last, 4)
    if ok then probeA_push("Wrote " .. fname)
    else probeA_push("json.dump_file FAILED for " .. fname) end
end

-- =====================================================================
-- Probe B — Rank/quest unlock WRITES (throwaway save)
-- =====================================================================
--
-- The Silvris recipe, applied incrementally. After each, re-capture
-- Probe A and eyeball the MR-sample accessibility + the boards in-game.

local probeB = {
    log = {},
    -- MR quest category value (Village=0 per gh #23). The Hall/MR value is
    -- resolved from snow.quest.QuestCategory at first write.
    categories = nil,
}

local function probeB_push(s)
    probeB.log[#probeB.log + 1] = s
    log_info(s)
end

local function probeB_resolve_categories()
    if probeB.categories then return probeB.categories end
    probeB.categories = {}
    local td = sdk.find_type_definition("snow.quest.QuestCategory")
    if not td then
        probeB_push("QuestCategory type not found")
        return probeB.categories
    end
    local fields = nil
    pcall(function() fields = td:get_fields() end)
    if fields then
        for _, f in ipairs(fields) do
            local is_lit = false
            pcall(function() is_lit = f:is_literal() end)
            if is_lit then
                local nm, val = nil, nil
                pcall(function() nm = f:get_name() end)
                pcall(function() val = f:get_data(nil) end)
                if type(val) == "number" then
                    probeB.categories[nm or "?"] = val
                end
            end
        end
    end
    local parts = {}
    for k, v in pairs(probeB.categories) do parts[#parts+1] = k.."="..v end
    probeB_push("QuestCategory: " .. table.concat(parts, " "))
    return probeB.categories
end

local function probeB_pqm()
    return get_singleton("snow.progress.quest.ProgressQuestManager")
end

-- Step 1: setClear(QN010702, true).
local function probeB_set_hr_cleared()
    local pqm = probeB_pqm()
    if not pqm then probeB_push("PQM singleton unavailable (load a save)"); return end
    local td = sdk.find_type_definition("snow.progress.quest.ProgressQuestManager")
    local m = nil
    pcall(function() m = td:get_method("setClear(System.UInt32, System.Boolean)") end)
    if not m then
        pcall(function() m = td:get_method("setClear(snow.quest.QuestNo, System.Boolean)") end)
    end
    if not m then probeB_push("setClear not resolved"); return end
    local ok, err = pcall(function() m:call(pqm, HR_END_QUEST_NO, true) end)
    if ok then probeB_push("setClear(" .. HR_END_QUEST_NO .. ", true) OK")
    else probeB_push("setClear threw: " .. safe_str(err)) end
end

-- Step 2: setFlag(_VillageEndStoryFlag, true) + setFlag(_HallEndStoryFlag, true).
-- Silvris used `false` inside an `if (!getFlag)` (looks like a bug) — we
-- test `true`.
local function probeB_set_end_story_flags()
    local type_name = "snow.progress.ProgressEventFlag"
    local sing = get_singleton(type_name)
    if not sing then probeB_push("ProgressEventFlag singleton unavailable"); return end
    local td = sdk.find_type_definition(type_name)
    local set_flag = nil
    pcall(function() set_flag = td:get_method("setFlag") end)
    if not set_flag then probeB_push("setFlag not resolved"); return end
    for _, fname in ipairs({ "_VillageEndStoryFlag", "_HallEndStoryFlag" }) do
        local handle = read_instance_field(sing, fname)
        if handle == nil then
            probeB_push("field " .. fname .. " unreadable")
        else
            local ok, err = pcall(function() set_flag:call(sing, handle, true) end)
            if ok then probeB_push("setFlag(" .. fname .. ", true) OK")
            else probeB_push("setFlag(" .. fname .. ") threw: " .. safe_str(err)) end
        end
    end
end

-- Read-back: is the MR sample quest now takeable, and what do the MR-tier
-- oracles say (swept across every QuestCategory at QL1)?
local function probeB_readback()
    local cats = probeB_resolve_categories()
    local pqm = probeB_pqm()
    local out = { categories = cats, mr_sample = {} }
    if not pqm then probeB_push("PQM unavailable for readback"); return out end
    local td = sdk.find_type_definition("snow.progress.quest.ProgressQuestManager")
    local function call1(sig, a)
        local m = nil; pcall(function() m = td:get_method(sig) end)
        if not m then return nil end
        local v = nil; pcall(function() v = m:call(pqm, a) end); return v
    end
    local function callcl(sig, c, l)
        local m = nil; pcall(function() m = td:get_method(sig) end)
        if not m then return nil end
        local v = nil; pcall(function() v = m:call(pqm, c, l) end); return v
    end
    out.mr_sample.isUnlock = call1("isUnlock(System.UInt32)", MR_SAMPLE_QUEST_NO)
    out.mr_sample.isClear = call1("isClear(System.UInt32)", MR_SAMPLE_QUEST_NO)
    out.mr_sample.checkUnlock =
        call1("checkUnlockCondition(snow.quest.QuestNo)", MR_SAMPLE_QUEST_NO)
    out.urgent_by_category = {}
    for name, val in pairs(cats) do
        out.urgent_by_category[name] = {
            -- QL1 = 0 (QuestLevel int from quests.py: QL1..QL7 = 0..6).
            isUnlockUrgent_QL1 = callcl(
                "isUnlockUrgent(snow.quest.QuestCategory, snow.quest.QuestLevel)", val, 0),
            isClearUrgent_QL1 = callcl(
                "isClearUrgent(snow.quest.QuestCategory, snow.quest.QuestLevel)", val, 0),
        }
    end
    probeB_push("Readback: MR sample isUnlock=" ..
        safe_str(out.mr_sample.isUnlock) .. " checkUnlock=" ..
        safe_str(out.mr_sample.checkUnlock))
    return out
end

local function probeB_dump_readback()
    local payload = {
        source = "MRSpike.lua / Probe B readback",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        readback = probeB_readback(),
    }
    local ok = json.dump_file("mr_spike_probeB_readback.json", payload, 4)
    if ok then probeB_push("Wrote mr_spike_probeB_readback.json")
    else probeB_push("json.dump_file FAILED") end
end

-- =====================================================================
-- Probe C — Elgado / area access (THE main unknown)
-- =====================================================================
--
-- No prior art. Strategy: reflect candidate managers for kohaku/elgado/
-- master fields (Probe A already snapshots these), surface the matches in
-- the UI, and give a free-text type/field/method search so the tester can
-- chase the travel-destination gate live. Writes are left as a generic
-- "set instance bool field" helper since the exact field is unknown until
-- found.

local probeC = {
    log = {},
    search_type = "snow.npc.TalkFlag",
    search_kw = "EV_PRO_MR_001",
    search_result = "",
    -- generic write target
    write_type = "snow.progress.ProgressEventFlag",
    write_field = "",
    write_value = true,
    -- raw-id flag write (the MR story flags 423+ have NO named field on
    -- ProgressEventFlag — they're TalkFlag enum ids. setFlag takes the int).
    flag_id = 423,        -- EV_PRO_MR_001_01_01 (Sunbreak intro / Elgado)
    flag_value = true,
}

local function probeC_push(s)
    probeC.log[#probeC.log + 1] = s
    log_info(s)
end

-- ProgressEventFlag getFlag/setFlag resolved once, called with a raw int id.
local function probeC_flag_methods()
    local td = sdk.find_type_definition("snow.progress.ProgressEventFlag")
    local gf, sf = nil, nil
    if td then
        pcall(function() gf = td:get_method("getFlag") end)
        pcall(function() sf = td:get_method("setFlag") end)
    end
    return gf, sf
end

-- Read getFlag(id) for a raw id.
local function probeC_read_flag_id(id)
    local sing = get_singleton("snow.progress.ProgressEventFlag")
    if not sing then return nil end
    local gf = probeC_flag_methods()
    if not gf then return nil end
    local v = nil
    pcall(function() v = gf:call(sing, id) end)
    return v
end

-- Write setFlag(id, value) for a raw id; reads back to confirm.
local function probeC_write_flag_id(id, value)
    local sing = get_singleton("snow.progress.ProgressEventFlag")
    if not sing then probeC_push("ProgressEventFlag singleton unavailable"); return end
    local gf, sf = probeC_flag_methods()
    if not sf then probeC_push("setFlag not resolved"); return end
    local ok, err = pcall(function() sf:call(sing, id, value) end)
    if not ok then probeC_push(string.format("setFlag(%d) threw: %s", id, safe_str(err))); return end
    local rb = nil
    if gf then pcall(function() rb = gf:call(sing, id) end) end
    probeC_push(string.format("setFlag(%d, %s) OK  readback=%s",
        id, tostring(value), safe_str(rb)))
end

-- Set the whole MR_001 intro cluster (Sunbreak opening) true.
local MR001_CLUSTER = { 423,424,425,426,427,428,429,430,431,432,
                        433,434,435,436,437,438,439,640 }
local function probeC_write_mr001_cluster(value)
    for _, id in ipairs(MR001_CLUSTER) do probeC_write_flag_id(id, value) end
    probeC_push("MR_001 cluster write done (" .. #MR001_CLUSTER .. " flags)")
end

-- Mark HR/village complete (the three confirmed end/start flags).
local HR_DONE_FLAGS = { 45, 46, 108 }  -- VILL_end, HALL_start, HALL_end
local function probeC_write_hr_done(value)
    for _, id in ipairs(HR_DONE_FLAGS) do probeC_write_flag_id(id, value) end
    probeC_push("HR-done flags write done (45/46/108)")
end

-- =====================================================================
-- Run 8: BULK FLAG MIRROR (the safe alternative to leaf-flag forcing).
-- =====================================================================
-- The entire story-flag state is ProgressEventFlagSaveData._Flag : uint32[]
-- (a bitmap). getAllFlag() reads it; setAllFlag() (no-arg) commits SaveData
-- ._Flag back into the live runtime. So:
--   capture: on a DONE save, getAllFlag() -> dump uint32[] to JSON.
--   install: on throwaway save, overwrite _Flag with the captured array,
--            setAllFlag() to commit, updateProgress(All) to recompute
--            HR/MR progress. No per-flag ordering -> sidesteps the Run 5
--            crash. Then check Elgado travel.
-- Bitmap file: <data>/mr_spike_flag_blob.json

local MR_FLAG_BLOB_FILE = "mr_spike_flag_blob.json"

local function probeC_pef()
    return get_singleton("snow.progress.ProgressEventFlag")
end

local function probeC_read_all_flags()
    local sing = probeC_pef()
    if not sing then return nil, "no ProgressEventFlag singleton" end
    local td = sdk.find_type_definition("snow.progress.ProgressEventFlag")
    local m = nil
    pcall(function() m = td:get_method("getAllFlag") end)
    if not m then return nil, "getAllFlag not resolved" end
    local arr = nil
    pcall(function() arr = m:call(sing) end)
    if not arr then return nil, "getAllFlag returned nil" end
    local n = nil
    pcall(function() n = arr:call("get_Length") end)
    if type(n) ~= "number" then pcall(function() n = arr:read_dword(0x1c) end) end
    if type(n) ~= "number" then return nil, "length unreadable" end
    local out = {}
    for i = 0, n - 1 do
        local v = nil
        pcall(function() v = arr:call("GetValue", i) end)
        if type(v) ~= "number" then pcall(function() v = arr:read_dword(0x20 + i*4) end) end
        out[#out + 1] = v
    end
    return out
end

-- CAPTURE: dump the live flag bitmap to JSON (run on a DONE/mr save).
local function probeC_capture_flag_blob()
    local blob, err = probeC_read_all_flags()
    if not blob then probeC_push("capture failed: " .. safe_str(err)); return end
    local payload = {
        source = "MRSpike.lua / flag blob capture",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        save_label = probeA.save_label,
        length = #blob,
        flag = blob,
    }
    -- Write to a label-derived file so captures never clobber the canonical
    -- blobs (mr / synth / trimmed). Falls back to the fixed name if no label.
    local label = probeA.save_label
    local fname = (label and label ~= "")
        and ("mr_spike_flag_blob_" .. label .. ".json")
        or MR_FLAG_BLOB_FILE
    local ok = json.dump_file(fname, payload, 4)
    if ok then probeC_push(string.format(
        "captured flag blob: %d words (label=%s) -> %s",
        #blob, label, fname))
    else probeC_push("json.dump_file FAILED for blob") end
end

-- TRIMMED blob install: a synthetic "just arrived at Elgado" bitmap built
-- offline (PowerShell, real bit ops) from the captured mr blob — keeps
-- VILL/HALL/MR_001, clears MR_002..MR_006 so no MR6 urgents show.
-- id->bit mapping CONFIRMED: word=id>>5, bit=id&31 (LE; 34 words=1088 bits).
-- Install reads this file instead of the raw capture.
local TRIMMED_BLOB_FILE = "mr_spike_flag_blob_trimmed.json"

-- SYNTHETIC sparse blob: only the minimal ids needed are set, all else 0.
-- Built offline (PowerShell real bit ops). Hyp1 = {2,45,46,108} + MR_001
-- (423-439,640). Unlike the trimmed blob (which was an all-ones region up to
-- 439, over-setting every VILL/HALL flag -> broke the village counter), this
-- leaves the VILL/HALL progression flags ALONE except the 3 HR-done markers.
local SYNTH_BLOB_FILE = "mr_spike_flag_blob_synth.json"

-- Resolve ProgressUpdateFilter "all"/max value (for updateProgress).
local function probeC_progress_update_filter_all()
    local td = sdk.find_type_definition("snow.progress.ProgressUpdateFilter")
    if not td then return nil end
    local fields = nil
    pcall(function() fields = td:get_fields() end)
    local best_name, best_val = nil, nil
    if fields then
        for _, f in ipairs(fields) do
            local is_lit = false
            pcall(function() is_lit = f:is_literal() end)
            if is_lit then
                local nm, val = nil, nil
                pcall(function() nm = f:get_name() end)
                pcall(function() val = f:get_data(nil) end)
                if type(val) == "number" then
                    -- prefer an explicit "All"/"ALL"; else the max value.
                    if nm and nm:lower():find("all") then return val, nm end
                    if best_val == nil or val > best_val then best_val = val; best_name = nm end
                end
            end
        end
    end
    return best_val, best_name
end

local function probeC_update_progress()
    local sing = get_singleton("snow.progress.ProgressManager")
    if not sing then probeC_push("no ProgressManager singleton"); return end
    local td = sdk.find_type_definition("snow.progress.ProgressManager")
    local m = nil
    pcall(function() m = td:get_method("updateProgress(snow.progress.ProgressUpdateFilter)") end)
    if not m then pcall(function() m = td:get_method("updateProgress") end) end
    if not m then probeC_push("updateProgress not resolved"); return end
    local filter, fname = probeC_progress_update_filter_all()
    if filter == nil then filter = 0 end
    local ok, err = pcall(function() m:call(sing, filter) end)
    if ok then probeC_push(string.format("updateProgress(%s=%s) OK",
        tostring(fname), tostring(filter)))
    else probeC_push("updateProgress threw: " .. safe_str(err)) end
end

-- INSTALL: write captured bitmap into live _Flag, commit, recompute.
-- DESTRUCTIVE — throwaway save only. `fname` defaults to the raw capture;
-- pass TRIMMED_BLOB_FILE to install the synthetic "arrived at Elgado" state.
local function probeC_install_flag_blob(fname)
    fname = fname or MR_FLAG_BLOB_FILE
    local data = json.load_file(fname)
    if not data or not data.flag then
        probeC_push("no blob file (" .. fname .. ") — capture/build first")
        return
    end
    probeC_push("installing blob from " .. fname)
    local blob = data.flag
    local sing = probeC_pef()
    if not sing then probeC_push("no ProgressEventFlag singleton"); return end

    -- Get the live SaveData._Flag array to overwrite in place.
    local td = sdk.find_type_definition("snow.progress.ProgressEventFlag")
    local get_sd = nil
    pcall(function() get_sd = td:get_method("get_SaveData") end)
    local sd = nil
    if get_sd then pcall(function() sd = get_sd:call(sing) end) end
    if not sd then probeC_push("get_SaveData returned nil"); return end
    local arr = nil
    pcall(function() arr = sd:get_field("_Flag") end)
    if not arr then probeC_push("_Flag field nil"); return end

    local n = nil
    pcall(function() n = arr:call("get_Length") end)
    if type(n) ~= "number" then pcall(function() n = arr:read_dword(0x1c) end) end
    if type(n) ~= "number" then probeC_push("_Flag length unreadable"); return end
    if n ~= #blob then
        probeC_push(string.format(
            "WARNING length mismatch: live=%d blob=%d (writing min) — flag layout differs?",
            n, #blob))
    end
    -- Snapshot helper: read all live _Flag words + getMrLatestStoryFlag.
    -- Lets us pinpoint which step (write / setAllFlag / updateProgress)
    -- introduces a bogus value (e.g. mrLatest=946 the blob never set).
    local function snapshot()
        local words = {}
        for i = 0, n - 1 do
            local w = nil
            pcall(function() w = arr:read_dword(0x20 + i*4) end)
            words[#words + 1] = w
        end
        local mrl = nil
        local mm = nil
        pcall(function() mm = td:get_method("getMrLatestStoryFlag") end)
        if mm then pcall(function() mrl = mm:call(sing) end) end
        return words, mrl
    end

    local words_before, mrl_before = snapshot()

    local count = math.min(n, #blob)
    local wrote, failed = 0, 0
    for i = 0, count - 1 do
        local v = blob[i + 1]
        -- uint32[] elements pack at +0x20 (len at +0x1c) — proven layout
        -- (QuestTargetSwap). Direct dword write is primary; SetValue
        -- fallback. Only write differing words to minimise churn.
        local cur = nil
        pcall(function() cur = arr:read_dword(0x20 + i*4) end)
        if cur ~= v then
            local ok = pcall(function() arr:write_dword(0x20 + i*4, v) end)
            if not ok then ok = pcall(function() arr:call("SetValue", v, i) end) end
            if ok then wrote = wrote + 1 else failed = failed + 1 end
        end
    end
    probeC_push(string.format("_Flag overwrite: %d wrote, %d failed", wrote, failed))

    local words_after_write, mrl_after_write = snapshot()

    -- DO NOT call setAllFlag(): it is "set ALL flags true" (debug unlock-
    -- everything), NOT "commit SaveData". Readback proved it floods _Flag to
    -- all-ones (mrLatest 439->946), clobbering our write. We write _Flag
    -- directly (it IS the runtime backing store — getMrLatestStoryFlag reads
    -- 439 from it after_write), so no commit call is needed.
    local words_after_setall, mrl_after_setall = words_after_write, mrl_after_write

    probeC_update_progress()

    local words_after_update, mrl_after_update = snapshot()

    -- Dump the three-stage readback so we can see exactly where a bogus
    -- value enters (instead of squinting at the imgui log).
    json.dump_file("mr_spike_install_readback.json", {
        source = "MRSpike.lua / install three-stage readback",
        blob_file = fname,
        blob_flag = blob,
        wrote = wrote, failed = failed,
        mrLatest = {
            before = mrl_before,
            after_write = mrl_after_write,
            after_setAllFlag = mrl_after_setall,
            after_updateProgress = mrl_after_update,
        },
        flag_words = {
            before = words_before,
            after_write = words_after_write,
            after_setAllFlag = words_after_setall,
            after_updateProgress = words_after_update,
        },
    }, 4)
    probeC_push(string.format(
        "mrLatest: before=%s afterWrite=%s afterSetAll=%s afterUpdate=%s",
        safe_str(mrl_before), safe_str(mrl_after_write),
        safe_str(mrl_after_setall), safe_str(mrl_after_update)))
    probeC_push("INSTALL done — wrote mr_spike_install_readback.json")
end

-- ---------------------------------------------------------------------
-- Run 6: forcing flags crashes (engine guards setFlag + faults on desync).
-- Instead, OBSERVE the legit transition. Read-only hook on setFlag logs
-- every (id, value) the ENGINE sets — so a normal HR→MR advance (or save
-- load) reveals the exact ordered flag sequence + lets us find the real
-- "advance progression" caller. Also a TalkFlag id→name reverse map for
-- readable logs.
-- ---------------------------------------------------------------------

probeC.flag_names = nil       -- id -> "EV_PRO_..."
probeC.setflag_hooked = false
probeC.setflag_log = {}       -- ring of { t, id, name, value }
probeC.setflag_count = 0

local function probeC_build_flag_names()
    if probeC.flag_names then return probeC.flag_names end
    probeC.flag_names = {}
    local td = sdk.find_type_definition("snow.npc.TalkFlag")
    if not td then return probeC.flag_names end
    local fields = nil
    pcall(function() fields = td:get_fields() end)
    if fields then
        for _, f in ipairs(fields) do
            local is_lit = false
            pcall(function() is_lit = f:is_literal() end)
            if is_lit then
                local nm, val = nil, nil
                pcall(function() nm = f:get_name() end)
                pcall(function() val = f:get_data(nil) end)
                if type(val) == "number" then probeC.flag_names[val] = nm end
            end
        end
    end
    return probeC.flag_names
end

local function probeC_install_setflag_logger()
    if probeC.setflag_hooked then probeC_push("setFlag logger already installed"); return end
    probeC_build_flag_names()
    local td = sdk.find_type_definition("snow.progress.ProgressEventFlag")
    if not td then probeC_push("ProgressEventFlag type not found"); return end
    local m = nil
    pcall(function() m = td:get_method("setFlag") end)
    if not m then probeC_push("setFlag method not found"); return end
    local ok, err = pcall(function()
        sdk.hook(m,
            function(args)
                -- args[1]=this, args[2]=flag id (TalkFlag/i32), args[3]=value
                local id, val = nil, nil
                pcall(function() id = sdk.to_int64(args[3]) end)
                pcall(function() val = sdk.to_int64(args[4]) end)
                probeC.setflag_count = probeC.setflag_count + 1
                probeC.setflag_log[#probeC.setflag_log + 1] = {
                    t = os.clock(), id = id,
                    name = (id ~= nil and probeC.flag_names[id]) or "?",
                    value = val,
                }
                if #probeC.setflag_log > 400 then table.remove(probeC.setflag_log, 1) end
            end,
            function(retval) return retval end)
    end)
    if ok then probeC.setflag_hooked = true; probeC_push("setFlag LOGGER installed (read-only)")
    else probeC_push("setFlag logger hook failed: " .. safe_str(err)) end
end

local function probeC_dump_setflag_log()
    local payload = {
        source = "MRSpike.lua / Probe C setFlag logger",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        total_calls = probeC.setflag_count,
        calls = probeC.setflag_log,
    }
    local ok = json.dump_file("mr_spike_setflag_log.json", payload, 4)
    if ok then probeC_push("Wrote mr_spike_setflag_log.json (" ..
        probeC.setflag_count .. " calls)")
    else probeC_push("json.dump_file FAILED") end
end

local function probeC_setflag_recent_text(max_rows)
    local n = #probeC.setflag_log
    local start = math.max(1, n - (max_rows or 16) + 1)
    local rows = {}
    for i = start, n do
        local e = probeC.setflag_log[i]
        rows[#rows + 1] = string.format("%d=%s := %s",
            e.id or -1, e.name or "?", tostring(e.value))
    end
    return table.concat(rows, "\n")
end

-- Read the LEGIT progression state (read-only): ProgressManager HR/MR
-- progress, ProgressEventFlag latest-story-flags, PQM MR/Hall urgent gate.
-- This is the state the proper advance path maintains (vs leaf flags).
local function probeC_read_progress_state()
    local out = {}
    local function read_prop(type_name, method_name, ...)
        local sing = get_singleton(type_name)
        if not sing then return "no-singleton" end
        local td = sdk.find_type_definition(type_name)
        if not td then return "no-type" end
        local m = nil
        pcall(function() m = td:get_method(method_name) end)
        if not m then return "no-method" end
        local v = nil
        local args = {...}
        local ok = pcall(function()
            if #args == 0 then v = m:call(sing)
            elseif #args == 1 then v = m:call(sing, args[1])
            else v = m:call(sing, args[1], args[2]) end
        end)
        if not ok then return "threw" end
        return v
    end
    local PM = "snow.progress.ProgressManager"
    local PEF = "snow.progress.ProgressEventFlag"
    local PQM = "snow.progress.quest.ProgressQuestManager"
    out.HRProgress = read_prop(PM, "get_HRProgress")
    out.MRProgress = read_prop(PM, "get_MRProgress")
    out.villageLatestStoryFlag = read_prop(PEF, "getVillageLatestStoryFlag")
    out.hallLatestStoryFlag = read_prop(PEF, "getHallLatestStoryFlag")
    out.mrLatestStoryFlag = read_prop(PEF, "getMrLatestStoryFlag")
    out.isUnlockHighRank = read_prop(PQM, "get_IsUnlockHighRank")
    -- isEnableUrgentMRHallQuest signature unknown; try no-arg + (QuestLevel).
    out.isEnableUrgentMRHallQuest_noarg = read_prop(PQM, "isEnableUrgentMRHallQuest")
    probeC_push(string.format(
        "progress state: HR=%s MR=%s mrLatest=%s unlockHR=%s",
        safe_str(out.HRProgress), safe_str(out.MRProgress),
        safe_str(out.mrLatestStoryFlag), safe_str(out.isUnlockHighRank)))
    return out
end

local function probeC_dump_progress_state()
    local payload = {
        source = "MRSpike.lua / Probe C progress state (READ-ONLY)",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        save_label = probeA.save_label,
        state = probeC_read_progress_state(),
    }
    local fname = "mr_spike_progress_state_" ..
        (probeA.save_label:gsub("[^%w]", "_")) .. ".json"
    local ok = json.dump_file(fname, payload, 4)
    if ok then probeC_push("Wrote " .. fname)
    else probeC_push("json.dump_file FAILED") end
end

-- Read-only hook on ProgressManager.updateProgress — the legit advance
-- routine. Log args + HR/MR progress before/after each call.
probeC.updateprog_hooked = false
probeC.updateprog_log = {}
local function probeC_install_updateprogress_logger()
    if probeC.updateprog_hooked then probeC_push("updateProgress logger already on"); return end
    local td = sdk.find_type_definition("snow.progress.ProgressManager")
    if not td then probeC_push("ProgressManager type not found"); return end
    local m = nil
    pcall(function() m = td:get_method("updateProgress") end)
    if not m then probeC_push("updateProgress method not found"); return end
    local get_hr, get_mr = nil, nil
    pcall(function() get_hr = td:get_method("get_HRProgress") end)
    pcall(function() get_mr = td:get_method("get_MRProgress") end)
    local function snap(sing)
        local hr, mr = nil, nil
        if get_hr then pcall(function() hr = get_hr:call(sing) end) end
        if get_mr then pcall(function() mr = get_mr:call(sing) end) end
        return hr, mr
    end
    local ok, err = pcall(function()
        sdk.hook(m,
            function(args)
                local a1, a2 = nil, nil
                pcall(function() a1 = sdk.to_int64(args[3]) end)
                pcall(function() a2 = sdk.to_int64(args[4]) end)
                local sing = get_singleton("snow.progress.ProgressManager")
                local hr, mr = snap(sing)
                probeC.updateprog_log[#probeC.updateprog_log + 1] = {
                    t = os.clock(), arg1 = a1, arg2 = a2,
                    hr_before = hr, mr_before = mr,
                }
                if #probeC.updateprog_log > 200 then table.remove(probeC.updateprog_log, 1) end
            end,
            function(retval) return retval end)
    end)
    if ok then probeC.updateprog_hooked = true; probeC_push("updateProgress LOGGER installed")
    else probeC_push("updateProgress hook failed: " .. safe_str(err)) end
end

local function probeC_dump_updateprogress_log()
    local payload = {
        source = "MRSpike.lua / Probe C updateProgress logger",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        calls = probeC.updateprog_log,
    }
    local ok = json.dump_file("mr_spike_updateprogress_log.json", payload, 4)
    if ok then probeC_push("Wrote mr_spike_updateprogress_log.json (" ..
        #probeC.updateprog_log .. " calls)")
    else probeC_push("json.dump_file FAILED") end
end

-- Reflect snow.progress.* progression types for advance/setProgress-style
-- methods (read-only) — the legit alternative to forcing leaf flags.
local function probeC_dump_progress_methods()
    local types = {
        "snow.progress.quest.ProgressQuestManager",
        "snow.progress.ProgressManager",
        "snow.progress.ProgressBehavior",
        "snow.progress.ProgressEventFlag",
    }
    local payload = { source = "MRSpike.lua / Probe C progress methods",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"), types = {} }
    for _, tn in ipairs(types) do
        local td = sdk.find_type_definition(tn)
        local entry = { found = td ~= nil, methods = {} }
        if td then
            local methods = nil
            pcall(function() methods = td:get_methods() end)
            if methods then
                for _, mm in ipairs(methods) do
                    local nm = nil
                    pcall(function() nm = mm:get_name() end)
                    if nm and (nm:lower():find("progress") or nm:lower():find("advance")
                        or nm:lower():find("clear") or nm:lower():find("unlock")
                        or nm:lower():find("step") or nm:lower():find("story")
                        or nm:lower():find("urgent") or nm:lower():find("flag")) then
                        entry.methods[#entry.methods + 1] = nm
                    end
                end
            end
        end
        payload.types[tn] = entry
    end
    local ok = json.dump_file("mr_spike_progress_methods.json", payload, 4)
    if ok then probeC_push("Wrote mr_spike_progress_methods.json")
    else probeC_push("json.dump_file FAILED") end
end

-- Search a single type for fields/methods matching keyword; also try as a
-- top-level type-name search across the TDB is NOT done here (use
-- MHRiseDebug.lua's tree search for that) — this is per-type drilldown.
local function probeC_search()
    local tn = probeC.search_type
    local kw = (probeC.search_kw or ""):lower()
    local lines = { "Type: " .. tn, "Keyword: " .. probeC.search_kw }
    local fields = dump_type_fields(tn)
    lines[#lines+1] = "-- fields --"
    local fhit = 0
    for _, f in ipairs(fields) do
        local nm = (f.name or ""):lower()
        if kw == "" or nm:find(kw, 1, true) then
            fhit = fhit + 1
            lines[#lines+1] = string.format("  %s : %s%s%s",
                f.name or "?", f.type or "?",
                f.is_literal and " [lit=" .. safe_str(f.literal_value) .. "]" or "",
                f.is_static and " [static]" or "")
            if fhit > 60 then lines[#lines+1] = "  ...(truncated)"; break end
        end
    end
    lines[#lines+1] = "-- methods --"
    local methods = list_methods_matching(tn, probeC.search_kw or "")
    for i, nm in ipairs(methods) do
        lines[#lines+1] = "  " .. nm
        if i > 60 then lines[#lines+1] = "  ...(truncated)"; break end
    end
    probeC.search_result = table.concat(lines, "\n")
    probeC_push("Searched " .. tn .. " for '" .. probeC.search_kw .. "'")
end

-- Generic write: set an instance flag handle true/false via getFlag's
-- sibling setFlag when the target type is ProgressEventFlag; otherwise
-- attempt a direct set_field for plain bool fields.
local function probeC_write()
    local tn = probeC.write_type
    local fname = probeC.write_field
    if fname == "" then probeC_push("write_field empty"); return end
    local sing = get_singleton(tn)
    if not sing then probeC_push("singleton unavailable: " .. tn); return end
    if tn == "snow.progress.ProgressEventFlag" then
        local td = sdk.find_type_definition(tn)
        local set_flag = nil
        pcall(function() set_flag = td:get_method("setFlag") end)
        local handle = read_instance_field(sing, fname)
        if set_flag and handle ~= nil then
            local ok, err = pcall(function()
                set_flag:call(sing, handle, probeC.write_value)
            end)
            if ok then probeC_push(string.format(
                "setFlag(%s, %s) OK", fname, tostring(probeC.write_value)))
            else probeC_push("setFlag threw: " .. safe_str(err)) end
            return
        end
        probeC_push("setFlag/handle unresolved for " .. fname)
        return
    end
    -- Fallback: direct field set (only works for primitive instance fields).
    local ok, err = pcall(function() sing:set_field(fname, probeC.write_value) end)
    if ok then probeC_push(string.format(
        "set_field(%s.%s, %s) OK", tn, fname, tostring(probeC.write_value)))
    else probeC_push("set_field threw: " .. safe_str(err)) end
end

-- =====================================================================
-- Probe D — MR quest clear + swap viability (read-only observation)
-- =====================================================================
--
-- After C unlocks travel, take/clear one low MR quest. Hook the same
-- setQuestClear path the real client uses and log the cleared quest_no so
-- we confirm MR clears surface identically to village. Also note whether
-- _nomalQuestDataKohaku is populated on this save (swap-pool prerequisite).

local probeD = {
    log = {},
    installed = false,
    events = {},
}

local function probeD_push(s)
    probeD.log[#probeD.log + 1] = s
    log_info(s)
end

local function probeD_active_quest_no()
    local qm = get_singleton("snow.QuestManager")
    if not qm then return nil end
    local td = sdk.find_type_definition("snow.QuestManager")
    local m = nil
    pcall(function() m = td:get_method("getQuestNo") end)
    if not m then return nil end
    local v = nil
    pcall(function() v = m:call(qm) end)
    if type(v) == "number" then return v end
    return nil
end

local function probeD_install()
    if probeD.installed then return end
    local td = sdk.find_type_definition("snow.QuestManager")
    if not td then probeD_push("QuestManager type not found"); return end
    local m = nil
    pcall(function() m = td:get_method("setQuestClear") end)
    if not m then probeD_push("setQuestClear not found"); return end
    local ok = pcall(function()
        sdk.hook(m,
            function(args)
                local qn = probeD_active_quest_no()
                probeD.events[#probeD.events + 1] = {
                    t = os.clock(), quest_no = qn,
                    is_mr = (qn ~= nil and qn >= 300000),
                }
                probeD_push("setQuestClear fired, quest_no=" .. safe_str(qn))
            end,
            function(retval) return retval end)
    end)
    if ok then probeD.installed = true; probeD_push("setQuestClear hook installed")
    else probeD_push("hook install failed") end
end

local function probeD_kohaku_populated()
    local qm = get_singleton("snow.QuestManager")
    if not qm then return nil end
    local arr = read_instance_field(qm, "_nomalQuestDataKohaku")
    if arr == nil then return false end
    local param = nil
    pcall(function() param = arr:get_field("_Param") end)
    if param == nil then return false end
    local len = nil
    pcall(function() len = param:get_size() end)
    return (type(len) == "number" and len > 0), len
end

local function probeD_dump()
    local populated, len = probeD_kohaku_populated()
    local payload = {
        source = "MRSpike.lua / Probe D",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        kohaku_populated = populated,
        kohaku_param_len = len,
        clear_events = probeD.events,
    }
    local ok = json.dump_file("mr_spike_probeD.json", payload, 4)
    if ok then probeD_push("Wrote mr_spike_probeD.json (kohaku_len=" ..
        safe_str(len) .. ")")
    else probeD_push("json.dump_file FAILED") end
end

-- =====================================================================
-- UI
-- =====================================================================

local function draw_log(lines, max_rows)
    local n = #lines
    local start = math.max(1, n - (max_rows or 16) + 1)
    local rows = {}
    for i = start, n do rows[#rows + 1] = lines[i] end
    imgui.text(table.concat(rows, "\n"))
end

local function draw_window()
    if not state.is_window_open then return end
    if not reframework:is_drawing_ui() then return end

    local ok, err = pcall(function()
        imgui.set_next_window_size(Vector2f.new(760, 620), 4)
        state.is_window_open = imgui.begin_window(
            "MHRise MR Spike", state.is_window_open, nil)
        if not state.is_window_open then
            imgui.end_window()
            return
        end

        imgui.text("Sunbreak (Master Rank) access spike — gh #24.")
        imgui.text("Output: <install>/reframework/data/mr_spike_*.json")
        imgui.text("!! WRITES ARE DESTRUCTIVE — throwaway save only !!")
        imgui.text("")

        if imgui.collapsing_header("Probe A — baseline state dump (READ-ONLY)") then
            imgui.text("Run on fresh / post-HR / mid-MR saves; diff the files.")
            local changed, v = imgui.input_text("save_label", probeA.save_label)
            if changed then probeA.save_label = v end
            if imgui.button("Capture baseline") then probeA_capture() end
            imgui.same_line()
            if imgui.button("Dump baseline JSON") then probeA_dump() end
            imgui.text("")
            imgui.text("Log:")
            imgui.begin_child_window("probeA_log", Vector2f.new(0, 140), true)
            draw_log(probeA.log, 20)
            imgui.end_child_window()
        end

        imgui.text("")
        if imgui.collapsing_header("Probe B — rank/quest unlock WRITES") then
            imgui.text("Silvris recipe, applied incrementally. Re-capture A")
            imgui.text("and check the boards in-game after each step.")
            imgui.text(string.format("HR-end quest_no=%d  MR sample quest_no=%d",
                HR_END_QUEST_NO, MR_SAMPLE_QUEST_NO))
            imgui.text("")
            if imgui.button("1) setClear(HR end, true)") then probeB_set_hr_cleared() end
            if imgui.button("2) setFlag(Village+Hall EndStory, true)") then
                probeB_set_end_story_flags()
            end
            if imgui.button("3) Read back MR accessibility") then probeB_readback() end
            imgui.same_line()
            if imgui.button("Dump readback JSON") then probeB_dump_readback() end
            imgui.text("")
            imgui.text("Log:")
            imgui.begin_child_window("probeB_log", Vector2f.new(0, 150), true)
            draw_log(probeB.log, 20)
            imgui.end_child_window()
        end

        imgui.text("")
        if imgui.collapsing_header("Probe C — Elgado / area access (UNKNOWN)") then
            imgui.text("Drill into a type's fields/methods for the travel gate.")
            local c1, t1 = imgui.input_text("search_type", probeC.search_type)
            if c1 then probeC.search_type = t1 end
            local c2, k1 = imgui.input_text("search_kw", probeC.search_kw)
            if c2 then probeC.search_kw = k1 end
            if imgui.button("Search type") then probeC_search() end
            imgui.begin_child_window("probeC_search", Vector2f.new(0, 200), true)
            imgui.text(probeC.search_result)
            imgui.end_child_window()

            imgui.text("")
            imgui.text("--- READ-ONLY: observe the legit transition (Run 6) ---")
            if not probeC.setflag_hooked then
                if imgui.button("Install setFlag LOGGER (read-only)") then
                    probeC_install_setflag_logger()
                end
            else
                imgui.text(string.format("setFlag logger ON. Calls: %d",
                    probeC.setflag_count))
            end
            if imgui.button("Dump setFlag log JSON") then probeC_dump_setflag_log() end
            imgui.same_line()
            if imgui.button("Dump progress methods JSON") then
                probeC_dump_progress_methods()
            end
            if imgui.button("Read progress state") then probeC_read_progress_state() end
            imgui.same_line()
            if imgui.button("Dump progress state JSON") then probeC_dump_progress_state() end
            if not probeC.updateprog_hooked then
                if imgui.button("Install updateProgress LOGGER") then
                    probeC_install_updateprogress_logger()
                end
            else
                imgui.text(string.format("updateProgress logger ON. Calls: %d",
                    #probeC.updateprog_log))
            end
            imgui.same_line()
            if imgui.button("Dump updateProgress log JSON") then
                probeC_dump_updateprogress_log()
            end
            imgui.text("Recent setFlag calls (engine-driven):")
            imgui.begin_child_window("probeC_setflag", Vector2f.new(0, 120), true)
            imgui.text(probeC_setflag_recent_text(16))
            imgui.end_child_window()

            imgui.text("")
            imgui.text("--- BULK FLAG MIRROR (Run 8 — the safe unlock attempt) ---")
            imgui.text("1) On MR/done save: Capture flag blob.")
            imgui.text("2) On throwaway save: Install blob (overwrite+commit+recompute).")
            imgui.text("3) Check Elgado travel + Read progress state.")
            if imgui.button("Capture flag blob (run on MR save)") then
                probeC_capture_flag_blob()
            end
            if imgui.button("INSTALL flag blob (throwaway save!)") then
                probeC_install_flag_blob()
            end
            imgui.same_line()
            if imgui.button("INSTALL TRIMMED blob (arrived-at-Elgado)") then
                probeC_install_flag_blob(TRIMMED_BLOB_FILE)
            end
            if imgui.button("INSTALL SYNTHETIC sparse blob (hyp1: minimal)") then
                probeC_install_flag_blob(SYNTH_BLOB_FILE)
            end
            imgui.same_line()
            if imgui.button("updateProgress only") then probeC_update_progress() end

            imgui.text("")
            imgui.text("--- LEAF-flag writes below CRASH the engine (Run 5). Avoid. ---")
            imgui.text("--- Story-flag writes by raw TalkFlag id (DESTRUCTIVE) ---")
            imgui.text("MR_001 = Sunbreak intro / Elgado arrival; ids 423-439,640.")
            local c6, v6 = imgui.input_text("flag_id", tostring(probeC.flag_id))
            if c6 then probeC.flag_id = tonumber(v6) or probeC.flag_id end
            local c7, v7 = imgui.checkbox("flag_value", probeC.flag_value)
            if c7 then probeC.flag_value = v7 end
            if imgui.button("Read flag id") then
                probeC_push(string.format("getFlag(%d) = %s",
                    probeC.flag_id, safe_str(probeC_read_flag_id(probeC.flag_id))))
            end
            imgui.same_line()
            if imgui.button("Write flag id") then
                probeC_write_flag_id(probeC.flag_id, probeC.flag_value)
            end
            imgui.text("")
            imgui.text("Presets (write the cluster, then check Elgado travel):")
            if imgui.button("Set HR-done (45/46/108) true") then
                probeC_write_hr_done(true)
            end
            if imgui.button("Set EV_PRO_MR_001_01_01 (423) true") then
                probeC_write_flag_id(423, true)
            end
            if imgui.button("Set MR_001 cluster (423-439,640) true") then
                probeC_write_mr001_cluster(true)
            end

            imgui.text("")
            imgui.text("Generic write (named field; ProgressEventFlag=setFlag else set_field):")
            local c3, t3 = imgui.input_text("write_type", probeC.write_type)
            if c3 then probeC.write_type = t3 end
            local c4, t4 = imgui.input_text("write_field", probeC.write_field)
            if c4 then probeC.write_field = t4 end
            local c5, v5 = imgui.checkbox("write_value", probeC.write_value)
            if c5 then probeC.write_value = v5 end
            if imgui.button("Apply write") then probeC_write() end
            imgui.text("")
            imgui.text("Log:")
            imgui.begin_child_window("probeC_log", Vector2f.new(0, 120), true)
            draw_log(probeC.log, 16)
            imgui.end_child_window()
        end

        imgui.text("")
        if imgui.collapsing_header("Probe D — MR clear + swap viability") then
            if not probeD.installed then
                if imgui.button("Install setQuestClear hook") then probeD_install() end
            else
                imgui.text("Hook installed. Clear a low MR quest in-game.")
            end
            if imgui.button("Dump Probe D JSON (incl. kohaku populated?)") then
                probeD_dump()
            end
            imgui.text("")
            imgui.text("Log:")
            imgui.begin_child_window("probeD_log", Vector2f.new(0, 120), true)
            draw_log(probeD.log, 16)
            imgui.end_child_window()
        end

        imgui.end_window()
    end)
    if not ok then
        log_info("draw error: " .. safe_str(err))
    end
end

re.on_frame(function() draw_window() end)

re.on_draw_ui(function()
    if imgui.button("MHRise MR Spike") then
        state.is_window_open = not state.is_window_open
    end
end)

log.info("[mr-spike] Loaded.")

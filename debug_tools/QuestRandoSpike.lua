-- QuestRandoSpike — Stage 1 research spike for the quest randomizer mode.
--
-- See QUEST_PLAN.md "Stage 1 — Research spike". This file is the
-- single home for the spike's probes; each probe should produce a
-- clear pass/fail with evidence dumped to
-- <install>/reframework/data/quest_rando_spike_*.json.
--
-- Currently implemented:
--   Probe 1  — Quest-completion hook identification.
--   Probe 2a — ProgressQuestManager.setUnlock per-quest gate. RESULT:
--              setUnlock toggles isUnlock cleanly on existing village
--              quests, but the village questboard does NOT consult
--              isUnlock to decide visibility — lock had no visible
--              effect on quest 202. setUnlock(303, true) was also a
--              no-op (didn't even flip isUnlock for the hidden quest).
--              The UI's actual visibility predicate is downstream of
--              isUnlock; checkUnlockCondition is the more interesting
--              signal (true for 202 visible, false for 303 hidden).
--   Probe 2b — checkUnlockCondition post-hook RETURN OVERRIDE. Force
--              the engine's own visibility oracle to lie per quest_no.
--              PASS.
--   Probe 3  — _BossEmType[0]/_TgtEmType[0] array Set rewrite on a
--              specific village quest_no after initQuestDataDictionary.
--              PASS for spawn redirect. Quest icon stays vanilla
--              (_Icon field untouched — cosmetic only). Engine handles
--              difficulty scaling for free (host quest dictates).
--              Carves can fall back to generic for cross-rank swaps
--              (e.g. MR-only monster spawned at LR). Some engine-
--              special arena monsters (Gaismagorm) crash on launch.
--
-- Dev-only. Drop into <install>/reframework/autorun/. No AP connection
-- needed. Never bundled into the player client zip (release workflow's
-- AUTORUN_FILES allow-list excludes debug_tools/).
--
-- Trigger: REFramework overlay button "MHRise Quest Rando Spike".

if reframework:get_game_name() ~= "mhrise" then return end

log.info("[quest-spike] Loading...")

local LOG_TAG = "[quest-spike] "

local function log_info(msg) log.info(LOG_TAG .. msg) end

local function safe_str(v)
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "<tostring error>"
end

-- =====================================================================
-- Probe 1 — Quest completion hook identification.
-- =====================================================================
--
-- Goal: identify which QuestManager method fires exactly once on a
-- successful village quest CLEAR (not on fail, not on abandon, not
-- multiple times), and exposes the cleared quest_no.
--
-- Strategy: install pre-hooks on each candidate method. On fire, read
-- the active quest_no via QuestManager:getActiveQuestUniqueNo() and
-- append a timestamped event to an in-memory ring. Render events in the
-- UI so the tester can correlate them against the in-game outcome they
-- just produced (clear / fail / abandon). The tester classifies each
-- run via three buttons ("Mark last run as CLEAR / FAIL / ABANDON")
-- that stamp every event since the last classification with the
-- declared outcome. Dump the classified event log on demand.
--
-- Candidates (per QUEST_PLAN.md):
--   - snow.QuestManager.setQuestClear          (primary suspect)
--   - snow.QuestManager.onQuestReturn          (returns to village)
--   - snow.QuestManager.notifyReturn           (notification path)
--   - snow.QuestManager.setQuestFail           (negative control —
--                                                MUST fire on fail and
--                                                MUST NOT fire on clear)
--
-- setQuestFail is included as a sanity-check: if it never fires on a
-- failed quest, the test environment is wrong (e.g. carts didn't
-- register) and the rest of the data is suspect.

local CANDIDATES = {
    { type_name = "snow.QuestManager", method_name = "setQuestClear" },
    { type_name = "snow.QuestManager", method_name = "onQuestReturn" },
    { type_name = "snow.QuestManager", method_name = "notifyReturn" },
    { type_name = "snow.QuestManager", method_name = "setQuestFail" },
}

local probe1 = {
    installed = false,
    install_log = {},     -- per-candidate install status strings
    events = {},          -- { { t, method, quest_no_*, outcome } ... }
    next_event_seq = 1,
    last_classified_seq = 0,  -- events with seq > this are "unclassified"
    quest_manager_td = nil,
    -- Three competing accessors for "the active quest's id" — Probe 1a
    -- showed getActiveQuestUniqueNo returns wild int32s (looks like a
    -- hashed UniqueNo, not the human _QuestNo). Probe 1b captures all
    -- three at every fire so we can pick the one that matches the
    -- catalog's _QuestNo (= the key in ap_world/data/quests.py).
    get_active_quest_unique_no = nil,  -- QuestManager.getActiveQuestUniqueNo() : Int32
    get_quest_no = nil,                -- QuestManager.getQuestNo() : Int32
    get_active_quest_data = nil,       -- QuestManager.getActiveQuestData() : QuestData
    qd_get_quest_no = nil,             -- QuestData.getQuestNo() : Int32
}

local function push_install(s)
    probe1.install_log[#probe1.install_log + 1] = s
    log_info(s)
end

local function probe1_call_int(method, receiver)
    if not method or not receiver then return nil end
    local v = nil
    pcall(function() v = method:call(receiver) end)
    if type(v) == "number" then return v end
    return nil
end

local function probe1_resolve_all()
    -- Capture every available "active quest id" reading at this
    -- instant. Returns a table with one field per accessor; any field
    -- may be nil. Also reads QuestData._QuestNo as a fourth path (the
    -- catalog uses _QuestNo directly, so this is the ground truth we
    -- compare the accessors against).
    --
    -- Probe 1a showed getActiveQuestUniqueNo returns wild int32s (a
    -- hashed UniqueNo, not the human _QuestNo). The other three paths
    -- below are the candidates for the gating-key the client will use.
    local out = {
        active_unique_no = nil,      -- QuestManager.getActiveQuestUniqueNo()
        manager_quest_no = nil,      -- QuestManager.getQuestNo()
        active_data_quest_no = nil,  -- QuestManager.getActiveQuestData():getQuestNo()
        active_data_field = nil,     -- QuestData._QuestNo field read
    }
    local qm = sdk.get_managed_singleton("snow.QuestManager")
    if not qm then return out end

    out.active_unique_no = probe1_call_int(probe1.get_active_quest_unique_no, qm)
    out.manager_quest_no = probe1_call_int(probe1.get_quest_no, qm)

    local qd = nil
    if probe1.get_active_quest_data then
        pcall(function() qd = probe1.get_active_quest_data:call(qm) end)
    end
    if qd then
        out.active_data_quest_no = probe1_call_int(probe1.qd_get_quest_no, qd)
        pcall(function()
            local v = qd:get_field("_QuestNo")
            if type(v) == "number" then out.active_data_field = v end
        end)
    end

    return out
end

local function probe1_record(method_name)
    local ids = probe1_resolve_all()
    local ev = {
        seq = probe1.next_event_seq,
        t = os.clock(),
        method = method_name,
        active_unique_no = ids.active_unique_no,
        manager_quest_no = ids.manager_quest_no,
        active_data_quest_no = ids.active_data_quest_no,
        active_data_field = ids.active_data_field,
        outcome = "(unclassified)",
    }
    probe1.next_event_seq = probe1.next_event_seq + 1
    probe1.events[#probe1.events + 1] = ev
    log_info(string.format(
        "event #%d %s unique=%s mgrQN=%s qdQN=%s qd_field=%s",
        ev.seq, method_name,
        tostring(ev.active_unique_no),
        tostring(ev.manager_quest_no),
        tostring(ev.active_data_quest_no),
        tostring(ev.active_data_field)))
end

local function probe1_install_one(cand)
    local td = sdk.find_type_definition(cand.type_name)
    if not td then
        push_install(string.format("  [skip] %s — type not found",
            cand.type_name))
        return false
    end
    -- Match by name only — none of these candidates have overloads in
    -- the QuestManager type dump (per QUEST.md), so a name-only lookup
    -- is unambiguous. If that ever changes, switch to the full
    -- signature form (e.g. "setQuestClear()").
    local method = td:get_method(cand.method_name)
    if not method then
        push_install(string.format("  [skip] %s.%s — method not found",
            cand.type_name, cand.method_name))
        return false
    end

    local ok_hook, err = pcall(function()
        sdk.hook(method,
            function(args)
                local ok, herr = pcall(function()
                    probe1_record(cand.method_name)
                end)
                if not ok then
                    log_info(string.format(
                        "%s pre-hook error: %s",
                        cand.method_name, safe_str(herr)))
                end
            end,
            function(retval) return retval end)
    end)
    if not ok_hook then
        push_install(string.format("  [fail] %s.%s — hook install error: %s",
            cand.type_name, cand.method_name, safe_str(err)))
        return false
    end
    push_install(string.format("  [ok]   %s.%s — pre-hook installed",
        cand.type_name, cand.method_name))
    return true
end

local function probe1_install_all()
    if probe1.installed then
        log_info("Probe 1 already installed — skipping reinstall")
        return
    end

    probe1.quest_manager_td = sdk.find_type_definition("snow.QuestManager")
    if probe1.quest_manager_td then
        pcall(function()
            probe1.get_active_quest_unique_no =
                probe1.quest_manager_td:get_method("getActiveQuestUniqueNo")
        end)
        pcall(function()
            probe1.get_quest_no =
                probe1.quest_manager_td:get_method("getQuestNo")
        end)
        pcall(function()
            probe1.get_active_quest_data =
                probe1.quest_manager_td:get_method("getActiveQuestData")
        end)
        push_install(string.format(
            "QuestManager: unique=%s mgrQN=%s activeData=%s",
            tostring(probe1.get_active_quest_unique_no ~= nil),
            tostring(probe1.get_quest_no ~= nil),
            tostring(probe1.get_active_quest_data ~= nil)))
    else
        push_install("snow.QuestManager type not found — all quest-id columns will be nil")
    end

    local qd_td = sdk.find_type_definition("snow.quest.QuestData")
    if qd_td then
        pcall(function()
            probe1.qd_get_quest_no = qd_td:get_method("getQuestNo")
        end)
        push_install(string.format(
            "QuestData.getQuestNo resolved: %s",
            tostring(probe1.qd_get_quest_no ~= nil)))
    else
        push_install("snow.quest.QuestData type not found — qdQN column will be nil")
    end

    push_install("Installing probe 1 hooks:")
    for _, cand in ipairs(CANDIDATES) do
        probe1_install_one(cand)
    end

    probe1.installed = true
end

local function probe1_classify_pending(outcome)
    -- Stamp every event with seq > last_classified_seq with the given
    -- outcome label. Use this immediately after running an in-game
    -- attempt (clear / fail / abandon).
    local count = 0
    for _, ev in ipairs(probe1.events) do
        if ev.seq > probe1.last_classified_seq then
            ev.outcome = outcome
            count = count + 1
        end
    end
    probe1.last_classified_seq = probe1.next_event_seq - 1
    log_info(string.format("classified %d pending event(s) as %s",
        count, outcome))
    return count
end

local function probe1_dump()
    local payload = {
        source = "QuestRandoSpike.lua / Probe 1",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        candidates = (function()
            local list = {}
            for _, c in ipairs(CANDIDATES) do
                list[#list + 1] = c.type_name .. "." .. c.method_name
            end
            return list
        end)(),
        install_log = probe1.install_log,
        event_count = #probe1.events,
        events = probe1.events,
    }
    local ok = json.dump_file("quest_rando_spike_probe1.json", payload, 4)
    if ok then
        log_info("dumped Probe 1 events -> quest_rando_spike_probe1.json")
    else
        log_info("json.dump_file failed for Probe 1")
    end
    return ok
end

local function probe1_summary_text()
    -- Per-method tallies bucketed by outcome. Quick visual gut-check
    -- of "which method fires only on CLEAR?".
    local tally = {}  -- method -> { CLEAR=n, FAIL=n, ABANDON=n, unclassified=n }
    for _, ev in ipairs(probe1.events) do
        local row = tally[ev.method]
        if not row then
            row = { CLEAR = 0, FAIL = 0, ABANDON = 0, ["(unclassified)"] = 0 }
            tally[ev.method] = row
        end
        row[ev.outcome] = (row[ev.outcome] or 0) + 1
    end
    local lines = {}
    for method_name, row in pairs(tally) do
        lines[#lines + 1] = string.format(
            "  %-20s CLEAR=%d  FAIL=%d  ABANDON=%d  unclassified=%d",
            method_name,
            row.CLEAR or 0, row.FAIL or 0, row.ABANDON or 0,
            row["(unclassified)"] or 0)
    end
    if #lines == 0 then
        return "(no events yet)"
    end
    table.sort(lines)
    return table.concat(lines, "\n")
end

local function probe1_recent_events_text(max_rows)
    local n = #probe1.events
    if n == 0 then return "(no events yet)" end
    local from = math.max(1, n - max_rows + 1)
    local lines = {}
    lines[#lines + 1] = string.format(
        "  %-4s %-7s %-16s %-13s %-10s %-10s %-10s %s",
        "#", "t", "method", "unique", "mgrQN", "qdQN", "qdField", "outcome")
    for i = from, n do
        local ev = probe1.events[i]
        lines[#lines + 1] = string.format(
            "  %-4d %7.2f %-16s %-13s %-10s %-10s %-10s [%s]",
            ev.seq, ev.t, ev.method,
            tostring(ev.active_unique_no),
            tostring(ev.manager_quest_no),
            tostring(ev.active_data_quest_no),
            tostring(ev.active_data_field),
            ev.outcome)
    end
    return table.concat(lines, "\n")
end

-- =====================================================================
-- Probe 2 — ProgressQuestManager.setUnlock / isUnlock per-quest gate.
-- =====================================================================
--
-- Goal: confirm that snow.progress.quest.ProgressQuestManager exposes a
-- per-quest visibility gate via setUnlock(quest_no, bool) /
-- isUnlock(quest_no) that takes effect on the village questboard UI.
--
-- Strategy: no hooks needed for the core experiment — just call the
-- methods imperatively from UI buttons. The tester opens the village
-- counter, observes baseline, presses LOCK on a visible quest,
-- re-opens, presses UNLOCK on a hidden quest, re-opens. Three reads
-- per action — isUnlock, isDisp, isClear — captured into the event log
-- alongside the imperative action ("lock" / "unlock" / "read") so we
-- can correlate state with the in-game UI outcome.
--
-- Targets:
--   PROBE2_VISIBLE_QUEST_NO = 202 (Great Izuchi, QL2 hunting — currently
--     visible per Probe 1 testing)
--   PROBE2_HIDDEN_QUEST_NO  = 303 (Feathered Frenzy / Aknosom, QL3
--     hunting — currently hidden; tests whether the gate generalizes
--     across QuestLevel or whether QL3 has a separate level-master gate)
--
-- If setUnlock(202, false) sticks across a counter re-open and the quest
-- disappears, the gate is engine-native and we use this in Stage 2.
-- If setUnlock(303, true) reveals the quest, QL gating uses the same
-- system and is per-quest, not per-level. If it doesn't reveal 303,
-- we know there's a secondary level gate to dig into next.

local PROBE2_VISIBLE_QUEST_NO = 202
local PROBE2_HIDDEN_QUEST_NO  = 303

local probe2 = {
    resolved = false,
    install_log = {},
    events = {},
    -- Resolved method handles (cached on first action).
    is_unlock = nil,       -- ProgressQuestManager.isUnlock(UInt32) : Bool
    set_unlock = nil,      -- ProgressQuestManager.setUnlock(UInt32, Bool) : Void
    is_disp = nil,         -- ProgressQuestManager.isDisp(QuestNo, Bool) : Bool  (no UInt32 overload)
    is_clear_u32 = nil,    -- ProgressQuestManager.isClear(UInt32) : Bool
    check_unlock = nil,    -- ProgressQuestManager.checkUnlockCondition(QuestNo) : Bool
}

local function probe2_push_install(s)
    probe2.install_log[#probe2.install_log + 1] = s
    log_info(s)
end

local function probe2_resolve()
    if probe2.resolved then return true end

    local td = sdk.find_type_definition("snow.progress.quest.ProgressQuestManager")
    if not td then
        probe2_push_install("  [skip] ProgressQuestManager — type not found")
        return false
    end

    -- Each accessor is wrapped in a pcall — overload disambiguation in
    -- REFramework is finicky. Where multiple overloads exist (isUnlock,
    -- setUnlock, isClear), prefer the UInt32 variant — passes a raw
    -- quest_no without needing an enum cast.
    pcall(function()
        probe2.is_unlock = td:get_method("isUnlock(System.UInt32)")
    end)
    pcall(function()
        probe2.set_unlock = td:get_method("setUnlock(System.UInt32, System.Boolean)")
    end)
    pcall(function()
        -- isDisp only has the (QuestNo, bool) overload per the dump. The
        -- enum is i32-backed so passing a raw int should work via
        -- REFramework's coercion, same as Probe 1's getQuestNo on the
        -- ManagedObject. If it throws we'll see it in the call log.
        probe2.is_disp = td:get_method("isDisp(snow.quest.QuestNo, System.Boolean)")
    end)
    pcall(function()
        probe2.is_clear_u32 = td:get_method("isClear(System.UInt32)")
    end)
    pcall(function()
        probe2.check_unlock = td:get_method("checkUnlockCondition(snow.quest.QuestNo)")
    end)

    probe2_push_install(string.format(
        "ProgressQuestManager methods: isUnlock=%s setUnlock=%s isDisp=%s isClear=%s checkUnlock=%s",
        tostring(probe2.is_unlock ~= nil),
        tostring(probe2.set_unlock ~= nil),
        tostring(probe2.is_disp ~= nil),
        tostring(probe2.is_clear_u32 ~= nil),
        tostring(probe2.check_unlock ~= nil)))

    probe2.resolved = true
    return true
end

local function probe2_singleton()
    return sdk.get_managed_singleton("snow.progress.quest.ProgressQuestManager")
end

local function probe2_read_state(quest_no)
    -- Returns { isUnlock, isDisp, isClear, checkUnlock } for quest_no.
    -- Any field may be nil if the corresponding method failed to resolve
    -- or threw. All calls are pcall'd; one bad accessor doesn't poison
    -- the rest.
    local out = {
        is_unlock = nil, is_disp = nil,
        is_clear = nil, check_unlock = nil,
    }
    local pqm = probe2_singleton()
    if not pqm then return out end

    if probe2.is_unlock then
        pcall(function() out.is_unlock = probe2.is_unlock:call(pqm, quest_no) end)
    end
    if probe2.is_disp then
        -- isDisp's second arg is a bool — the dump doesn't name it, but
        -- by convention in this engine it's usually "include
        -- unaccepted/locked entries". Pass false; we want the strict
        -- "would the UI display this right now?" answer.
        pcall(function() out.is_disp = probe2.is_disp:call(pqm, quest_no, false) end)
    end
    if probe2.is_clear_u32 then
        pcall(function() out.is_clear = probe2.is_clear_u32:call(pqm, quest_no) end)
    end
    if probe2.check_unlock then
        pcall(function() out.check_unlock = probe2.check_unlock:call(pqm, quest_no) end)
    end
    return out
end

local function probe2_record(action, quest_no, extra)
    local state = probe2_read_state(quest_no)
    local ev = {
        t = os.clock(),
        action = action,
        quest_no = quest_no,
        is_unlock = state.is_unlock,
        is_disp = state.is_disp,
        is_clear = state.is_clear,
        check_unlock = state.check_unlock,
        extra = extra,
    }
    probe2.events[#probe2.events + 1] = ev
    log_info(string.format(
        "probe2 %s qn=%d isUnlock=%s isDisp=%s isClear=%s checkUnlock=%s%s",
        action, quest_no,
        tostring(ev.is_unlock), tostring(ev.is_disp),
        tostring(ev.is_clear), tostring(ev.check_unlock),
        extra and (" extra=" .. safe_str(extra)) or ""))
end

local function probe2_do_set_unlock(quest_no, value)
    if not probe2_resolve() then return end
    local pqm = probe2_singleton()
    if not pqm then
        log_info("probe2: ProgressQuestManager singleton not available")
        return
    end
    if not probe2.set_unlock then
        log_info("probe2: setUnlock not resolved")
        return
    end
    local extra = nil
    local ok, err = pcall(function()
        probe2.set_unlock:call(pqm, quest_no, value)
    end)
    if not ok then extra = "setUnlock call threw: " .. safe_str(err) end
    probe2_record(value and "unlock" or "lock", quest_no, extra)
end

local function probe2_do_read(quest_no)
    if not probe2_resolve() then return end
    probe2_record("read", quest_no, nil)
end

local function probe2_dump()
    local payload = {
        source = "QuestRandoSpike.lua / Probe 2 (ProgressQuestManager)",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        visible_quest_no = PROBE2_VISIBLE_QUEST_NO,
        hidden_quest_no = PROBE2_HIDDEN_QUEST_NO,
        install_log = probe2.install_log,
        event_count = #probe2.events,
        events = probe2.events,
    }
    local ok = json.dump_file("quest_rando_spike_probe2.json", payload, 4)
    if ok then
        log_info("dumped Probe 2 events -> quest_rando_spike_probe2.json")
    else
        log_info("json.dump_file failed for Probe 2")
    end
    return ok
end

local function probe2_recent_events_text(max_rows)
    local n = #probe2.events
    if n == 0 then return "(no actions yet)" end
    local from = math.max(1, n - max_rows + 1)
    local lines = {}
    lines[#lines + 1] = string.format(
        "  %-7s %-7s %-6s %-9s %-7s %-7s %s",
        "t", "action", "qn", "isUnlock", "isDisp", "isClear", "checkUnlock")
    for i = from, n do
        local ev = probe2.events[i]
        lines[#lines + 1] = string.format(
            "  %7.2f %-7s %-6d %-9s %-7s %-7s %s",
            ev.t, ev.action, ev.quest_no,
            tostring(ev.is_unlock), tostring(ev.is_disp),
            tostring(ev.is_clear), tostring(ev.check_unlock))
    end
    return table.concat(lines, "\n")
end

-- =====================================================================
-- Probe 2b — checkUnlockCondition return-value override.
-- =====================================================================
--
-- Goal: confirm that we can override snow.progress.quest
-- .ProgressQuestManager.checkUnlockCondition(QuestNo)'s return per
-- quest_no via a post-hook, and that the village questboard re-queries
-- it on board open (so our override actually changes visibility).
--
-- Strategy: install one post-hook on checkUnlockCondition. The hook
-- consults probe2b.overrides[quest_no_str] — a per-quest-no entry of
-- "true" / "false" / absent. Absent = passthrough (return engine's
-- own value unchanged). "true" / "false" = force that boolean as the
-- return.
--
-- We also need the quest_no the engine queried. The post-hook only
-- gets retval; the QuestNo arg is captured in the PRE callback into a
-- thread-local-ish slot, then read in POST. This is the Silvris idiom
-- noted in CLAUDE.md ("snow.quest.QuestData.getQuestText pre+post hook
-- — thread-static storage of the per-call args between pre and post").
-- CAVEAT: QUEST.md "Argument lifetime" warns that args[N] raw pointers
-- aren't safe to use after the function returns. We're not capturing
-- the raw pointer; we're capturing the INT VALUE extracted from it
-- (via sdk.to_int64) inside the pre-hook, which is just a Lua number
-- and safe to read later.
--
-- Buttons:
--   "Hide 202"   -> overrides[202] = false  (visible -> should disappear)
--   "Show 303"   -> overrides[303] = true   (hidden  -> should appear)
--   "Clear overrides" -> pass-through for all quests
--   "READ via hook" -> call checkUnlockCondition imperatively to
--                       confirm the override is taking effect at all
--                       (independent of UI re-query behavior).

local probe2b = {
    installed = false,
    install_log = {},
    overrides = {},        -- string(quest_no) -> bool override, or absent
    last_pre_qn = nil,     -- captured by pre, read by post (single-threaded UI thread)
    fires = 0,             -- total hook fires (sanity check that UI re-queries)
    last_fires_log = {},   -- ring of last ~20 fires: { qn, original, returned }
}

local function probe2b_push_install(s)
    probe2b.install_log[#probe2b.install_log + 1] = s
    log_info(s)
end

local function probe2b_install()
    if probe2b.installed then
        log_info("Probe 2b already installed — skipping reinstall")
        return
    end

    local td = sdk.find_type_definition("snow.progress.quest.ProgressQuestManager")
    if not td then
        probe2b_push_install("  [skip] ProgressQuestManager — type not found")
        return
    end
    local method = td:get_method("checkUnlockCondition(snow.quest.QuestNo)")
    if not method then
        probe2b_push_install("  [skip] checkUnlockCondition — method not found")
        return
    end

    local ok_hook, err = pcall(function()
        sdk.hook(method,
            function(args)
                -- args[1]=this, args[2]=quest_no (QuestNo enum, i32-backed).
                -- Convert pointer to int value immediately; the raw
                -- pointer is not safe to read in post (QUEST.md note).
                local qn = nil
                pcall(function() qn = sdk.to_int64(args[3]) end)
                probe2b.last_pre_qn = qn
            end,
            function(retval)
                local qn = probe2b.last_pre_qn
                local original = nil
                pcall(function()
                    -- retval is a pointer to the bool return. Extract
                    -- the int value (0/1) for logging.
                    original = sdk.to_int64(retval)
                end)

                local returned = original
                local override = nil
                if qn ~= nil then
                    override = probe2b.overrides[tostring(qn)]
                end
                if override == true then
                    returned = 1
                    retval = sdk.to_ptr(1)
                elseif override == false then
                    returned = 0
                    retval = sdk.to_ptr(0)
                end

                probe2b.fires = probe2b.fires + 1
                probe2b.last_fires_log[#probe2b.last_fires_log + 1] = {
                    qn = qn, original = original, returned = returned,
                }
                -- Trim ring buffer.
                if #probe2b.last_fires_log > 20 then
                    table.remove(probe2b.last_fires_log, 1)
                end

                return retval
            end)
    end)
    if not ok_hook then
        probe2b_push_install("  [fail] checkUnlockCondition — hook install error: " .. safe_str(err))
        return
    end
    probe2b_push_install("  [ok]   checkUnlockCondition — pre+post hook installed")
    probe2b.installed = true
end

local function probe2b_set_override(quest_no, value)
    -- value: true / false / nil (clear)
    if value == nil then
        probe2b.overrides[tostring(quest_no)] = nil
    else
        probe2b.overrides[tostring(quest_no)] = value
    end
    log_info(string.format("probe2b override qn=%d -> %s",
        quest_no, tostring(value)))
end

local function probe2b_clear_all()
    probe2b.overrides = {}
    log_info("probe2b cleared all overrides")
end

local function probe2b_read_via_hook(quest_no)
    -- Imperative read — calls checkUnlockCondition through the engine,
    -- which goes through our hook. Confirms the override path works
    -- even if the UI happens not to re-query.
    if not probe2b.installed then
        log_info("probe2b: hook not installed")
        return
    end
    local pqm = probe2_singleton()
    if not pqm or not probe2.check_unlock then
        log_info("probe2b: no singleton or method not resolved (resolve via Probe 2 first)")
        return
    end
    local v = nil
    pcall(function() v = probe2.check_unlock:call(pqm, quest_no) end)
    log_info(string.format("probe2b read via hook: qn=%d -> %s", quest_no, tostring(v)))
end

local function probe2b_dump()
    local payload = {
        source = "QuestRandoSpike.lua / Probe 2b (checkUnlockCondition override)",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        install_log = probe2b.install_log,
        overrides = probe2b.overrides,
        total_fires = probe2b.fires,
        last_fires = probe2b.last_fires_log,
    }
    local ok = json.dump_file("quest_rando_spike_probe2b.json", payload, 4)
    if ok then
        log_info("dumped Probe 2b -> quest_rando_spike_probe2b.json")
    else
        log_info("json.dump_file failed for Probe 2b")
    end
    return ok
end

local function probe2b_overrides_text()
    local lines = {}
    for k, v in pairs(probe2b.overrides) do
        lines[#lines + 1] = string.format("  qn=%s -> %s", k, tostring(v))
    end
    if #lines == 0 then return "  (none — pass-through)" end
    table.sort(lines)
    return table.concat(lines, "\n")
end

local function probe2b_fires_text(max_rows)
    local n = #probe2b.last_fires_log
    if n == 0 then return "(no fires yet — open village quest counter)" end
    local from = math.max(1, n - max_rows + 1)
    local lines = {}
    lines[#lines + 1] = "  qn       orig    returned"
    for i = from, n do
        local ev = probe2b.last_fires_log[i]
        lines[#lines + 1] = string.format("  %-8s %-7s %-7s",
            tostring(ev.qn), tostring(ev.original), tostring(ev.returned))
    end
    return table.concat(lines, "\n")
end

-- =====================================================================
-- Probe 3 — _BossEmType[0] / _TgtEmType[0] array Set rewrite.
-- =====================================================================
--
-- Goal: confirm that RiseQuestLoader's idiom — mutating the boss/target
-- EmType arrays on an existing QuestData entry via
-- array:call("Set", 0, em_type_int) — actually redirects both the UI
-- target-monster label AND the in-game spawn for a village quest.
--
-- Strategy: install a post-hook on
-- snow.QuestManager.initQuestDataDictionary. On fire, walk
-- _normalQuestData._Param, find the one entry with _QuestNo == 202
-- (Great Izuchi, em_type 98), and overwrite _BossEmType[0] and
-- _TgtEmType[0] to 89 (Magnamalo). Stash the original values so we can
-- inspect them via the spike UI and (in principle) revert.
--
-- Test sequence in-game:
--   1. Reset Scripts -> Install Probe 3 hook.
--   2. Load save (so QuestManager initializes; initQuestDataDictionary
--      fires once during load). If already in-game when installing,
--      reload to-title or just observe whether the swap took effect.
--   3. Open village quest counter, find Great Izuchi. The displayed
--      target monster should be Magnamalo (label changed).
--   4. Accept and start the quest. Expected: Magnamalo spawns.
--
-- PASS = both label and spawn switched. Match (per QUEST_PLAN.md
-- Probe 3 spec). If only the label changes but the spawn is still
-- Izuchi, we need to ALSO hook EnemyManager.findBossInitSetInfo /
-- findBossInitPosition per QUEST.md "Answer" section.
--
-- This probe ALSO answers QUEST.md's open question about
-- array:call("Set", ...) — if the call throws "Invoke threw an
-- exception" we're back to the :write_dword(0x20, ...) hack from
-- QUEST.md's earlier exploration.

local PROBE3_TARGET_QUEST_NO = 202   -- Great Izuchi (em_type 98)

-- Named swap presets for the spike UI. The value is what we'll write
-- into _BossEmType[0] / _TgtEmType[0]. Names are display-only.
local PROBE3_PRESETS = {
    { name = "Arzuros (60) — completable test",         em = 60  },
    { name = "Magnamalo (89) — original test",          em = 89  },
    { name = "Lunagaron (133) — Sunbreak swap",         em = 133 },
    { name = "Gaismagorm (135) — special arena (UNSAFE)", em = 135 },
    { name = "Revert to Great Izuchi (98)",             em = 98  },
}

local probe3 = {
    installed = false,
    install_log = {},
    swap_applied = false,
    swap_attempts = 0,
    -- Captured ONCE on the first swap (so it survives subsequent swaps
    -- when we overwrite our own writes).
    vanilla_boss_em = nil,
    vanilla_tgt_em = nil,
    -- Last-swap state.
    last_em_attempted = nil,
    post_boss_em = nil,
    post_tgt_em = nil,
    set_err = nil,
    -- Auto-apply on initQuestDataDictionary hook fires. Defaults off
    -- after Probe 3 first PASS — we want explicit button-driven swaps
    -- now so we can choose the em_type per test without recompiling.
    auto_apply_on_hook = false,
    auto_apply_em = 60,
}

local function probe3_push_install(s)
    probe3.install_log[#probe3.install_log + 1] = s
    log_info(s)
end

local function probe3_read_em_slot0(arr)
    -- Read element 0 from an EmTypes[] array. Tries call("get_Item", 0)
    -- first (the System.Array indexer); falls back to read_dword(0x20)
    -- if the call route doesn't return an int.
    if not arr then return nil end
    local v = nil
    pcall(function() v = arr:call("get_Item", 0) end)
    if type(v) == "number" then return v end
    pcall(function() v = arr:read_dword(0x20) end)
    if type(v) == "number" then return v end
    return nil
end

local function probe3_find_param_for_quest(arr_field_name, quest_no)
    -- Walk a NormalQuestDataForEnemy.Param[] array on QuestManager and
    -- return the element whose _QuestNo == quest_no, or nil.
    --
    -- Per QuestCatalogDump precedent, the _Param array elements ARE
    -- NormalQuestData.Param payloads directly — no get_RawNormal()
    -- indirection. Iterate via System.Array layout: count at +0x1c.
    local qm = sdk.get_managed_singleton("snow.QuestManager")
    if not qm then return nil end

    local container = nil
    pcall(function() container = qm:get_field(arr_field_name) end)
    if not container then return nil end

    local arr = nil
    pcall(function() arr = container:get_field("_Param") end)
    if not arr then return nil end

    local count = nil
    pcall(function() count = arr:read_dword(0x1c) end)
    if not count or count <= 0 then return nil end

    for i = 0, count - 1 do
        local elem = nil
        pcall(function() elem = arr:call("get_Item", i) end)
        if elem then
            local qn = nil
            pcall(function() qn = elem:get_field("_QuestNo") end)
            if qn == quest_no then return elem end
        end
    end
    return nil
end

local function probe3_apply_swap(new_em_type)
    -- Find the QuestData for the target quest_no in the normal catalog
    -- (Rise base + HR — Kohaku/MR is a separate array). Mutate slot 0
    -- of both _BossEmType and _TgtEmType to the requested em_type.
    --
    -- Vanilla values are captured on the first call only — subsequent
    -- calls would read back our own writes, which is the wrong baseline.
    probe3.swap_attempts = probe3.swap_attempts + 1
    probe3.last_em_attempted = new_em_type

    local param = probe3_find_param_for_quest("_normalQuestData", PROBE3_TARGET_QUEST_NO)
    if not param then
        probe3.set_err = string.format(
            "could not find quest_no %d in _normalQuestData._Param",
            PROBE3_TARGET_QUEST_NO)
        log_info("probe3: " .. probe3.set_err)
        return
    end

    local boss = nil
    local tgt = nil
    pcall(function() boss = param:get_field("_BossEmType") end)
    pcall(function() tgt = param:get_field("_TgtEmType") end)
    if not boss or not tgt then
        probe3.set_err = "could not read _BossEmType / _TgtEmType from param"
        log_info("probe3: " .. probe3.set_err)
        return
    end

    if probe3.vanilla_boss_em == nil then
        probe3.vanilla_boss_em = probe3_read_em_slot0(boss)
        probe3.vanilla_tgt_em = probe3_read_em_slot0(tgt)
        log_info(string.format(
            "probe3 vanilla baseline: boss=%s tgt=%s",
            tostring(probe3.vanilla_boss_em),
            tostring(probe3.vanilla_tgt_em)))
    end

    local set_err = nil
    local ok_boss = pcall(function()
        boss:call("Set", 0, new_em_type)
    end)
    local ok_tgt = pcall(function()
        tgt:call("Set", 0, new_em_type)
    end)
    if not ok_boss or not ok_tgt then
        set_err = string.format(
            "Set call threw — boss_ok=%s tgt_ok=%s — falling back to write_dword",
            tostring(ok_boss), tostring(ok_tgt))
        log_info("probe3: " .. set_err)
        pcall(function() boss:write_dword(0x20, new_em_type) end)
        pcall(function() tgt:write_dword(0x20, new_em_type) end)
    end
    probe3.set_err = set_err

    probe3.post_boss_em = probe3_read_em_slot0(boss)
    probe3.post_tgt_em = probe3_read_em_slot0(tgt)
    probe3.swap_applied = true
    log_info(string.format(
        "probe3 post-swap: boss=%s tgt=%s (requested em=%d)",
        tostring(probe3.post_boss_em),
        tostring(probe3.post_tgt_em),
        new_em_type))
end

local function probe3_install()
    if probe3.installed then
        log_info("Probe 3 already installed — skipping reinstall")
        return
    end

    local td = sdk.find_type_definition("snow.QuestManager")
    if not td then
        probe3_push_install("  [skip] snow.QuestManager — type not found")
        return
    end
    local method = td:get_method("initQuestDataDictionary")
    if not method then
        probe3_push_install("  [skip] initQuestDataDictionary — method not found")
        return
    end

    local ok_hook, err = pcall(function()
        sdk.hook(method,
            function(args) end,
            function(retval)
                if probe3.auto_apply_on_hook then
                    local ok_inner, herr = pcall(function()
                        probe3_apply_swap(probe3.auto_apply_em)
                    end)
                    if not ok_inner then
                        log_info("probe3 post-hook error: " .. safe_str(herr))
                    end
                end
                return retval
            end)
    end)
    if not ok_hook then
        probe3_push_install("  [fail] initQuestDataDictionary — hook install error: " .. safe_str(err))
        return
    end
    probe3_push_install("  [ok]   initQuestDataDictionary — post-hook installed")
    probe3.installed = true
end

local function probe3_apply_now(em_type)
    -- If we're already in a save when the spike is installed, the
    -- initQuestDataDictionary hook won't fire (it already ran at load).
    -- This forces the mutation immediately without a reload-to-title.
    log_info(string.format(
        "probe3: applying swap immediately (em=%d, bypassing hook)",
        em_type))
    probe3_apply_swap(em_type)
end

local function probe3_dump()
    local payload = {
        source = "QuestRandoSpike.lua / Probe 3 (boss EmType swap)",
        captured_at = os.date("%Y-%m-%dT%H:%M:%S"),
        target_quest_no = PROBE3_TARGET_QUEST_NO,
        last_em_attempted = probe3.last_em_attempted,
        install_log = probe3.install_log,
        swap_applied = probe3.swap_applied,
        swap_attempts = probe3.swap_attempts,
        vanilla_boss_em = probe3.vanilla_boss_em,
        vanilla_tgt_em = probe3.vanilla_tgt_em,
        post_boss_em = probe3.post_boss_em,
        post_tgt_em = probe3.post_tgt_em,
        set_err = probe3.set_err,
        auto_apply_on_hook = probe3.auto_apply_on_hook,
        auto_apply_em = probe3.auto_apply_em,
    }
    local ok = json.dump_file("quest_rando_spike_probe3.json", payload, 4)
    if ok then
        log_info("dumped Probe 3 -> quest_rando_spike_probe3.json")
    else
        log_info("json.dump_file failed for Probe 3")
    end
    return ok
end

-- =====================================================================
-- UI
-- =====================================================================

local state = {
    is_window_open = false,
}

local function draw_window()
    if not state.is_window_open then return end
    if not reframework:is_drawing_ui() then return end

    local ok, err = pcall(function()
        imgui.set_next_window_size(Vector2f.new(720, 560), 4)
        state.is_window_open = imgui.begin_window(
            "MHRise Quest Rando Spike", state.is_window_open, nil)
        if not state.is_window_open then
            imgui.end_window()
            return
        end

        imgui.text("Stage 1 research spike. See QUEST_PLAN.md.")
        imgui.text("Output: <install>/reframework/data/quest_rando_spike_*.json")
        imgui.text("")

        if imgui.collapsing_header("Probe 1 — quest-completion hook") then
            if not probe1.installed then
                if imgui.button("Install Probe 1 hooks") then
                    probe1_install_all()
                end
            else
                imgui.text("Hooks installed. Now in-game:")
                imgui.text("  1. Start + clear a village quest, then click MARK CLEAR.")
                imgui.text("  2. Start + fail a village quest (cart 3x), click MARK FAIL.")
                imgui.text("  3. Start + abandon a village quest, click MARK ABANDON.")
                imgui.text("Pass: a method that fires CLEAR=1 / FAIL=0 / ABANDON=0,")
                imgui.text("      with a non-nil quest_no.")
            end

            imgui.text("")
            imgui.text("Install log:")
            for _, line in ipairs(probe1.install_log) do
                imgui.text(line)
            end

            imgui.text("")
            if imgui.button("Mark pending as CLEAR") then
                probe1_classify_pending("CLEAR")
            end
            imgui.same_line()
            if imgui.button("Mark pending as FAIL") then
                probe1_classify_pending("FAIL")
            end
            imgui.same_line()
            if imgui.button("Mark pending as ABANDON") then
                probe1_classify_pending("ABANDON")
            end

            imgui.text("")
            if imgui.button("Dump Probe 1 JSON") then
                probe1_dump()
            end

            imgui.text("")
            imgui.text("Per-method tally:")
            imgui.text(probe1_summary_text())

            imgui.text("")
            imgui.text("Recent events (last 20):")
            imgui.begin_child_window("probe1_events",
                Vector2f.new(0, 200), true)
            imgui.text(probe1_recent_events_text(20))
            imgui.end_child_window()
        end

        imgui.text("")
        if imgui.collapsing_header("Probe 2 — ProgressQuestManager.setUnlock") then
            imgui.text(string.format(
                "Visible target (QL2): quest_no=%d  Hidden target (QL3): quest_no=%d",
                PROBE2_VISIBLE_QUEST_NO, PROBE2_HIDDEN_QUEST_NO))
            imgui.text("Test sequence:")
            imgui.text("  1. READ both targets (baseline).")
            imgui.text("  2. LOCK the visible target -> reopen village counter.")
            imgui.text("     Pass: quest disappears.")
            imgui.text("  3. UNLOCK the visible target -> reopen.")
            imgui.text("     Pass: quest reappears.")
            imgui.text("  4. UNLOCK the hidden target -> reopen.")
            imgui.text("     Pass(QL3 same gate): quest appears.")
            imgui.text("     Fail(QL3 has level gate): doesn't appear -- inspect isDisp.")

            imgui.text("")
            if imgui.button("READ visible (QL2)") then
                probe2_do_read(PROBE2_VISIBLE_QUEST_NO)
            end
            imgui.same_line()
            if imgui.button("LOCK visible") then
                probe2_do_set_unlock(PROBE2_VISIBLE_QUEST_NO, false)
            end
            imgui.same_line()
            if imgui.button("UNLOCK visible") then
                probe2_do_set_unlock(PROBE2_VISIBLE_QUEST_NO, true)
            end

            if imgui.button("READ hidden (QL3)") then
                probe2_do_read(PROBE2_HIDDEN_QUEST_NO)
            end
            imgui.same_line()
            if imgui.button("LOCK hidden") then
                probe2_do_set_unlock(PROBE2_HIDDEN_QUEST_NO, false)
            end
            imgui.same_line()
            if imgui.button("UNLOCK hidden") then
                probe2_do_set_unlock(PROBE2_HIDDEN_QUEST_NO, true)
            end

            imgui.text("")
            imgui.text("Resolve log:")
            for _, line in ipairs(probe2.install_log) do
                imgui.text(line)
            end

            imgui.text("")
            if imgui.button("Dump Probe 2 JSON") then
                probe2_dump()
            end

            imgui.text("")
            imgui.text("Recent actions (last 12):")
            imgui.begin_child_window("probe2_events",
                Vector2f.new(0, 200), true)
            imgui.text(probe2_recent_events_text(12))
            imgui.end_child_window()
        end
        imgui.text("")
        if imgui.collapsing_header("Probe 2b — checkUnlockCondition return override") then
            if not probe2b.installed then
                if imgui.button("Install Probe 2b hook") then
                    probe2b_install()
                end
            else
                imgui.text(string.format(
                    "Hook installed. Total fires: %d",
                    probe2b.fires))
                imgui.text("Procedure:")
                imgui.text("  1. Open village counter once to see baseline fires.")
                imgui.text("  2. Press 'Hide 202' -> reopen counter -> 202 should disappear.")
                imgui.text("  3. Press 'Show 303' -> reopen counter -> 303 should appear.")
                imgui.text("  4. Press 'Clear overrides' -> reopen counter -> back to vanilla.")
            end

            imgui.text("")
            if imgui.button("Hide 202 (visible -> hidden)") then
                probe2b_set_override(PROBE2_VISIBLE_QUEST_NO, false)
            end
            imgui.same_line()
            if imgui.button("Show 303 (hidden -> visible)") then
                probe2b_set_override(PROBE2_HIDDEN_QUEST_NO, true)
            end

            if imgui.button("Pass-through 202") then
                probe2b_set_override(PROBE2_VISIBLE_QUEST_NO, nil)
            end
            imgui.same_line()
            if imgui.button("Pass-through 303") then
                probe2b_set_override(PROBE2_HIDDEN_QUEST_NO, nil)
            end
            imgui.same_line()
            if imgui.button("Clear all overrides") then
                probe2b_clear_all()
            end

            imgui.text("")
            if imgui.button("READ 202 via hook") then
                probe2b_read_via_hook(PROBE2_VISIBLE_QUEST_NO)
            end
            imgui.same_line()
            if imgui.button("READ 303 via hook") then
                probe2b_read_via_hook(PROBE2_HIDDEN_QUEST_NO)
            end

            imgui.text("")
            imgui.text("Active overrides:")
            imgui.text(probe2b_overrides_text())

            imgui.text("")
            imgui.text("Install log:")
            for _, line in ipairs(probe2b.install_log) do
                imgui.text(line)
            end

            imgui.text("")
            if imgui.button("Dump Probe 2b JSON") then
                probe2b_dump()
            end

            imgui.text("")
            imgui.text("Recent fires (last 12):")
            imgui.begin_child_window("probe2b_fires",
                Vector2f.new(0, 180), true)
            imgui.text(probe2b_fires_text(12))
            imgui.end_child_window()
        end

        imgui.text("")
        if imgui.collapsing_header("Probe 3 — boss/target EmType Set rewrite") then
            imgui.text(string.format(
                "Target quest: quest_no=%d (Great Izuchi, vanilla em_type=98)",
                PROBE3_TARGET_QUEST_NO))
            imgui.text("PASS confirmed for spawn redirect (Magnamalo swap).")
            imgui.text("Outstanding: quest-info-screen icon doesn't change")
            imgui.text("  (likely sourced from _Icon[], not _BossEmType[0]).")
            imgui.text("")
            imgui.text("Use the preset buttons to apply additional test swaps.")

            imgui.text("")
            if not probe3.installed then
                if imgui.button("Install Probe 3 hook") then
                    probe3_install()
                end
            else
                imgui.text(string.format(
                    "Hook installed. Swap attempts: %d.  Applied: %s.",
                    probe3.swap_attempts, tostring(probe3.swap_applied)))
            end

            imgui.text("")
            imgui.text("Swap presets (apply immediately on click):")
            for _, p in ipairs(PROBE3_PRESETS) do
                if imgui.button("Apply: " .. p.name) then
                    probe3_apply_now(p.em)
                end
            end

            imgui.text("")
            imgui.text("Auto-apply at next initQuestDataDictionary fire:")
            local changed, new_val = imgui.checkbox(
                "auto_apply_on_hook", probe3.auto_apply_on_hook)
            if changed then probe3.auto_apply_on_hook = new_val end
            imgui.text(string.format(
                "  auto_apply_em = %d (edit PROBE3_PRESETS / probe3.auto_apply_em in code to change)",
                probe3.auto_apply_em))

            imgui.text("")
            imgui.text(string.format("vanilla_boss_em (first read): %s",
                tostring(probe3.vanilla_boss_em)))
            imgui.text(string.format("vanilla_tgt_em  (first read): %s",
                tostring(probe3.vanilla_tgt_em)))
            imgui.text(string.format("last_em_attempted:            %s",
                tostring(probe3.last_em_attempted)))
            imgui.text(string.format("post_boss_em:                 %s",
                tostring(probe3.post_boss_em)))
            imgui.text(string.format("post_tgt_em:                  %s",
                tostring(probe3.post_tgt_em)))
            if probe3.set_err then
                imgui.text("set_err: " .. probe3.set_err)
            end

            imgui.text("")
            imgui.text("Install log:")
            for _, line in ipairs(probe3.install_log) do
                imgui.text(line)
            end

            imgui.text("")
            if imgui.button("Dump Probe 3 JSON") then
                probe3_dump()
            end
        end

        imgui.end_window()
    end)
    if not ok then
        log_info("draw error: " .. safe_str(err))
    end
end

re.on_frame(function() draw_window() end)

re.on_draw_ui(function()
    if imgui.button("MHRise Quest Rando Spike") then
        state.is_window_open = not state.is_window_open
    end
end)

log.info("[quest-spike] Loaded.")

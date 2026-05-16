-- QuestRandoSpike — Stage 1 research spike for the quest randomizer mode.
--
-- See QUEST_PLAN.md "Stage 1 — Research spike". This file is the
-- single home for the spike's probes; each probe should produce a
-- clear pass/fail with evidence dumped to
-- <install>/reframework/data/quest_rando_spike_*.json.
--
-- Currently implemented:
--   Probe 1 — Quest-completion hook identification.
--
-- Pending:
--   Probe 2 — makeQuestNoList post-hook REMOVE (hide quest from board).
--   Probe 3 — _BossEmType[0]/_TgtEmType[0] array Set rewrite.
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
        if imgui.collapsing_header("Probe 2 — makeQuestNoList REMOVE (not implemented)") then
            imgui.text("Pending. See QUEST_PLAN.md Probe 2.")
        end
        if imgui.collapsing_header("Probe 3 — array Set rewrite (not implemented)") then
            imgui.text("Pending. See QUEST_PLAN.md Probe 3.")
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

-- Experimental: rewrite the active quest's target + boss EmType
-- arrays (NormalQuestData.Param._TgtEmType, ._BossEmType) at quest
-- start, redirecting both UI target and actual spawn to a hardcoded
-- EmType (Magnamalo, em_type 89).
--
-- Strategy:
--   * Hook snow.QuestManager.setupQuestEnemy() pre. This is the
--     first method we observed fire at quest start. It takes no
--     args, so we fetch the active QuestData via the QuestManager
--     singleton's _RawNormal field (or getQuestData on the active
--     quest no).
--   * Overwrite Param._TgtEmType[0] and ._BossEmType[0] with
--     TARGET_EM_TYPE via direct memory write (RE Engine array
--     layout: 0x20-byte header, then packed i32 elements).
--
-- Why this method (not getQuestData, not setupQuestEnemyPosition):
--   - Hooking getQuestData mutated EVERY quest's Param the moment
--     its details were queried, poisoning the whole quest catalog.
--     Story progression broke.
--   - Hooking setupQuestEnemyPosition was too late: writes landed
--     but the engine had already consumed the EmType list.
--   - setupQuestEnemy fires earlier than Position in the prep
--     chain, AND only at quest start (not on UI preview), so it
--     scopes the mutation to the one quest we're about to play.
--
-- Dev-only. Drop into <install>/reframework/autorun/. No AP server
-- connection needed.

if reframework:get_game_name() ~= "mhrise" then return end

log.info("[quest-swap] Loading...")

local TARGET_EM_TYPE = 89  -- Magnamalo (matches ap_world/data/monsters.py)
local TARGET_LABEL = "Magnamalo (em_type 89)"

local hooked = false


local function log_info(msg) log.info("[quest-swap] " .. msg) end

-- Both prior post-hook variants crashed even when read-only —
-- suggesting that holding the args[4] List<EmTypes> pointer across
-- the call boundary is itself unsafe. Switch to a pre-hook only,
-- read-only experiment: just snapshot the list and the QuestData,
-- log them, and DO NOT carry anything over to the post-hook. If
-- this is crash-free, the problem really is "raw arg pointer goes
-- stale by the post-hook" and the workaround for the actual swap
-- will be to re-fetch via the QuestManager singleton's
-- _QuestTargetEmTypeList field after the call returns.
--
-- args layout (REFramework convention):
--   args[1] = method-table junk
--   args[2] = `this`
--   args[3] = QuestData
--   args[4] = List<EmTypes>
--   args[5] = bool (boxed)

-- Helper: overwrite slot 0 of a managed EmTypes[] array.
-- The array is a reference type (System.Array). Setting an
-- element via :call("SetValue", index, value) is the safe shape;
-- raw int → boxed enum slot.
local function overwrite_em_array(array_obj, label)
    if not array_obj then
        log_info("  " .. label .. ": nil array, skipping")
        return
    end
    local len = -1
    pcall(function() len = array_obj:call("get_Length") end)
    if type(len) ~= "number" or len < 1 then
        log_info(string.format("  %s: length=%s, skipping", label, tostring(len)))
        return
    end
    local before = nil
    pcall(function() before = array_obj:call("GetValue", 0) end)

    -- Array.SetValue refuses raw Int32 -> EmTypes-typed slot.
    -- Bypass CLR reflection by writing element memory directly.
    -- Managed System.Array on RE Engine x64: a fixed header (0x20
    -- bytes) followed by tightly packed elements. EmTypes is i32
    -- so element 0 lives at offset 0x20 from the array's base.
    -- REManagedObject exposes write_dword/qword/etc. relative to
    -- the object's own address — perfect for this.
    -- Element layout confirmed: i32 elements packed at +0x20, with
    -- the dword length at +0x1c. Write only the slots [0..len-1] that
    -- are real entries; trailing sentinel slots in _BossEmType end
    -- past `len` and the engine doesn't iterate past it, so we leave
    -- them alone (writing past len was what caused the spawn-loop
    -- crash earlier).
    -- Only overwrite slot 0. _TgtEmType (len=2) and _BossEmType
    -- (len=7) are fixed-size containers; trailing slots past the
    -- "real" entries hold sentinel EM_None values, and overwriting
    -- those with a real EmType makes the UI try to render and the
    -- spawn loop try to materialize ghost monsters. Slot 0 is the
    -- primary target/boss; that's the one we want to redirect.
    local before, after = nil, nil
    pcall(function() before = array_obj:read_dword(0x20) end)
    pcall(function() array_obj:write_dword(0x20, TARGET_EM_TYPE) end)
    pcall(function() after = array_obj:read_dword(0x20) end)
    log_info(string.format("  %s: len=%d, [0] 0x%x -> 0x%x",
        label, len,
        type(before) == "number" and before or 0,
        type(after) == "number" and after or 0))
end

local function mutate_quest_data(qd)
    if not qd then return end
    local raw_normal = nil
    pcall(function() raw_normal = qd:call("get_RawNormal") end)
    if not raw_normal then
        log_info("active QuestData has no RawNormal (not a normal quest?)")
        return
    end
    local tgt_arr, boss_arr
    pcall(function() tgt_arr = raw_normal:get_field("_TgtEmType") end)
    pcall(function() boss_arr = raw_normal:get_field("_BossEmType") end)
    log_info("mutating active QuestData -> " .. TARGET_LABEL)
    overwrite_em_array(tgt_arr, "_TgtEmType")
    overwrite_em_array(boss_arr, "_BossEmType")
end

-- DIAGNOSTIC: pre-hook does nothing but log "fired" with a count.
-- If the game crashes on quest start without this line ever being
-- logged, the act of installing the hook on setupQuestEnemy is
-- itself destabilizing on this build (same failure shape as the
-- earlier makeQuestTargetData_Normal experiment). If the line IS
-- logged and then the crash follows, the hook itself is fine and
-- something else broke.
local pre_hook_fire_count = 0
local function pre_hook(_args)
    pre_hook_fire_count = pre_hook_fire_count + 1
    log_info("pre: setupQuestEnemy fired #" .. pre_hook_fire_count)
end

local function post_hook(_retval) end

local function install()
    if hooked then return end
    local td = sdk.find_type_definition("snow.QuestManager")
    if not td then log_info("QuestManager type not found"); return end

    local method = td:get_method("setupQuestEnemy")
    if not method then log_info("setupQuestEnemy not found"); return end
    sdk.hook(method, pre_hook, post_hook)
    hooked = true
    log_info("hooked setupQuestEnemy -> rewrite active quest to " .. TARGET_LABEL)
end

install()

log.info("[quest-swap] Loaded.")

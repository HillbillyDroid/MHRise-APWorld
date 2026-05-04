-- MHRiseDebug — interactive REFramework explorer plugin.
--
-- Dev-only. Drop into <install>/reframework/autorun/ to use; never
-- bundled into the player client zip (see .github/workflows/release.yml
-- AUTORUN_FILES allow-list).
--
-- Two sections:
--   1. Type dump — input a managed-type name, get fields + methods
--      printed inline and dumped to JSON.
--   2. Tree search — case-insensitive substring search across the
--      full type database (types / fields / methods toggleable).
--
-- Independent of MHRiseAP.lua: no AP slot connection required, no
-- AP_REF/AP_CLIENT modules imported.

if reframework:get_game_name() ~= "mhrise" then return end

log.info("[mhrise-debug] Loading...")

local LOG_TAG = "[mhrise-debug] "
local SEARCH_CAP = 500

local state = {
    type_input = "snow.QuestManager",
    search_input = "",
    search_match_types = true,
    search_match_fields = true,
    search_match_methods = true,
    type_dump_preview = nil,
    search_results_preview = nil,
    is_window_open = false,
}

local function log_info(msg) log.info(LOG_TAG .. msg) end

local function sanitize(name)
    return (tostring(name):gsub("[^%w%-]", "_"))
end

local function safe_str(v)
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "<tostring error>"
end

local function method_signature(method)
    local name = method:get_name()
    local rt = "?"
    local ok_rt = pcall(function()
        local r = method:get_return_type()
        if r then rt = r:get_full_name() end
    end)
    if not ok_rt then rt = "?" end
    local params = {}
    pcall(function()
        for _, pt in ipairs(method:get_param_types() or {}) do
            params[#params + 1] = pt:get_full_name()
        end
    end)
    return name, rt, params
end

local function dump_type(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then
        local msg = string.format("<type not found: %s>", type_name)
        log_info(msg)
        state.type_dump_preview = msg
        return
    end

    local parent_name = nil
    pcall(function()
        local parent = td:get_parent_type()
        if parent then parent_name = parent:get_full_name() end
    end)

    local fields = {}
    pcall(function()
        for _, field in ipairs(td:get_fields() or {}) do
            local row = {
                name = field:get_name(),
                type = "?",
                is_static = false,
                is_literal = false,
                value = nil,
            }
            pcall(function()
                local ft = field:get_type()
                if ft then row.type = ft:get_full_name() end
            end)
            pcall(function() row.is_static = field:is_static() end)
            pcall(function() row.is_literal = field:is_literal() end)
            -- Reading data on non-static fields without an instance, and
            -- on certain literal types, can throw. pcall + only attempt
            -- when static.
            if row.is_static then
                pcall(function()
                    local v = field:get_data(nil)
                    if type(v) == "number" or type(v) == "string"
                            or type(v) == "boolean" then
                        row.value = v
                    end
                end)
            end
            fields[#fields + 1] = row
        end
    end)

    local methods = {}
    pcall(function()
        for _, method in ipairs(td:get_methods() or {}) do
            local name, rt, params = method_signature(method)
            methods[#methods + 1] = {
                name = name,
                return_type = rt,
                param_types = params,
            }
        end
    end)

    local payload = {
        type = type_name,
        parent_type = parent_name,
        fields = fields,
        methods = methods,
    }

    local out_name = "mhrise_type_" .. sanitize(type_name) .. ".json"
    local ok_dump = json.dump_file(out_name, payload, 4)
    if ok_dump then
        log_info(string.format("dumped %s: %d fields, %d methods -> %s",
            type_name, #fields, #methods, out_name))
    else
        log_info(string.format("json.dump_file failed for %s", out_name))
    end

    -- Build inline preview text.
    local lines = {}
    lines[#lines + 1] = "type: " .. type_name
    lines[#lines + 1] = "parent: " .. tostring(parent_name)
    lines[#lines + 1] = string.format("fields (%d):", #fields)
    for _, f in ipairs(fields) do
        local prefix = f.is_static and "static " or ""
        if f.is_literal then prefix = prefix .. "literal " end
        local val = ""
        if f.value ~= nil then val = " = " .. safe_str(f.value) end
        lines[#lines + 1] = string.format("  %s%s %s%s",
            prefix, f.type, f.name, val)
    end
    lines[#lines + 1] = string.format("methods (%d):", #methods)
    for _, m in ipairs(methods) do
        lines[#lines + 1] = string.format("  %s %s(%s)",
            m.return_type, m.name, table.concat(m.param_types, ", "))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "JSON written to <install>/reframework/data/."
    state.type_dump_preview = table.concat(lines, "\n")
end

local function lower(s) return tostring(s):lower() end

local function search_tdb(keyword)
    if not keyword or keyword == "" then
        state.search_results_preview = "Enter a keyword first"
        return
    end
    if not (state.search_match_types or state.search_match_fields
            or state.search_match_methods) then
        state.search_results_preview = "Enable at least one of types/fields/methods"
        return
    end

    -- This REFramework build (MH Rise) does not expose any direct TDB
    -- enumeration API — sdk.* only has find_type_definition (lookup by
    -- exact name) and typeof. To enumerate every type we go through the
    -- managed reflection API instead: sdk.typeof(seed) returns a real
    -- System.Type, and from there System.Reflection.Assembly.GetTypes()
    -- gives us every type in that assembly. Walking
    -- AppDomain.CurrentDomain.GetAssemblies() then GetTypes() on each
    -- covers the whole loaded type universe.
    local td_list = {}
    local enum_err = nil
    pcall(function()
        -- Static method call: invoke on the RETypeDefinition with no
        -- instance (passing nil/no this). REFramework's instance-style
        -- :call("get_CurrentDomain") on a System.Type doesn't dispatch
        -- to statics — we need to go through the type-def's method.
        local app_domain_td = sdk.find_type_definition("System.AppDomain")
        if not app_domain_td then enum_err = "find_type_definition(System.AppDomain) failed"; return end
        local get_current = app_domain_td:get_method("get_CurrentDomain")
        if not get_current then enum_err = "AppDomain.get_CurrentDomain method missing"; return end
        local current_domain = get_current:call(nil)
        if not current_domain then enum_err = "get_CurrentDomain():call(nil) returned nil"; return end
        local assemblies = current_domain:call("GetAssemblies")
        if not assemblies then enum_err = "GetAssemblies returned nil"; return end
        local n_asm = assemblies:get_size()
        for ai = 0, n_asm - 1 do
            local asm = assemblies:get_element(ai)
            if asm then
                local types_arr
                pcall(function() types_arr = asm:call("GetTypes") end)
                if types_arr then
                    local n_t = types_arr:get_size()
                    for ti = 0, n_t - 1 do
                        local sys_type = types_arr:get_element(ti)
                        if sys_type then
                            local full_name
                            pcall(function() full_name = sys_type:call("get_FullName") end)
                            if type(full_name) == "string" and full_name ~= "" then
                                local td = sdk.find_type_definition(full_name)
                                if td then td_list[#td_list + 1] = td end
                            end
                        end
                    end
                end
            end
        end
    end)
    if #td_list == 0 then
        local msg = "type enumeration via System.AppDomain failed: "
            .. tostring(enum_err or "no types collected")
        log_info(msg)
        state.search_results_preview = msg
        return
    end

    local needle = lower(keyword)
    local results = {}
    local truncated = false
    local n_types = #td_list

    for i = 1, n_types do
        if #results >= SEARCH_CAP then truncated = true; break end
        local td = td_list[i]
        if td then
            local tname = ""
            pcall(function() tname = td:get_full_name() or "" end)
            local tname_lc = lower(tname)

            if state.search_match_types and tname_lc:find(needle, 1, true) then
                results[#results + 1] = tname
                if #results >= SEARCH_CAP then truncated = true; break end
            end

            if state.search_match_fields then
                local ok = pcall(function()
                    for _, field in ipairs(td:get_fields() or {}) do
                        if #results >= SEARCH_CAP then truncated = true; break end
                        local fname = field:get_name() or ""
                        if lower(fname):find(needle, 1, true) then
                            results[#results + 1] = string.format("%s.%s",
                                tname, fname)
                        end
                    end
                end)
                if not ok then end -- swallow per-type field walk errors
                if truncated then break end
            end

            if state.search_match_methods then
                local ok = pcall(function()
                    for _, method in ipairs(td:get_methods() or {}) do
                        if #results >= SEARCH_CAP then truncated = true; break end
                        local mname, _rt, params = method_signature(method)
                        if lower(mname):find(needle, 1, true) then
                            results[#results + 1] = string.format("%s:%s(%s)",
                                tname, mname, table.concat(params, ", "))
                        end
                    end
                end)
                if not ok then end
                if truncated then break end
            end
        end
    end

    local out_name = "mhrise_search_" .. sanitize(keyword) .. ".json"
    local ok_dump = json.dump_file(out_name, {
        keyword = keyword,
        match_types = state.search_match_types,
        match_fields = state.search_match_fields,
        match_methods = state.search_match_methods,
        truncated = truncated,
        results = results,
    }, 4)
    if ok_dump then
        log_info(string.format("search '%s': %d results%s -> %s",
            keyword, #results, truncated and " (truncated)" or "", out_name))
    else
        log_info(string.format("json.dump_file failed for %s", out_name))
    end

    local lines = {}
    lines[#lines + 1] = string.format("results: %d%s",
        #results, truncated and " (truncated, refine keyword)" or "")
    for _, r in ipairs(results) do
        lines[#lines + 1] = "  " .. r
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "JSON written to <install>/reframework/data/."
    state.search_results_preview = table.concat(lines, "\n")
end

local function draw_window()
    if not state.is_window_open then return end
    if not reframework:is_drawing_ui() then return end

    local ok, err = pcall(function()
        imgui.set_next_window_size(Vector2f.new(640, 720), 4)
        state.is_window_open = imgui.begin_window(
            "MHRise Debug", state.is_window_open, nil)
        if state.is_window_open then
            if imgui.collapsing_header("Type dump") then
                local changed_t, val_t = imgui.input_text(
                    "Type name", state.type_input)
                if changed_t then state.type_input = val_t end
                if imgui.button("Dump") then
                    dump_type(state.type_input)
                end
                imgui.begin_child_window("type_dump_preview",
                    Vector2f.new(0, 280), true)
                if state.type_dump_preview then
                    imgui.text(state.type_dump_preview)
                else
                    imgui.text("(no dump yet)")
                end
                imgui.end_child_window()
            end

            if imgui.collapsing_header("Tree search") then
                local changed_k, val_k = imgui.input_text(
                    "Keyword", state.search_input)
                if changed_k then state.search_input = val_k end
                local cmt, vmt = imgui.checkbox("Match types",
                    state.search_match_types)
                if cmt then state.search_match_types = vmt end
                imgui.same_line()
                local cmf, vmf = imgui.checkbox("Match fields",
                    state.search_match_fields)
                if cmf then state.search_match_fields = vmf end
                imgui.same_line()
                local cmm, vmm = imgui.checkbox("Match methods",
                    state.search_match_methods)
                if cmm then state.search_match_methods = vmm end
                if imgui.button("Search") then
                    search_tdb(state.search_input)
                end
                imgui.begin_child_window("search_results_preview",
                    Vector2f.new(0, 320), true)
                if state.search_results_preview then
                    imgui.text(state.search_results_preview)
                else
                    imgui.text("(no search yet)")
                end
                imgui.end_child_window()
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
    if imgui.button("MHRise Debug") then
        state.is_window_open = not state.is_window_open
    end
end)

log.info("[mhrise-debug] Loaded.")

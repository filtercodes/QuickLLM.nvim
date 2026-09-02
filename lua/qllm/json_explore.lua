local M = {}
local Window = require("qllm.window")
local Ui = require("qllm.ui")

-- Module-level cache to store decoded Lua tables for each popup buffer.
-- This bypasses the slow serialization/copying overhead of crossing the vim.b boundary.
local json_cache = {}

-- Module-level cache to persist state for files across popup lifetimes (within the session)
M.saved_paths = {}

local find_folding_index -- Forward declaration

local function get_perf_log_path()
    local path = vim.fn.stdpath("state")
    if not path or path == "" then
        path = vim.fn.stdpath("cache")
    end
    return path .. "/qllm_perf.log"
end

local function save_undo_state(bufnr)
    local path = vim.b[bufnr].json_path or {}
    local fold = vim.b[bufnr].json_active_fold_idx
    local path_copy = {}
    for i, v in ipairs(path) do
        path_copy[i] = v
    end
    vim.b[bufnr].json_last_path = path_copy
    vim.b[bufnr].json_last_fold_idx = fold
end

local function show_transient_warning(msg)
    vim.api.nvim_echo({{ msg, "WarningMsg" }}, false, {})
end

local function save_path_state(filepath, path, active_fold_idx, search_query, search_results, search_index)
    if filepath == "" then return end
    if not M.saved_paths[filepath] then
        M.saved_paths[filepath] = {
            cursor_positions = {}
        }
    end
    if path ~= nil then
        M.saved_paths[filepath].path = path
    end
    if active_fold_idx ~= nil then
        M.saved_paths[filepath].active_fold_idx = active_fold_idx
    end
    if search_query ~= nil then
        M.saved_paths[filepath].search_query = search_query
    end
    if search_results ~= nil then
        M.saved_paths[filepath].search_results = search_results
    end
    if search_index ~= nil then
        M.saved_paths[filepath].search_index = search_index
    end
end

local function save_current_cursor(bufnr)
    local filepath = vim.b[bufnr].json_file or ""
    if filepath == "" then return end

    local path = vim.b[bufnr].json_path or {}
    local path_key = "root." .. table.concat(path, ".")
    local cursor = vim.api.nvim_win_get_cursor(0)

    save_path_state(filepath, path, vim.b[bufnr].json_active_fold_idx)
    M.saved_paths[filepath].cursor_positions[path_key] = cursor
end

---Recursively searches a decoded JSON structure for keys and values matching query.
---@param data any The JSON object/array/value.
---@param query string The search query (case-insensitive substring).
---@return table results Array of match objects: { parent_path = table, target_key = any, val = any, match_type = string }
local function execute_search(data, query)
    local results = {}
    if not query or query == "" or data == nil then
        return results
    end

    local query_lower = string.lower(query)

    local function traverse(node, current_path)
        if type(node) == "table" then
            -- Check if it's an array or object
            local is_array = true
            local max_idx = 0
            local keys = {}
            for k in pairs(node) do
                if type(k) == "number" then
                    if k > max_idx then max_idx = k end
                else
                    is_array = false
                end
                table.insert(keys, k)
            end

            if is_array and #keys > 0 then
                for i = 1, max_idx do
                    local val = node[i]
                    local new_path = {}
                    for _, p in ipairs(current_path) do table.insert(new_path, p) end
                    table.insert(new_path, i)

                    if type(val) == "table" then
                        traverse(val, new_path)
                    else
                        local val_str = string.lower(tostring(val))
                        if string.find(val_str, query_lower, 1, true) then
                            table.insert(results, {
                                parent_path = current_path,
                                target_key = i,
                                val = val,
                                match_type = "value",
                            })
                        end
                    end
                end
            else
                -- Sort keys for deterministic search ordering
                table.sort(keys, function(a, b)
                    return tostring(a) < tostring(b)
                end)
                for _, k in ipairs(keys) do
                    local val = node[k]
                    local k_str = tostring(k)
                    local new_path = {}
                    for _, p in ipairs(current_path) do table.insert(new_path, p) end
                    table.insert(new_path, k)

                    local key_matched = false
                    -- Match key name
                    if string.find(string.lower(k_str), query_lower, 1, true) then
                        key_matched = true
                        table.insert(results, {
                            parent_path = current_path,
                            target_key = k,
                            val = val,
                            match_type = "key",
                        })
                    end

                    if type(val) == "table" then
                        traverse(val, new_path)
                    else
                        -- Match primitive value
                        local val_str = string.lower(tostring(val))
                        if string.find(val_str, query_lower, 1, true) then
                            if not key_matched then
                                table.insert(results, {
                                    parent_path = current_path,
                                    target_key = k,
                                    val = val,
                                    match_type = "value",
                                })
                            end
                        end
                    end
                end
            end
        else
            -- Root primitive value
            local val_str = string.lower(tostring(node))
            if string.find(val_str, query_lower, 1, true) then
                table.insert(results, {
                    parent_path = {},
                    target_key = nil,
                    val = node,
                    match_type = "value",
                })
            end
        end
    end

    traverse(data, {})
    return results
end

local function restore_cursor(bufnr)
    local filepath = vim.b[bufnr].json_file or ""
    local path = vim.b[bufnr].json_path or {}
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    -- 0. Check if search mode is active and snap cursor to the target matched key/leaf
    if vim.b[bufnr].json_search_mode then
        local results = vim.b[bufnr].json_search_results or {}
        local idx = vim.b[bufnr].json_search_index or 1
        local match = results[idx]
        if match and match.target_key ~= nil then
            local key_str = tostring(match.target_key)
            local target_prefix_1 = "▶ [" .. key_str .. "]"
            local target_prefix_2 = "  [" .. key_str .. "]"
            for line_idx = 1, line_count do
                local line_content = vim.api.nvim_buf_get_lines(bufnr, line_idx - 1, line_idx, false)[1] or ""
                if string.find(line_content, target_prefix_1, 1, true) == 1 or
                   string.find(line_content, target_prefix_2, 1, true) == 1 then
                    pcall(vim.api.nvim_win_set_cursor, 0, { line_idx, 0 })
                    return
                end
            end
        end
    end

    -- 1. Check if returning from a sub-path and focus the child key we came from
    local old_path = vim.b[bufnr].json_old_path
    local focused_from_parent = false
    if old_path and #old_path > #path then
        local is_prefix = true
        for i = 1, #path do
            if old_path[i] ~= path[i] then
                is_prefix = false
                break
            end
        end
        if is_prefix then
            local came_from_key = old_path[#path + 1]
            if came_from_key then
                local target_prefix_1 = "▶ [" .. tostring(came_from_key) .. "]"
                local target_prefix_2 = "  [" .. tostring(came_from_key) .. "]"
                for idx = 1, line_count do
                    local line_content = vim.api.nvim_buf_get_lines(bufnr, idx - 1, idx, false)[1] or ""
                    if string.find(line_content, target_prefix_1, 1, true) == 1 or
                       string.find(line_content, target_prefix_2, 1, true) == 1 then
                        pcall(vim.api.nvim_win_set_cursor, 0, { idx, 0 })
                        focused_from_parent = true
                        break
                    end
                end
            end
        end
        -- Always clear old_path state after checking
        vim.b[bufnr].json_old_path = nil
    end

    if focused_from_parent then
        return
    end

    -- 2. Scan the buffer to locate the first expandable child node (starting with "▶ ")
    local first_child_line = nil
    for idx = 1, line_count do
        local line_content = vim.api.nvim_buf_get_lines(bufnr, idx - 1, idx, false)[1] or ""
        if string.sub(line_content, 1, 4) == "▶ " then
            first_child_line = idx
            break
        end
    end

    -- If an expandable child exists, snap to it. Otherwise, default to line 5 (or 4 if empty)
    local default_line = first_child_line or math.min((#path > 0) and 5 or 4, line_count)

    if filepath == "" then 
        vim.api.nvim_win_set_cursor(0, {default_line, 0})
        return 
    end

    local path_key = "root." .. table.concat(path, ".")
    local saved = M.saved_paths[filepath]

    if saved and saved.cursor_positions and saved.cursor_positions[path_key] then
        local cursor = saved.cursor_positions[path_key]
        local row = math.min(cursor[1], line_count)
        -- Never let the restored cursor sit automatically on the parent navigator line (line 4)
        if #path > 0 and row == 4 then
            row = math.min(5, line_count)
        end
        pcall(vim.api.nvim_win_set_cursor, 0, {row, cursor[2]})
    else
        vim.api.nvim_win_set_cursor(0, {default_line, 0})
    end
end

function M.render(bufnr)
    -- Clear command-line area of any previous warnings on successful node/path changes
    vim.cmd("echo ''")

    local start_time = vim.loop.hrtime()
    -- Fetch the JSON data from the fast, pure Lua memory cache
    local data = json_cache[bufnr]
    local path = vim.b[bufnr].json_path or {}
    local filepath = vim.b[bufnr].json_file or ""

    local t1 = vim.loop.hrtime()

    -- Navigate to the target node
    local node = data
    for _, key in ipairs(path) do
        if type(node) == "table" then
            node = node[key]
        else
            node = nil
            break
        end
    end

    local t2 = vim.loop.hrtime()

    local lines = {}
    local is_search = vim.b[bufnr].json_search_mode == true
    local search_query = vim.b[bufnr].json_search_query or ""
    local search_results = vim.b[bufnr].json_search_results or {}
    local search_idx = vim.b[bufnr].json_search_index or 1

    local header_title = "# JSON Explorer: " .. vim.fn.fnamemodify(filepath, ":t")
    if is_search and search_query ~= "" then
        header_title = string.format("%s [SEARCH: %q (%d/%d)]", header_title, search_query, (#search_results > 0 and search_idx or 0), #search_results)
    end
    table.insert(lines, header_title)
    
    if #path > 0 then
        table.insert(lines, "Path: `root." .. table.concat(path, ".") .. "`")
        table.insert(lines, "")
        table.insert(lines, "◀ [..] (back to parent)")
    else
        table.insert(lines, "Path: `root`")
        table.insert(lines, "")
    end

    if type(node) == "table" then
        -- Check if it's an array or a dictionary
        local is_array = true
        local max_idx = 0
        local keys = {}
        for k in pairs(node) do
            if type(k) == "number" then
                if k > max_idx then max_idx = k end
            else
                is_array = false
            end
            table.insert(keys, k)
        end

        if is_array and #keys > 0 then
            -- Render array items
            for i = 1, max_idx do
                local val = node[i]
                if type(val) == "table" then
                    table.insert(lines, string.format("▶ [%d]", i))
                else
                    table.insert(lines, string.format("  [%d] = %s", i, vim.inspect(val)))
                end
            end
        else
            -- Render object keys sorted alphabetically
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for _, k in ipairs(keys) do
                local val = node[k]
                if type(val) == "table" then
                    table.insert(lines, string.format("▶ [%s]", tostring(k)))
                else
                    table.insert(lines, string.format("  [%s] = %s", tostring(k), vim.inspect(val)))
                end
            end
        end
    else
        table.insert(lines, "Value:")
        table.insert(lines, "  " .. vim.inspect(node))
    end

    -- If we are nested and there are no children, append an empty line
    -- to allow the cursor to sit on line 5 instead of clamping to the parent navigator (line 4).
    if #path > 0 and #lines < 5 then
        table.insert(lines, "")
    end

    local t3 = vim.loop.hrtime()

    -- Universal approach: If enabled, scan all generated lines and split any containing '\n' into actual newlines
    if vim.g.qllm_json_newline then
        local expanded_lines = {}
        for _, line in ipairs(lines) do
            local clean_line = line:gsub("\\n", "\n"):gsub("\\r", "")
            for sub_line in string.gmatch(clean_line .. "\n", "(.-)\n") do
                table.insert(expanded_lines, sub_line)
            end
        end
        lines = expanded_lines
    end

    -- Make buffer modifiable to update lines, then set unmodifiable
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)

    -- Validate and potentially clear json_active_fold_idx if it exceeds current path length
    local active_fold = vim.b[bufnr].json_active_fold_idx
    if active_fold and active_fold > #path then
        vim.b[bufnr].json_active_fold_idx = nil
    end

    -- Clear and set active folding highlight on Path line (line 2 of buffer, index 1)
    local ns_id = vim.api.nvim_create_namespace("qllm_json_fold_hl")
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    
    local fold_idx = find_folding_index(path, bufnr)
    if fold_idx and #path > 0 then
        local prefix = "Path: `root."
        local current_pos = #prefix
        for i = 1, fold_idx - 1 do
            current_pos = current_pos + #tostring(path[i]) + 1
        end
        local start_col = current_pos
        local end_col = current_pos + #tostring(path[fold_idx])
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "IncSearch", 1, start_col, end_col)
    end

    local t4 = vim.loop.hrtime()

    -- Log render details (in milliseconds)
    if vim.g.qllm_log_enabled == true then
        local log_msg = string.format(
            "  [PERF_RENDER] get_vars=%.2fms, traverse=%.2fms, generate_lines=%.2fms, set_lines=%.2fms, total=%.2fms\n",
            (t1 - start_time) / 1e6,
            (t2 - t1) / 1e6,
            (t3 - t2) / 1e6,
            (t4 - t3) / 1e6,
            (t4 - start_time) / 1e6
        )
        local f = io.open(get_perf_log_path(), "a")
        if f then
            f:write(log_msg)
            f:close()
        end
    end

    -- Restore saved cursor position for this path, or default to first child
    restore_cursor(bufnr)
end

function M.handle_enter(bufnr)
    save_current_cursor(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1]
    local col = cursor[2]
    local filepath = vim.b[bufnr].json_file or ""

    -- Save undo state before changing path or active fold
    save_undo_state(bufnr)

    -- Reset virtual paging index on any navigation or fold change
    vim.b[bufnr].json_virtual_index = nil

    -- If cursor is on the Path line (line 2)
    if row == 2 then
        local path = vim.b[bufnr].json_path or {}
        local prefix = "Path: `root."
        local prefix_len = #prefix

        if #path == 0 or col < prefix_len then
            vim.b[bufnr].json_active_fold_idx = nil
            if filepath ~= "" then
                save_path_state(filepath, path, nil)
            end
            vim.notify("json_explore: Reset to default folding point.", vim.log.levels.INFO, { title = "qLLM" })
            M.render(bufnr)
            return
        end

        local current_pos = prefix_len
        local selected_idx = nil
        for idx, segment in ipairs(path) do
            local segment_str = tostring(segment)
            local start_col = current_pos
            local end_col = current_pos + #segment_str - 1

            if col >= start_col and col <= end_col then
                selected_idx = idx
                break
            end
            current_pos = current_pos + #segment_str + 1
        end

        if selected_idx then
            local part = path[selected_idx]
            if type(part) == "number" or (type(part) == "string" and tonumber(part) ~= nil) then
                vim.b[bufnr].json_active_fold_idx = selected_idx
                if filepath ~= "" then
                    save_path_state(filepath, path, selected_idx)
                end
                vim.notify(string.format("json_explore: Active folding index set to segment %d (%s)", selected_idx, tostring(part)), vim.log.levels.INFO, { title = "qLLM" })
                M.render(bufnr)
            else
                vim.notify("json_explore: Selected segment is not a number. Folding requires a numeric index.", vim.log.levels.WARN, { title = "qLLM" })
            end
        end
        return
    end

    local line = vim.api.nvim_get_current_line()
    local path = vim.b[bufnr].json_path or {}

    -- Check if back navigation
    if line:find("◀ %[%.%.%]") then
        if #path > 0 then
            local old_path = {}
            for i, v in ipairs(path) do old_path[i] = v end
            vim.b[bufnr].json_old_path = old_path

            table.remove(path)
            vim.b[bufnr].json_path = path
            if filepath ~= "" then
                save_path_state(filepath, path, vim.b[bufnr].json_active_fold_idx)
            end
            M.render(bufnr)
        end
        return
    end

    -- Check if drilling into an object/array
    local key = line:match("▶ %[(.-)%]")
    if key then
        -- Convert numeric key if it represents an array index
        local num = tonumber(key)
        if num then
            table.insert(path, num)
        else
            table.insert(path, key)
        end
        vim.b[bufnr].json_path = path
        if filepath ~= "" then
            save_path_state(filepath, path, vim.b[bufnr].json_active_fold_idx)
        end
        M.render(bufnr)
        return
    end
end

function find_folding_index(path, bufnr)
    if bufnr then
        local active = vim.b[bufnr].json_active_fold_idx
        if active and active <= #path then
            local part = path[active]
            if type(part) == "number" or (type(part) == "string" and tonumber(part) ~= nil) then
                return active
            end
        end
    end

    local start_idx = 1
    if bufnr then
        start_idx = (vim.b[bufnr].json_initial_path_len or 0) + 1
    end
    for i = start_idx, #path do
        local part = path[i]
        if type(part) == "number" or (type(part) == "string" and tonumber(part) ~= nil) then
            return i
        end
    end
    return nil
end

---Cycles the cursor forward or backward through lines that are expandable child nodes (starting with '▶ ' or '◀ ').
---@param bufnr number The UI buffer number.
---@param direction string "forward" or "backward".
function M.jump_to_expandable_child(bufnr, direction)
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    local start_offset = (direction == "forward") and 1 or -1
    local step = (direction == "forward") and 1 or -1

    local index = cur_line + start_offset
    local iterations = 0

    while iterations < line_count do
        -- Wrap around indices (1-indexed lines)
        if index > line_count then
            index = 1
        elseif index < 1 then
            index = line_count
        end

        local line_content = vim.api.nvim_buf_get_lines(bufnr, index - 1, index, false)[1] or ""
        -- Match keys or parents that can open
        if string.sub(line_content, 1, 4) == "▶ " or string.sub(line_content, 1, 5) == "◀ " then
            pcall(vim.api.nvim_win_set_cursor, 0, { index, 0 })
            return
        end

        index = index + step
        iterations = iterations + 1
    end
end

function M.navigate(bufnr, direction)
    save_current_cursor(bufnr)
    local start_time = vim.loop.hrtime()
    local path = vim.b[bufnr].json_path or {}
    if #path == 0 then
        show_transient_warning("json_explore: Cannot navigate on root path.")
        return
    end

    local fold_idx = find_folding_index(path, bufnr)
    if not fold_idx then
        show_transient_warning("json_explore: No numeric folding index found in current path.")
        return
    end

    local count = vim.v.count > 0 and vim.v.count or 1
    local current_val = tonumber(path[fold_idx])

    -- Retrieve tracking virtual index, falling back to current active path index
    local virtual_index = vim.b[bufnr].json_virtual_index or current_val
    local next_virtual = virtual_index + (direction == "forward" and count or -count)
    if next_virtual < 1 then
        show_transient_warning("json_explore: Cannot decrement index below 1.")
        return
    end

    -- Save new virtual index tracking state
    vim.b[bufnr].json_virtual_index = next_virtual

    -- Build target path to test if it exists
    local target_path = {}
    for i = 1, #path do
        target_path[i] = path[i]
    end

    local old_val = path[fold_idx]
    if type(old_val) == "number" then
        target_path[fold_idx] = next_virtual
    else
        target_path[fold_idx] = tostring(next_virtual)
    end

    local t1 = vim.loop.hrtime()

    -- Verify if the target path actually exists in the data
    local data = json_cache[bufnr]
    local temp = data
    local exists = true
    for i = 1, #target_path do
        if type(temp) == "table" then
            temp = temp[target_path[i]]
        else
            exists = false
            break
        end
    end

    local t2 = vim.loop.hrtime()

    if not exists or temp == nil then
        -- Notify warning but do not modify the active path or redraw the UI
        show_transient_warning(string.format("json_explore: Index %d out of bounds or path doesn't exist.", next_virtual))
        return
    end

    -- Target path exists: Save undo state, then update active path and json_path state
    save_undo_state(bufnr)
    path[fold_idx] = target_path[fold_idx]
    vim.b[bufnr].json_path = path

    -- Save to persistent state
    local filepath = vim.b[bufnr].json_file or ""
    if filepath ~= "" then
        save_path_state(filepath, path, vim.b[bufnr].json_active_fold_idx)
    end

    local t3 = vim.loop.hrtime()
    M.render(bufnr)
    local t4 = vim.loop.hrtime()

    -- Log duration details (in milliseconds)
    if vim.g.qllm_log_enabled == true then
        local log_msg = string.format(
            "[PERF] Navigate: path_setup=%.2fms, verify=%.2fms, path_save=%.2fms, render=%.2fms, total=%.2fms\n",
            (t1 - start_time) / 1e6,
            (t2 - t1) / 1e6,
            (t3 - t2) / 1e6,
            (t4 - t3) / 1e6,
            (t4 - start_time) / 1e6
        )
        local f = io.open(get_perf_log_path(), "a")
        if f then
            f:write(log_msg)
            f:close()
        end
    end
end

function M.undo_navigation(bufnr)
    local last_path = vim.b[bufnr].json_last_path
    local last_fold = vim.b[bufnr].json_last_fold_idx

    if not last_path then
        vim.notify("json_explore: No undo history available.", vim.log.levels.WARN, { title = "qLLM" })
        return
    end

    local current_path = vim.b[bufnr].json_path or {}
    local current_fold = vim.b[bufnr].json_active_fold_idx

    local current_path_copy = {}
    for i, v in ipairs(current_path) do
        current_path_copy[i] = v
    end

    -- Swap current and last
    vim.b[bufnr].json_path = last_path
    vim.b[bufnr].json_active_fold_idx = last_fold
    vim.b[bufnr].json_last_path = current_path_copy
    vim.b[bufnr].json_last_fold_idx = current_fold

    -- Reset virtual index when undoing
    vim.b[bufnr].json_virtual_index = nil

    local filepath = vim.b[bufnr].json_file or ""
    if filepath ~= "" then
        save_path_state(filepath, last_path, last_fold)
    end

    M.render(bufnr)
end

---Exits search mode on the given buffer and returns to normal navigation mode.
---@param bufnr number The UI buffer number.
function M.exit_search(bufnr)
    if vim.b[bufnr].json_search_mode then
        vim.b[bufnr].json_search_mode = false
        vim.notify("json_explore: Exited search mode.", vim.log.levels.INFO, { title = "qLLM" })
        M.render(bufnr)
    end
end

---Iterates forward or backward through search results.
---@param bufnr number The UI buffer number.
---@param direction string "forward" or "backward".
function M.navigate_search(bufnr, direction)
    save_current_cursor(bufnr)
    local results = vim.b[bufnr].json_search_results or {}
    if #results == 0 then
        show_transient_warning("json_explore: No search results found.")
        return
    end

    local count = vim.v.count > 0 and vim.v.count or 1
    local cur_idx = vim.b[bufnr].json_search_index or 1
    local total = #results

    local next_idx
    if direction == "forward" then
        next_idx = ((cur_idx - 1 + count) % total) + 1
    else
        next_idx = ((cur_idx - 1 - count) % total)
        if next_idx < 0 then next_idx = next_idx + total end
        next_idx = next_idx + 1
    end

    vim.b[bufnr].json_search_index = next_idx
    local match = results[next_idx]

    -- Save state
    local filepath = vim.b[bufnr].json_file or ""
    if filepath ~= "" and M.saved_paths[filepath] then
        M.saved_paths[filepath].search_index = next_idx
    end

    -- Update path to match's parent path
    local target_path = {}
    for i, v in ipairs(match.parent_path) do
        target_path[i] = v
    end
    vim.b[bufnr].json_path = target_path

    M.render(bufnr)
end

---Opens interactive search input for the JSON explorer buffer.
---@param bufnr number The UI buffer number.
function M.prompt_search(bufnr)
    local current_query = vim.b[bufnr].json_search_query or ""
    vim.ui.input({ prompt = "JSON Search: ", default = current_query }, function(input)
        if input == nil then
            -- User pressed Esc / cancelled prompt
            return
        end

        local query = vim.trim(input)
        if query == "" then
            -- Empty input: exit search mode and return to normal mode
            M.exit_search(bufnr)
            return
        end

        local data = json_cache[bufnr]
        local results = execute_search(data, query)

        if #results == 0 then
            show_transient_warning(string.format("json_explore: No matches for %q", query))
            return
        end

        local filepath = vim.b[bufnr].json_file or ""
        local search_idx = 1
        -- Check if it's the same query as saved, resume index
        if filepath ~= "" and M.saved_paths[filepath] and M.saved_paths[filepath].search_query == query then
            search_idx = math.min(M.saved_paths[filepath].search_index or 1, #results)
        end

        vim.b[bufnr].json_search_mode = true
        vim.b[bufnr].json_search_query = query
        vim.b[bufnr].json_search_results = results
        vim.b[bufnr].json_search_index = search_idx

        if filepath ~= "" then
            if not M.saved_paths[filepath] then
                M.saved_paths[filepath] = { cursor_positions = {} }
            end
            M.saved_paths[filepath].search_query = query
            M.saved_paths[filepath].search_results = results
            M.saved_paths[filepath].search_index = search_idx
        end

        local match = results[search_idx]
        local target_path = {}
        for i, v in ipairs(match.parent_path) do
            target_path[i] = v
        end
        vim.b[bufnr].json_path = target_path

        M.render(bufnr)
    end)
end

function M.start_explorer(filepath, initial_path, bufnr, search_query)
    local expanded = vim.fn.expand(filepath)
    if vim.fn.filereadable(expanded) ~= 1 then
        vim.notify("json_explore: File not found or unreadable: " .. filepath, vim.log.levels.ERROR, { title = "qLLM" })
        return
    end

    local file_content = table.concat(vim.fn.readfile(expanded), "\n")
    local ok, decoded = pcall(vim.fn.json_decode, file_content)
    if not ok or not decoded then
        vim.notify("json_explore: Failed to parse JSON file: " .. filepath, vim.log.levels.ERROR, { title = "qLLM" })
        return
    end

    -- Create popup window using centralized Ui.create_window to register ownership
    local ui_elem = Ui.create_window("markdown", bufnr, nil, nil, nil, nil, true)
    local ui_bufnr = ui_elem.bufnr

    -- Setup buffer-local state inside pure Lua cache
    json_cache[ui_bufnr] = decoded

    -- Setup deletion handler to purge pure Lua cache
    local event = require("nui.utils.autocmd").event
    ui_elem:on(event.BufDelete, function()
        json_cache[ui_bufnr] = nil
    end)

    -- Check persistent cache first
    local saved = M.saved_paths[expanded]
    local use_path = initial_path or {}
    local use_fold_idx = nil
    -- Only use saved path if the user didn't specify a custom initial path via args
    if saved and (#use_path == 0) then
        use_path = saved.path
        use_fold_idx = saved.active_fold_idx
    end

    -- Setup search state if search_query passed
    local is_search = false
    local search_results = {}
    local search_idx = 1

    if search_query and search_query ~= "" then
        search_results = execute_search(decoded, search_query)
        if #search_results > 0 then
            is_search = true
            -- Check if same query was saved to resume index
            if saved and saved.search_query == search_query then
                search_idx = math.min(saved.search_index or 1, #search_results)
            else
                search_idx = 1
            end
            use_path = search_results[search_idx].parent_path
            if saved then
                saved.search_query = search_query
                saved.search_results = search_results
                saved.search_index = search_idx
            end
        else
            vim.notify(string.format("json_explore: No matches for %q", search_query), vim.log.levels.WARN, { title = "qLLM" })
        end
    end

    vim.b[ui_bufnr].json_path = use_path
    vim.b[ui_bufnr].json_initial_path_len = #(initial_path or {})
    vim.b[ui_bufnr].json_file = expanded
    vim.b[ui_bufnr].json_active_fold_idx = use_fold_idx
    vim.b[ui_bufnr].json_search_mode = is_search
    vim.b[ui_bufnr].json_search_query = search_query or (saved and saved.search_query) or ""
    vim.b[ui_bufnr].json_search_results = is_search and search_results or (saved and saved.search_results) or {}
    vim.b[ui_bufnr].json_search_index = is_search and search_idx or (saved and saved.search_index) or 1
    vim.b[ui_bufnr].qllm_metadata = { command = "json_explore" }

    -- Map Enter key in this buffer to handle navigation
    vim.keymap.set("n", "<CR>", function()
        M.handle_enter(ui_bufnr)
    end, { buffer = ui_bufnr, silent = true })

    -- Map Backspace to go back
    vim.keymap.set("n", "<BS>", function()
        save_current_cursor(ui_bufnr)
        local path = vim.b[ui_bufnr].json_path or {}
        if #path > 0 then
            save_undo_state(ui_bufnr)
            local old_path = {}
            for i, v in ipairs(path) do old_path[i] = v end
            vim.b[ui_bufnr].json_old_path = old_path

            table.remove(path)
            vim.b[ui_bufnr].json_path = path
            vim.b[ui_bufnr].json_virtual_index = nil
            if expanded ~= "" then
                save_path_state(expanded, path, vim.b[ui_bufnr].json_active_fold_idx)
            end
            M.render(ui_bufnr)
        end
    end, { buffer = ui_bufnr, silent = true })

    -- Map search trigger key (default: <c-s>)
    local search_key = (vim.g.qllm_ui_commands and vim.g.qllm_ui_commands.search) or "<c-s>"
    vim.keymap.set("n", search_key, function()
        M.prompt_search(ui_bufnr)
    end, { buffer = ui_bufnr, silent = true })

    -- Map <Esc> to exit search mode if active, otherwise handle double-esc quit
    local last_esc_time = 0
    vim.keymap.set("n", "<Esc>", function()
        if vim.b[ui_bufnr].json_search_mode then
            M.exit_search(ui_bufnr)
        else
            if vim.g.qllm_quit_with_double_esc then
                local now = vim.loop.now()
                if now - last_esc_time < 500 then
                    ui_elem:unmount()
                else
                    last_esc_time = now
                end
            end
        end
    end, { buffer = ui_bufnr, silent = true })

    -- Map f to go forward, d to go backward in search results or numeric folding points
    vim.keymap.set("n", "f", function()
        if vim.b[ui_bufnr].json_search_mode then
            M.navigate_search(ui_bufnr, "forward")
        else
            M.navigate(ui_bufnr, "forward")
        end
    end, { buffer = ui_bufnr, silent = true })

    vim.keymap.set("n", "d", function()
        if vim.b[ui_bufnr].json_search_mode then
            M.navigate_search(ui_bufnr, "backward")
        else
            M.navigate(ui_bufnr, "backward")
        end
    end, { buffer = ui_bufnr, silent = true })

    -- Map c to jump to next expandable child, C to jump to previous
    vim.keymap.set("n", "c", function()
        M.jump_to_expandable_child(ui_bufnr, "forward")
    end, { buffer = ui_bufnr, silent = true })

    vim.keymap.set("n", "C", function()
        M.jump_to_expandable_child(ui_bufnr, "backward")
    end, { buffer = ui_bufnr, silent = true })

    -- Map u to undo
    vim.keymap.set("n", "u", function()
        M.undo_navigation(ui_bufnr)
    end, { buffer = ui_bufnr, silent = true })

    -- Set filetype to markdown for syntax highlighting
    vim.api.nvim_buf_set_option(ui_bufnr, "filetype", "markdown")

    -- Initial render
    M.render(ui_bufnr)
end

return M

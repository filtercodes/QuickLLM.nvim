local M = {}

---Expands a list of file patterns (including wildcards) into absolute paths.
---@param patterns table A list of strings (e.g. {"*.lua", "src/*.js"})
---@return table A list of valid, readable file paths.
function M.resolve_patterns(patterns)
    local files = {}
    local seen = {}

    for _, pattern in ipairs(patterns) do
        -- Remove potential quotes from individual patterns if they were split naively
        local clean_pattern = pattern:gsub('^["\'`]', ''):gsub('["\'`]$', '')

        -- Support multiple files in a single quoted string (e.g. "src/a.lua src/b.lua")
        local sub_patterns = vim.split(clean_pattern, "%s+")

        for _, sub_pattern in ipairs(sub_patterns) do
            if sub_pattern ~= "" then
                -- Expand ~ manually if present to ensure glob works correctly
                if sub_pattern:match("^~") then
                    sub_pattern = vim.fn.expand(sub_pattern)
                end

                local expanded = vim.fn.glob(sub_pattern, true, true)
                for _, path in ipairs(expanded) do
                    if vim.fn.filereadable(path) == 1 and not seen[path] then
                        table.insert(files, path)
                        seen[path] = true
                    end
                end
            end
        end
    end
    return files
end

---Calculates a hash for a file to detect changes.
---@param path string
---@return string?
function M.get_file_hash(path)
    if vim.fn.filereadable(path) ~= 1 then return nil end
    local lines = vim.fn.readfile(path)
    local content = table.concat(lines, "\n")
    return vim.fn.sha256(content)
end

---Reads the content of multiple files and formats them into a single string.
---@param files table A list of absolute file paths.
---@return string The formatted content block.
function M.format_files_as_context(files)
    local context = ""
    for _, path in ipairs(files) do
        local lines = vim.fn.readfile(path)
        local content = table.concat(lines, "\n")
        context = context .. string.format("\nFILE: %s\n```%s\n%s\n```\n---\n", 
            path, 
            vim.filetype.match({ filename = path }) or "text", 
            content)
    end
    return context
end

---Parses the input string to find delimited blocks, search queries, and prompt.
---Handles escaped characters like \" or \`.
---@param input string The full command input (e.g. 'files [file 1.lua] my query -- prompt')
---@param command string? The command being executed.
---@return table extracted List of strings from file delimiters.
---@return string? query Content from query ' -- ' separator (only for scan).
---@return string remaining Everything else.
function M.parse_input(input, command)
    local extracted = {}
    local remaining = input
    local query = nil

    -- 1. Extract File Blocks [...]
    local function extract_next_file(str)
        local delimiters = {
            { '[', ']' }
        }
        
        for _, d in ipairs(delimiters) do
            local start_char = d[1]
            local end_char = d[2]
            
            local start_idx = str:find("^" .. vim.pesc(start_char))
            if not start_idx then
                start_idx = str:find("%s" .. vim.pesc(start_char))
                if start_idx then start_idx = start_idx + 1 end
            end

            if start_idx then
                local content = ""
                local i = start_idx + 1
                while i <= #str do
                    local char = str:sub(i, i)
                    if char == "\\" then
                        content = content .. (str:sub(i + 1, i + 1) or "")
                        i = i + 2
                    elseif char == end_char then
                        local full_match = str:sub(start_idx, i)
                        return content, full_match, i
                    else
                        content = content .. char
                        i = i + 1
                    end
                end
            end
        end
        return nil
    end

    while true do
        local content, full_match, end_pos = extract_next_file(remaining)
        if content then
            table.insert(extracted, content)
            remaining = vim.trim(remaining:sub(end_pos + 1))
        else
            break
        end
    end

    -- 2. Extract Query via ' -- ' separator (Only for scan command)
    if command == "scan" then
        -- Find the first occurrence of " -- " (space-double-dash-space)
        local sep_start, sep_end = remaining:find(" %-%- ")
        if sep_start then
            query = vim.trim(remaining:sub(1, sep_start - 1))
            remaining = vim.trim(remaining:sub(sep_end + 1))
        else
            -- If no separator, the entire remaining string is the query
            query = remaining
            remaining = ""
        end
    end

    return extracted, query, remaining
end

---Finds files containing the query using rg, git grep, or grep from the project root.
---@param query string
---@param project_root string
---@return table files
function M.find_files_with_query(query, project_root)
    local files = {}
    local cmd
    if vim.fn.executable("rg") == 1 then
        cmd = string.format("rg -l --max-count 1 -F %s %s", vim.fn.shellescape(query), vim.fn.shellescape(project_root))
    elseif vim.fn.executable("git") == 1 and vim.fn.isdirectory(project_root .. ".git") == 1 then
        cmd = string.format("git -C %s grep -l -F %s", vim.fn.shellescape(project_root), vim.fn.shellescape(query))
    elseif vim.fn.executable("grep") == 1 then
        cmd = string.format("grep -r -l -F %s %s", vim.fn.shellescape(query), vim.fn.shellescape(project_root))
    end

    if cmd then
        local output = vim.fn.systemlist(cmd)
        if vim.v.shell_error == 0 or #output > 0 then
            for _, line in ipairs(output) do
                local path = vim.trim(line)
                if path ~= "" and vim.fn.filereadable(path) == 1 then
                    table.insert(files, path)
                end
            end
        end
    end

    return files
end

---Attempts to find the containing code block (function/method/class) for a matched line using Tree-sitter.
---@param content string
---@param filetype string
---@param line_num number
---@return number? start_line, number? end_line
function M.get_containing_block_range(content, filetype, line_num)
    local ok, parser = pcall(vim.treesitter.get_string_parser, content, filetype)
    if not ok or not parser then return nil end

    local tree = parser:parse()[1]
    if not tree then return nil end
    local root = tree:root()
    if not root then return nil end

    local line_idx = line_num - 1
    local node = root:descendant_for_range(line_idx, 0, line_idx, 1000)
    if not node then return nil end

    local function is_code_block(node_type)
        if node_type == "program" or node_type == "source_file" or node_type == "translation_unit" then
            return false
        end
        local t = node_type:lower()
        return t:find("function")
            or t:find("method")
            or t:find("class")
            or t:find("struct")
            or t:find("impl")
            or t:find("definition")
            or t:find("declaration")
    end

    local current = node
    while current do
        if is_code_block(current:type()) then
            local start_row, _, end_row, _ = current:range()
            return start_row + 1, end_row + 1
        end
        current = current:parent()
    end
    return nil
end

---Performs a hybrid search (scan) across files and returns matching chunks.
---@param files table List of resolved file paths.
---@param query string The search query.
---@param context_lines number? Number of lines around the match to include.
---@return string The formatted search results.
function M.scan_search(files, query, context_lines)
    local results = ""
    -- Use global variable for context or default to 3
    local kb_opts = vim.g.qllm_kb_opts
    local ctx = context_lines or (kb_opts and kb_opts.scan_context) or 3
    
    for _, path in ipairs(files) do
        local lines = vim.fn.readfile(path)
        local matches = {}

        for i, line in ipairs(lines) do
            -- Case-insensitive find
            if line:lower():find(query:lower(), 1, true) then
                table.insert(matches, i)
            end
        end

        if #matches > 0 then
            local content = table.concat(lines, "\n")
            local filetype = vim.filetype.match({ filename = path }) or "text"
            results = results .. string.format("\nFILE: %s (Matches for '%s')\n", vim.fn.fnamemodify(path, ":."), query)
            local last_end = -1

            for _, line_num in ipairs(matches) do
                local start_i, end_i

                -- Attempt Tree-Sitter block extraction
                local ts_start, ts_end = M.get_containing_block_range(content, filetype, line_num)
                if ts_start and ts_end then
                    start_i = ts_start
                    end_i = ts_end
                end

                -- Fallback to standard context window if TS failed
                if not start_i or not end_i then
                    start_i = math.max(1, line_num - ctx)
                    end_i = math.min(#lines, line_num + ctx)
                end

                if start_i <= last_end then
                    start_i = last_end + 1
                end

                if start_i <= end_i then
                    local chunk = {}
                    for k = start_i, end_i do
                        table.insert(chunk, lines[k])
                    end
                    results = results .. string.format("L%d-L%d:\n```%s\n%s\n```\n", start_i, end_i, filetype, table.concat(chunk, "\n"))
                    last_end = end_i
                end
            end
            results = results .. "---\n"
        end
    end
    return results
end

---Orchestrates context gathering for all commands.
---@param command string The command name.
---@param args_str string The raw command arguments string.
---@param current_bufnr number The current buffer.
---@param current_selection string? Optional current visual selection.
---@param overrides table? Optional overrides passed from the command runner.
---@return string? command The resolved command name.
---@return string command_args The prompt/arguments for the LLM.
---@return string text_selection The injected context.
---@return table overrides Table with queue_user_message and ground_include_queue.
function M.handle_context_command(command, args_str, current_bufnr, current_selection, overrides)
    local CommandsList = require("qllm.commands_list")
    local ProjectContext = require("qllm.project_context")

    local is_explicit_cmd = CommandsList.is_valid_cmd(command)

    -- Strip the command name from the beginning of the raw args string
    -- 1. Parse Input
    local raw_input = args_str
    if is_explicit_cmd then
        raw_input = vim.trim(args_str:sub(#command + 1))
    end
    local extracted_blocks, query, remaining_prompt = M.parse_input(raw_input, command)
    
    local command_args = remaining_prompt
    local text_selection = current_selection or ""
    overrides = overrides or {}
    overrides.ground_include_queue = false
    overrides.queue_metadata = {}

    -- Project Context Injection
    -- 2. Project Context (System Project Map) Injection
    local project_map = ProjectContext.get_active_context()
    local project_root = ProjectContext.get_project_root()
    if project_map then
        local kb_opts = vim.g.qllm_kb_opts
        if kb_opts and kb_opts.auto_check_freshness then
            ProjectContext.check_freshness()
        end
    end

    -- Fallback: If no files were wrapped, scan the prompt for raw paths
    -- 3. File Context Resolution
    -- Fallback for unquoted files if it's a files/scan command
    if #extracted_blocks == 0 and (command == "files" or command == "scan") then
        local new_remaining = {}
        for word in remaining_prompt:gmatch("%S+") do
            -- Expand ~ manually if present
            local pattern = word
            if pattern:match("^~") then
                pattern = vim.fn.expand(pattern)
            end

            local expanded = vim.fn.glob(pattern, true, true)
            local is_file = false
            for _, path in ipairs(expanded) do
                if vim.fn.filereadable(path) == 1 then
                    is_file = true
                    break
                end
            end
            if is_file then
                table.insert(extracted_blocks, word)
            else
                table.insert(new_remaining, word)
            end
        end
        remaining_prompt = table.concat(new_remaining, " ")
        command_args = remaining_prompt
    end

    -- If there's no prompt explicitly typed after the files, but the user has selected text,
    -- use the selected text as the prompt for the files (only for files/scan commands).
    -- Handle Selection-to-Prompt fallback
    if (command == "files" or command == "scan" or command == "query" or not is_explicit_cmd)
        and remaining_prompt == "" and current_selection ~= "" then
        -- We assume the visual selection in this context is meant to be the prompt/instructions
        command_args = current_selection
        -- Clear text_selection so it doesn't get injected twice
        text_selection = ""
    end

    local resolved_files = {}
    if #extracted_blocks > 0 then
        resolved_files = M.resolve_patterns(extracted_blocks)
        -- If files found but no command, or command is 'query', upgrade to 'files'
        if not is_explicit_cmd or command == "query" then
            command = "files"
        end
    elseif command == "scan" then
        local search_query = query or remaining_prompt
        if search_query and search_query ~= "" then
            resolved_files = M.find_files_with_query(search_query, project_root)
        end
        -- Fallback to current file if no project matches found or search query is empty
        if #resolved_files == 0 then
            local current_file = vim.api.nvim_buf_get_name(current_bufnr)
            if current_file ~= "" then
                resolved_files = { current_file }
            end
        end
    end

    -- 4. Determine if we should inject project context (only if relevant to current project)
    local system_context = ""
    if project_map then
        local use_project_context = false
        if #resolved_files > 0 then
            for _, path in ipairs(resolved_files) do
                -- Check if file is a child of the project root
                if path:sub(1, #project_root) == project_root then
                    use_project_context = true
                    break
                end
            end
        else
            -- If no files resolved, check if current buffer is in project
            local current_file = vim.api.nvim_buf_get_name(current_bufnr)
            if current_file ~= "" and current_file:sub(1, #project_root) == project_root then
                use_project_context = true
            end
        end

        if use_project_context then
            system_context = "\n[SYSTEM PROJECT CONTEXT]\n" .. project_map .. "\n---\n"
        end
    end

    -- 5. Command-Specific Formatting and Metadata
    local context_files_display = #extracted_blocks > 0 and table.concat(extracted_blocks, ", ")
        or (#resolved_files > 0 and vim.fn.fnamemodify(resolved_files[1], ":t") or "")

    if #resolved_files > 0 then
        if command == "files" then
            local context_text = M.format_files_as_context(resolved_files)
            if command_args == "" then
                overrides.queue_user_message = "FILES ANALYSIS: " .. context_files_display
            else
                overrides.queue_user_message = "FILES: " .. command_args .. " in [" .. context_files_display .. "]"
            end
            -- Append original text_selection (if any remains) to the file context (omitting system_context / qLLM.md)
            text_selection = context_text .. ((text_selection ~= "") and ("\n[USER SELECTION]\n" .. text_selection) or "")
        elseif command == "scan" then
            -- 1. Determine the search query (prioritize <query> brackets)
            local search_query = query or remaining_prompt

            if search_query and search_query ~= "" then
                local context_text = M.scan_search(resolved_files, search_query)

                -- 2. Determine prompt behavior
                if query and remaining_prompt ~= "" then
                    -- Both <query> and a prompt provided: Send to LLM
                    text_selection = system_context .. context_text
                    overrides.queue_user_message = "SCAN: " .. search_query .. " -- " .. remaining_prompt .. " in [" .. context_files_display .. "]"
                    overrides.queue_metadata.search_results = context_text
                else
                    -- No prompt provided: Just display results in a popup, bypass LLM.
                    local Ui = require("qllm.ui")
                    local Utils = require("qllm.utils")
                    local lines = Utils.parse_lines(context_text)
                    if #lines == 0 then table.insert(lines, "No matches found for: " .. search_query) end
                    
                    Ui.popup(lines, "markdown", current_bufnr)
                    return nil, "", "", {}
                end
            end
        else
            -- For other commands (e.g. :Que [A.lua] explain), just inject the files as context
            local context_text = M.format_files_as_context(resolved_files)
            text_selection = system_context .. context_text .. ((text_selection ~= "") and ("\n[USER SELECTION]\n" .. text_selection) or "")

            -- Override queue user message to show clean context
            local suffix = " in [" .. context_files_display .. "]"
            local prompt_str = command_args ~= "" and command_args or (command:upper() .. suffix)
            if command_args ~= "" then
                prompt_str = prompt_str .. suffix
            end
            overrides.queue_user_message = prompt_str
        end
    else
        -- Standard 'explain' injection
        -- No files, just inject system context into text_selection
        text_selection = system_context .. text_selection

        -- For other commands with visual selection but no files
        if text_selection ~= "" and text_selection ~= system_context then
            local prompt_str = command_args ~= "" and command_args or (command:upper() .. " (selection)")
            if command_args ~= "" then
                prompt_str = prompt_str .. " (selection)"
            end
            overrides.queue_user_message = prompt_str
        end
    end

    -- Setup overrides.queue_metadata for structured storage
    overrides.queue_metadata = overrides.queue_metadata or {}
    if #resolved_files > 0 then
        overrides.queue_metadata.files = resolved_files
    end
    -- Keep only the pure selection context (without the prepended system context)
    local selection_context = current_selection or ""
    if command_args == selection_context then
        -- Avoid saving the prompt text itself as a duplicate selection
        selection_context = ""
    end
    if selection_context ~= "" then
        overrides.queue_metadata.selection = selection_context
    end

    if command == "search" then
        overrides.queue_user_message = command_args ~= "" and command_args or "SEARCH"
    end

    -- Final fallback for command if it's still not valid
    if not CommandsList.is_valid_cmd(command) then
        command = "query"
    end

    return command, command_args, text_selection, overrides
end

return M

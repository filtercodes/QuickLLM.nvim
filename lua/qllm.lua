local Commands = require("qllm.commands")
local CommandsList = require("qllm.commands_list")
local Utils = require("qllm.utils")
local Ui = require("qllm.ui")
local Queue = require("qllm.queue")
local qllmModule = {}

local function has_command_args(opts)
    local pattern = "%{%{command_args%}%}"
    return string.find(opts.user_message_template or "", pattern)
        or string.find(opts.system_message_template or "", pattern)
end

function qllmModule.get_status(...)
    return Commands.get_status(...)
end

function qllmModule.run_cmd(opts)
    local text_selection = Utils.get_selected_lines()
    local command_args = table.concat(opts.fargs, " ")
    local command = opts.fargs[1]
    local bufnr = nil
    local is_ui_window = false

    -- Determine Context and which buffer is Queue Owner
    local current_bufnr = vim.api.nvim_get_current_buf()
    local owner_bufnr = Ui.get_owner_bufnr(current_bufnr)

    if owner_bufnr then
        is_ui_window = true
        bufnr = owner_bufnr -- Queue is always the owner's
    else
        bufnr = current_bufnr -- Queue is the current buffer's
    end

    -- Handle `clear` as a special case that doesn't need validation
    -- 1. HANDLE UTILITY COMMANDS (Early Return)
    if command == "clear" and #opts.fargs == 1 then
        Queue.clear_queue(bufnr)
        vim.b[bufnr].qllm_metadata = nil
        Ui.close_active_popup(current_bufnr)
        vim.notify("Chat queue cleared for this buffer.", vim.log.levels.INFO, { title = "qLLM" })
        return -- Stop all further processing
    end

    local is_recall = command and command:find("^recall") ~= nil
    local show_question = command and command:find("q$") ~= nil
    local is_recall_action = false
    local recall_offset = 1
    
    if is_recall then
        if #opts.fargs == 1 then
            is_recall_action = true
            recall_offset = 1
        elseif #opts.fargs == 2 then
            local arg = opts.fargs[2]
            local num = tonumber(arg)
            if num and num > 0 and math.floor(num) == num then
                is_recall_action = true
                recall_offset = num
            elseif arg == "backward" then
                is_recall_action = true
                recall_offset = (vim.b[bufnr].qllm_recall_index or 0) + 1
            elseif arg == "forward" then
                is_recall_action = true
                recall_offset = math.max(1, (vim.b[bufnr].qllm_recall_index or 1) - 1)
            end
        end
    end

    if is_recall_action then
        local last_response, model, cmd, cursor_pos, question = Queue.get_last_response(bufnr, recall_offset)
        local display_text = show_question and question or last_response

        if display_text then
            -- Store index, metadata, and show_question flag on the owner buffer
            -- so that the popup buffer can inherit it for traversal.
            vim.b[bufnr].qllm_recall_index = recall_offset
            vim.b[bufnr].qllm_metadata = { model = model, command = cmd }
            vim.b[bufnr].qllm_show_question = show_question

            local start_row, start_col, end_row, end_col = Utils.get_visual_selection()
            Ui.popup(Utils.parse_lines(display_text), vim.g.qllm_text_popup_filetype, bufnr, start_row, start_col, end_row, end_col, (not show_question and cursor_pos or nil))
        else
            local msg = show_question and "question" or "assistant response"
            vim.notify(string.format("No %s found at queue index %d for this buffer.", msg, recall_offset), vim.log.levels.WARN, { title = "qLLM" })
        end
        return
    end

    local is_undo = command == "undo"
    if is_undo and #opts.fargs == 1 then
        local success = Queue.undo_last_exchange(bufnr)
        if success then
            vim.notify("Last conversation exchange removed from queue.", vim.log.levels.INFO, { title = "qLLM" })
        else
            vim.notify("No queue to undo.", vim.log.levels.WARN, { title = "qLLM" })
        end
        return
    end

    -- Handle `help` as a special case
    if command == "help" and #opts.fargs == 1 then
        local Help = require("qllm.help")
        Help.show_help(bufnr)
        return
    end

    -- Handle popup command as a special case (session workspace popup)
    if command == "popup" then
        local p_buf = Ui.get_or_create_workspace_buf()
        -- If the workspace popup is currently visible, toggle or focus it
        if Ui.has_active_popup(p_buf) then
            local current_win = vim.api.nvim_get_current_win()
            local p_win = vim.fn.bufwinid(p_buf)
            if p_win ~= -1 and current_win == p_win then
                -- Focused in workspace popup: toggle close
                Ui.close_active_popup(p_buf)
                return
            elseif p_win ~= -1 then
                -- Open but not focused: switch focus to popup
                vim.api.nvim_set_current_win(p_win)
                return
            end
        end

        local ui_elem = Ui.create_window(filetype, bufnr, nil, nil, nil, nil, true, p_buf)
        return ui_elem
    end

    -- list: show all buffers that have chat queue
    if command == "list" and #opts.fargs == 1 then
        local entries = Queue.list_queue_buffers()

        if #entries == 0 then
            vim.notify("No chat queue exists for any buffer.", vim.log.levels.INFO, { title = "qLLM" })
            return
        end

        -- Probe token-counting availability once on the first entry.
        -- If it returns nil (no tiktoken / no python) we fall back to the
        -- otherwise use compact layout so the user sees no ugly error columns.
        local tokens_available = false
        if #entries > 0 then
            local probe, probe_err = Queue.get_queue_token_count(entries[1].bufnr)
            tokens_available = (probe ~= nil)
        end

        -- Header ────────────────────────────────────────────────────────
        local lines
        if tokens_available then
            lines = { "  bufnr │ messages │ tokens  │ last model      │ buffer name" }
            table.insert(lines, string.rep("─", 68))
        else
            lines = { "  bufnr │ messages │ last model      │ buffer name" }
            table.insert(lines, string.rep("─", 60))
        end

        -- Rows ──────────────────────────────────────────────────────────
        for _, e in ipairs(entries) do
            local age = ""
            if e.last_ts then
                local secs = os.time() - e.last_ts
                if     secs < 60   then age = secs                     .. "s ago"
                elseif secs < 3600 then age = math.floor(secs / 60)   .. "m ago"
                else                    age = math.floor(secs / 3600) .. "h ago"
                end
            end

            if tokens_available then
                local tok_count = Queue.get_queue_token_count(e.bufnr) or 0
                table.insert(lines, string.format(
                    "  %-6d│ %-9d│ %-8d│ %-16s│ %s  (%s)",
                    e.bufnr,
                    e.msg_count,
                    tok_count,
                    e.last_model:sub(1, 16),
                    e.buf_name,
                    age
                ))
            else
                table.insert(lines, string.format(
                    "  %-6d│ %-9d│ %-16s│ %s  (%s)",
                    e.bufnr,
                    e.msg_count,
                    e.last_model:sub(1, 16),
                    e.buf_name,
                    age
                ))
            end
        end

        -- Reuse the existing popup renderer
        Ui.popup(lines, "markdown", bufnr, nil, nil, nil, nil, nil)
        return
    end

    -- copy: copy queue from a source buffer into the current buffer ─────
    if command == "copy" then
        --  :Que copy          -> copy from alternate buffer (#)
        --  :Que copy 7        -> copy from bufnr 7
        --  :Que copy 7 merge  -> merge instead of replace

        local src_bufnr
        local merge = false

        -- Parse args
        for i = 2, #opts.fargs do
            local arg = opts.fargs[i]
            if arg == "merge" then
                merge = true
            else
                local n = tonumber(arg)
                if n then
                    src_bufnr = n
                else
                    vim.notify(
                        "copy: unrecognised argument '" .. arg .. "'. Usage: copy [bufnr] [merge]",
                        vim.log.levels.ERROR, { title = "qLLM" }
                    )
                    return
                end
            end
        end

        -- Default: use the alternate buffer
        if not src_bufnr then
            src_bufnr = vim.fn.bufnr('#')
            if src_bufnr == -1 then
                vim.notify(
                    "copy: no alternate buffer found. Specify a bufnr explicitly, e.g. :Que copy 3",
                    vim.log.levels.WARN, { title = "qLLM" }
                )
                return
            end
        end

        if not vim.api.nvim_buf_is_valid(src_bufnr) then
            vim.notify(
                string.format("copy: buffer %d is not valid.", src_bufnr),
                vim.log.levels.ERROR, { title = "qLLM" }
            )
            return
        end

        local ok, err = Queue.copy_queue(src_bufnr, bufnr, { merge = merge })

        if ok then
            local src_entries = Queue.list_queue_buffers()
            local src_count = 0
            for _, e in ipairs(src_entries) do
                if e.bufnr == src_bufnr then src_count = e.msg_count; break end
            end

            vim.notify(
                string.format(
                    "Copied %d messages from buf %d → buf %d%s.",
                    src_count, src_bufnr, bufnr,
                    merge and " (merged)" or " (replaced)"
                ),
                vim.log.levels.INFO, { title = "qLLM" }
            )
        else
            vim.notify("copy failed: " .. (err or "unknown error"), vim.log.levels.ERROR, { title = "qLLM" })
        end
        return
    end

    -- Handle `heavy` as a special case
    if command == "heavy" then
        local level = opts.fargs[2]
        if level == "low" or level == "medium" or level == "high" then
            vim.g.qllm_queue_heaviness = level
            vim.notify("Queue heaviness set to: " .. level, vim.log.levels.INFO, { title = "qLLM" })
        else
            vim.notify("Usage: :Que heavy [low|medium|high]. Current: " .. (vim.g.qllm_queue_heaviness or "low"), vim.log.levels.WARN, { title = "qLLM" })
        end
        return
    end

    -- Handle `wiki_index` as a special case
    if command == "wiki_index" then
        local KB = require("qllm.providers.knowledge_base")
        KB.wiki_index()
        return
    end

    -- Handle `wiki_lint` as a special case
    if command == "wiki_lint" then
        local KB = require("qllm.providers.knowledge_base")
        KB.wiki_lint()
        return
    end

    -- Handle `wiki_save` as a special case
    if command == "wiki_save" then
        local KB = require("qllm.providers.knowledge_base")
        local filename = opts.fargs[2]
        if not filename then
            vim.notify("Usage: :Que wiki_save <filename.md>", vim.log.levels.ERROR)
            return
        end
        KB.wiki_save(filename, text_selection)
        return
    end

    -- Handle `init` as a special case
    if command == "init" then
        local ProjectContext = require("qllm.project_context")
        ProjectContext.init_project()
        return
    end

    -- Handle `json` as a special case
    if command == "json" then
        local filepath = opts.fargs[2]
        if not filepath then
            local cur_file = vim.api.nvim_buf_get_name(0)
            if cur_file:match("%.json$") then
                filepath = cur_file
            else
                vim.notify("Usage: :Que json <filepath> [initial.path]", vim.log.levels.ERROR, { title = "qLLM" })
                return
            end
        end

        local initial_path = {}
        local initial_path_str = opts.fargs[3]
        if initial_path_str then
            for part in string.gmatch(initial_path_str, "[^.]+") do
                local num = tonumber(part)
                if num then
                    table.insert(initial_path, num)
                else
                    table.insert(initial_path, part)
                end
            end
        end

        local JsonExplore = require("qllm.json_explore")
        JsonExplore.start_explorer(filepath, initial_path, bufnr)
        return
    end

    -- Handle `load` as a special case
    if command == "load" then
        local loaded_files = {}
        for i = 2, #opts.fargs do
            local filepath = opts.fargs[i]
            local expanded_path = vim.fn.expand(filepath)
            if vim.fn.filereadable(expanded_path) == 1 then
                local content = table.concat(vim.fn.readfile(expanded_path), "\n")

                -- Check if this is a qLLM queue JSON export
                local is_queue_json = false
                if filepath:match("%.json$") then
                    local ok, decoded = pcall(vim.fn.json_decode, content)
                    if ok and type(decoded) == "table" and #decoded > 0 and decoded[1].role and decoded[1].content then
                        is_queue_json = true
                        local current_queue = Queue.get_raw_queue(bufnr)
                        local merge = current_queue ~= nil and #current_queue > 0
                        local success, err = Queue.copy_queue(decoded, bufnr, { merge = merge })
                        if success then
                            vim.notify(string.format("%s `%s` queue into current chat.", merge and "Merged" or "Loaded", filepath), vim.log.levels.INFO, { title = "qLLM" })
                            table.insert(loaded_files, filepath)
                        else
                            vim.notify("load queue error: " .. tostring(err), vim.log.levels.ERROR, { title = "qLLM" })
                        end
                    end
                end

                if not is_queue_json then
                    local user_msg = string.format("Here is the contents of the file `%s`:\n\n```%s\n%s\n```",
                        vim.fn.fnamemodify(expanded_path, ":t"),
                        vim.fn.fnamemodify(expanded_path, ":e"),
                        content
                    )
                    Queue.add_message(bufnr, "user", user_msg)
                    Queue.add_message(bufnr, "assistant", string.format("Understood. I have loaded the contents of `%s` as context.", vim.fn.fnamemodify(expanded_path, ":t")))
                    table.insert(loaded_files, filepath)
                end
            else
                vim.notify("load: File not found or unreadable: " .. filepath, vim.log.levels.ERROR, { title = "qLLM" })
            end
        end

        if #loaded_files == 0 and text_selection and text_selection ~= "" then
            local user_msg = "Here is the loaded text selection:\n\n" .. text_selection
            Queue.add_message(bufnr, "user", user_msg)
            Queue.add_message(bufnr, "assistant", "Understood. I have loaded the selected text as context.")
            vim.notify("Loaded visual selection into chat queue.", vim.log.levels.INFO, { title = "qLLM" })
            return
        end

        if #loaded_files > 0 then
            -- Notifications are handled per-file above
        else
            vim.notify("Usage: :Que load <filepath> or select text visually.", vim.log.levels.WARN, { title = "qLLM" })
        end
        return
    end

    -- Handle `export` as a special case
    if command == "export" then
        local raw_queue = Queue.get_raw_queue(bufnr)
        if not raw_queue or #raw_queue == 0 then
            vim.notify("export: No chat queue to export for this buffer.", vim.log.levels.WARN, { title = "qLLM" })
            return
        end

        -- Generate default name: qllm_<project_folder>_<date>.json
        local folder_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
        local date = os.date("%Y-%m-%d")
        local default_name = string.format("qllm_%s_%s.json", folder_name, date)

        local filepath = opts.fargs[2]
        local target_path
        if not filepath then
            target_path = vim.fn.getcwd() .. "/" .. default_name
        else
            local expanded = vim.fn.expand(filepath)
            if vim.fn.isdirectory(expanded) == 1 then
                target_path = expanded:gsub("/$", "") .. "/" .. default_name
            else
                target_path = expanded
            end
        end

        local success, encoded = pcall(vim.fn.json_encode, raw_queue)
        if not success or not encoded then
            vim.notify("export: Failed to encode chat queue to JSON.", vim.log.levels.ERROR, { title = "qLLM" })
            return
        end

        local f = io.open(target_path, "w")
        if f then
            f:write(encoded)
            f:close()
            vim.notify(string.format("Exported chat queue to: %s", target_path), vim.log.levels.INFO, { title = "qLLM" })
        else
            vim.notify("export: Failed to write file: " .. target_path, vim.log.levels.ERROR, { title = "qLLM" })
        end
        return
    end

    -- 2. RESOLVE PROVIDER & PRESETS
    local overrides = nil
    -- Command-to-Provider Mapping
    local provider_map = {
        Gemini = "gemini",
        Claude = "anthropic",
        Openai = "openai",
        Ollama = "ollama",
        Groq = "groq",
    }

    -- Detect Presets
    local preset_idx = opts.name:match("Pre(%d)$")
    if preset_idx then
        overrides = { preset = tonumber(preset_idx) }
    elseif provider_map[opts.name] then
        overrides = { 
            provider = provider_map[opts.name],
            -- By default, if they use a provider command for search, use that provider's native search
            search_provider = provider_map[opts.name]
        }
        -- Special case for Ollama + Search -> Local Grounding
        if command == "search" and opts.name == "Ollama" then
            overrides.search_provider = "local_grounding"
        end
    end

    -- 3. EXECUTION PIPELINE
    local function execute_with_fresh_context()
        if command == "tree" then
            local query = opts.fargs[2] or ""
            if query == "" then
                vim.notify("Usage: :Que tree <function_or_variable>", vim.log.levels.ERROR)
                return
            end
            local ProjectContext = require("qllm.project_context")
            ProjectContext.show_tree(query, bufnr)
            return
        end

        if command == "deadcode" then
            local ProjectContext = require("qllm.project_context")
            ProjectContext.show_dead_code(bufnr)
            return
        end

        local ContextEngine = require("qllm.context_engine")

        -- Universal Context Resolution (Files, Selection, Project Map)
        local resolved_command, resolved_command_args, resolved_text_selection, resolved_overrides = 
            ContextEngine.handle_context_command(command, opts.args, current_bufnr, text_selection, overrides)

        if resolved_command == nil then return end -- Handled internally (e.g. scan popup)

        command = resolved_command
        command_args = resolved_command_args
        text_selection = resolved_text_selection
        overrides = resolved_overrides

        -- Fetch Options for the Final Resolved Command
        local cmd_opts = CommandsList.get_cmd_opts(command, overrides)

        if command == nil or command == "" or cmd_opts == nil then
            vim.notify("No valid command or options found for: " .. (command or "unknown"), vim.log.levels.ERROR, {
                title = "qLLM",
            })
            return
        end

        -- Check if command requires context (selection or files)
        if not cmd_opts.allow_empty_text_selection and (text_selection == nil or text_selection == "") then
            vim.notify("This command (" .. command .. ") requires a visual selection or file context.", vim.log.levels.WARN, {
                title = "qLLM",
            })
            return
        end

        Commands.run_cmd(command, command_args, text_selection, bufnr, cmd_opts, overrides)
    end

    -- If command needs project map context, ensure it is fresh before proceeding.
    local needs_project_map = command == "scan" or command == "tree" or command == "deadcode"

    if needs_project_map then
        local ProjectContext = require("qllm.project_context")
        ProjectContext.ensure_fresh_context(execute_with_fresh_context)
    else
        execute_with_fresh_context()
    end
end

function qllmModule.recall(arg)
    local fargs = { "recall" }
    if arg then table.insert(fargs, tostring(arg)) end
    return qllmModule.run_cmd({ fargs = fargs, name = "Que" })
end

function qllmModule.undo()
    return qllmModule.run_cmd({ fargs = { "undo" }, name = "Que" })
end

function qllmModule.clear()
    return qllmModule.run_cmd({ fargs = { "clear" }, name = "Que" })
end

function qllmModule.adjust_popup_size(delta_w, delta_h)
    local Window = require("qllm.window")
    Window.update_global_layout(delta_w, delta_h)
    return Ui.refresh_active_popup()
end

function qllmModule.adjust_popup_position(delta_col, delta_row)
    local Window = require("qllm.window")
    Window.move_global_layout(delta_col, delta_row)
    return Ui.refresh_active_popup()
end

return qllmModule

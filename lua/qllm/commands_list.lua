local Utils = require("qllm.utils")
local Ui = require("qllm.ui")

local CommandsList = {}
local cmd_default = {
    temperature = 0.2,
    number_of_choices = 1,
    system_message_template = "",
    user_message_template = "",
    callback_type = "text_popup",
    allow_empty_text_selection = true,
    extra_params = {}, -- extra parameters sent to the API
}

CommandsList.CallbackTypes = {
    ["text_popup"] = function(lines, bufnr, start_row, start_col, end_row, end_col)
        local popup_filetype = vim.g.qllm_text_popup_filetype
        Ui.popup(lines, popup_filetype, bufnr, start_row, start_col, end_row, end_col)
    end,
    ["replace_lines"] = function(lines, bufnr, start_row, start_col, end_row, end_col)
        -- Structural extraction via Tree-sitter
        lines = Utils.trim_to_code_block(lines)
        -- Cleanup of broken fences (if TS failed or was partial)
        lines = Utils.strip_broken_fences(lines)

        lines = Utils.remove_trailing_whitespace(lines)
        Utils.fix_indentation(bufnr, start_row, end_row, lines)
        if vim.api.nvim_buf_is_valid(bufnr) == true then
            Utils.replace_lines(lines, bufnr, start_row, start_col, end_row, end_col)
        else
            -- if the buffer is not valid, open a popup. This can happen when the user closes the previous popup window before the request is finished.
            Ui.popup(lines, Utils.get_filetype(), bufnr, start_row, start_col, end_row, end_col)
        end
    end,
    ["custom"] = nil,
}

---Checks if a given string matches a registered command name.
---@param cmd string The command name to check.
---@return boolean True if it's a valid command, false otherwise.
function CommandsList.is_valid_cmd(cmd)
    if vim.g.qllm_commands_defaults and type(vim.g.qllm_commands_defaults[cmd]) == "table" then
        return true
    end
    if vim.g.qllm_commands and type(vim.g.qllm_commands[cmd]) == "table" then
        return true
    end
    return false
end

function CommandsList.get_cmd_opts(cmd, overrides)
    -- Start with hardcoded defaults for all commands
    local opts = vim.deepcopy(cmd_default)

    local preset_suffix = (overrides and overrides.preset) and tostring(overrides.preset) or ""

    -- Resolve Provider Name
    local provider_name = (overrides and overrides.provider) 
        or vim.g["qllm_api_provider" .. preset_suffix]
        or vim.g.qllm_api_provider 
        or "openai"
    provider_name = string.lower(provider_name)

    -- Merge provider defaults (Global fallback)
    local global_provider_defaults = vim.g.qllm_provider_defaults or {}
    if global_provider_defaults[provider_name] then
        opts = vim.tbl_extend("force", opts, global_provider_defaults[provider_name])
    end

    -- Merge preset-specific provider defaults (Higher precedence)
    if preset_suffix ~= "" then
        local preset_provider_defaults = vim.g["qllm_provider_defaults" .. preset_suffix] or {}
        if preset_provider_defaults[provider_name] then
            opts = vim.tbl_extend("force", opts, preset_provider_defaults[provider_name])
        end
    end

    -- 1. Merge Base Unified Defaults (The global templates and settings)
    local base_defaults = vim.g.qllm_commands_defaults
    if base_defaults and type(base_defaults) == "table" then
        local config_table = vim.deepcopy(base_defaults)
        
        -- Apply Flat Keys (Base Global)
        local flat_keys = {}
        for k, v in pairs(config_table) do
            if type(v) ~= "table" then flat_keys[k] = v end
        end
        opts = vim.tbl_extend("force", opts, flat_keys)

        -- Apply Base Command Overrides (The templates like 'query', 'explain', etc.)
        local cmd_overrides = config_table[cmd]
        if cmd_overrides and type(cmd_overrides) == "table" then
            opts = vim.tbl_extend("force", opts, cmd_overrides)
        end
    end

    -- 2. Merge Preset-Specific Unified Defaults (Overrides for this specific preset)
    if preset_suffix ~= "" then
        local preset_defaults = vim.g["qllm_commands_defaults" .. preset_suffix]
        if preset_defaults and type(preset_defaults) == "table" then
            local config_table = vim.deepcopy(preset_defaults)

            -- Apply Flat Keys (Preset Global)
            local flat_keys = {}
            for k, v in pairs(config_table) do
                if type(v) ~= "table" then flat_keys[k] = v end
            end

            -- If an explicit provider was requested via command (:Gemini), strip the preset's global model
            if (overrides and (overrides.provider or overrides.search_provider)) then
                 flat_keys.model = nil
                 flat_keys.search_model = nil
            end

            opts = vim.tbl_extend("force", opts, flat_keys)

            -- Apply Preset Command Overrides
            local cmd_overrides = config_table[cmd]
            if cmd_overrides and type(cmd_overrides) == "table" then
                -- Handle Per-Command Provider Overrides in the preset
                if cmd_overrides.provider and not (overrides and overrides.provider) then
                    provider_name = string.lower(cmd_overrides.provider)
                    local new_provider_defaults = (vim.g.qllm_provider_defaults or {})[provider_name] or {}
                    opts = vim.tbl_extend("force", opts, new_provider_defaults)
                end
                opts = vim.tbl_extend("force", opts, cmd_overrides)
            end
        end
    end

    -- Add the resolved provider name to the opts so the caller knows which one to use
    opts.provider = provider_name

    -- Merge user-defined commands (extra flexibility)
    local user_cmd_opts = (vim.g.qllm_commands or {})[cmd]
    if user_cmd_opts ~= nil then
        opts = vim.tbl_extend("force", opts, user_cmd_opts)
    end

    -- Handle decoupled search model logic
    if opts.is_search_command then
        local search_provider = (overrides and overrides.search_provider) 
            or vim.g["qllm_search_provider" .. preset_suffix]
            or vim.g.qllm_search_provider
            or "gemini"

        -- Get default search model settings for this provider
        local search_model_defaults = vim.g.qllm_search_model_defaults or {}
        local provider_search_settings = search_model_defaults[search_provider] or {}
        local default_search_model = provider_search_settings.model

        -- Safely fetch generic global search model
        local global_search_model = vim.g["qllm_search_model" .. preset_suffix] or vim.g.qllm_search_model
        
        -- If an explicit provider was requested (e.g., :Gemini), strip the generic global search model
        -- because we must use the provider's specific search model we just loaded.
        if overrides and (overrides.provider or overrides.search_provider) then
             global_search_model = nil
             opts.search_model = nil
        end

        -- Resolution order:
        -- 1. Global user setting (`global_search_model`)
        -- 2. Command-specific `search_model` override
        -- 3. Provider specific default for search (`default_search_model`)
        opts.model = global_search_model or opts.search_model or default_search_model
    end

    -- Model is configured?
    if opts.model == nil or opts.model == "" then
        vim.notify(
            "qLLM.vim: Model not configured for command '"
                .. cmd
                .. "'. Please set it in vim.g.qllm_commands or vim.g.qllm_commands_defaults",
            vim.log.levels.ERROR
        )
        return nil
    end

    -- Callback function
    if opts.callback_type == "custom" then
        if type(opts.callback) ~= "function" then
            vim.notify("Custom callback for command '" .. cmd .. "' is not a function.", vim.log.levels.ERROR)
            return nil
        end
    else
        opts.callback = CommandsList.CallbackTypes[opts.callback_type]
    end
    
    return opts
end

---Context-Aware Completion for the command line.
---@param ArgLead string The leading portion of the argument currently being completed.
---@param CmdLine string The entire command line.
---@param CursorPos number The cursor position in the command line.
---@return table A list of completion suggestions.
function CommandsList.complete(ArgLead, CmdLine, CursorPos)
    local parts = {}
    for word in CmdLine:gmatch("%S+") do
        table.insert(parts, word)
    end

    local ends_with_space = CmdLine:match("%s$") ~= nil

    -- If we are still typing the first argument (sub-command)
    if #parts == 1 or (#parts == 2 and not ends_with_space) then
        local cmd = { "heavy", "copy", "list", "listmodels", "undo", "wiki_index", "wiki_lint", "wiki_save", "init", "tree", "deadcode", "recall", "recallq", "clear", "help", "load", "export", "json" }
        for k, v in pairs(vim.g.qllm_commands_defaults or {}) do
            if type(v) == "table" then
                table.insert(cmd, k)
            end
        end
        for k in pairs(vim.g.qllm_commands or {}) do
            table.insert(cmd, k)
        end

        local res = {}
        for _, c in ipairs(cmd) do
            if c:find("^" .. vim.pesc(ArgLead)) then
                table.insert(res, c)
            end
        end
        return res
    end

    local sub_cmd = parts[2]

    -- Provide options for the heaviness command
    if sub_cmd == "heavy" then
        local res = {}
        for _, level in ipairs({ "low", "medium", "high" }) do
            if level:find("^" .. vim.pesc(ArgLead)) then
                table.insert(res, level)
            end
        end
        return res
    end

    -- If the sub-command deals with files, provide native file completion
    if sub_cmd == "files" or sub_cmd == "scan" or sub_cmd == "wiki_save" or sub_cmd == "load" or sub_cmd == "export" or sub_cmd == "json" then
        local clean_lead = ArgLead
        local quote = ""
        -- Handle leading brackets to allow users to group files
        if ArgLead:match("^%[") then
            quote = "["
            clean_lead = ArgLead:sub(2)
        end

        local files = vim.fn.getcompletion(clean_lead, "file")
        if quote ~= "" then
            local res = {}
            for _, f in ipairs(files) do
                table.insert(res, quote .. f)
            end
            return res
        else
            return files
        end
    end

    return {}
end

return CommandsList

local M = {}
local Api = require("qllm.api")

---Gets the project root directory (closest directory with .git or current working dir).
---@return string
function M.get_project_root()
    local git_dir = vim.fn.finddir(".git", ".;")
    if git_dir ~= "" then
        -- Resolve to an absolute path before taking the parent. Applying ":h" first
        -- yields "." when the search starts in the project root itself, which then
        -- survives ":p" and leaves every file:// link and stored path relative.
        local absolute = vim.fn.fnamemodify(git_dir, ":p"):gsub("/$", "")
        return vim.fn.fnamemodify(absolute, ":h") .. "/"
    end
    return vim.fn.getcwd() .. "/"
end

---Generates a lightweight skeleton hash and file count.
---@param root string
---@return string hash
---@return number count
function M.generate_project_skeleton(root)
    -- Scan files up to 3 levels deep, ignoring .git
    local files = vim.fn.globpath(root, "**", true, true)
    local structure = {}
    local count = 0
    for _, file in ipairs(files) do
        local is_meta = file:find("qLLM%.md$") or file:find("qLLM_map%.json$")
        if not file:find("%.git/") and not is_meta then
            local stats = vim.loop.fs_stat(file)
            if stats then
                -- Skeleton: Names and timestamps
                table.insert(structure, string.format("%s:%d", file, stats.mtime.sec))
                count = count + 1
            end
        end
    end
    table.sort(structure)
    return vim.fn.sha256(table.concat(structure, "\n")), count
end

local CodeExtraction = require("qllm.code_extraction")

local is_indexing = false
local last_progress_time = 0

---Orchestrates the project initialization (:Que init).
---@param callback function? Optional callback for when init is complete.
function M.init_project(callback)
    local kb_opts = vim.g.qllm_kb_opts or {}
    local now = os.time()
    if is_indexing and (now - last_progress_time < 300) then
        vim.notify("Project initialization already in progress.", vim.log.levels.WARN)
        return
    end

    local root = M.get_project_root()
    is_indexing = true
    last_progress_time = now
    local readme_path = root .. "README.md"
    local readme_content = ""
    if vim.fn.filereadable(readme_path) == 1 then
        readme_content = table.concat(vim.fn.readfile(readme_path), "\n")
    end

    -- Get directory listing
    local files = vim.fn.globpath(root, "*", true, true)
    local relative_files = {}
    for _, file in ipairs(files) do
        table.insert(relative_files, vim.fn.fnamemodify(file, ":."))
    end
    local dir_listing = table.concat(relative_files, "\n")

    local prompt = string.format([[
You are the Project Architect. Analyze the following project structure and README.
Generate a high-level architectural map for this project.
Include:
1. Architecture Summary: What is this project?
2. Core Hubs: Key files/directories and their functional roles.

PROJECT STRUCTURE:
%s

README CONTENT:
%s

IMPORTANT: Output your response in Markdown format.
]], dir_listing, readme_content)

    local provider_name = kb_opts.context_provider or kb_opts.project_provider or vim.g.qllm_api_provider

    local Providers = require("qllm.providers")
    local provider = Providers.get_provider({ provider = provider_name })

    -- If model is nil, fetch the provider's default
    local model_name = kb_opts.context_model or kb_opts.project_model
    if not model_name then
        local CommandsList = require("qllm.commands_list")
        local provider_opts = CommandsList.get_cmd_opts("query", { provider = provider_name })
        model_name = provider_opts.model
    end

    -- Build the AST call graph locally first so it is available even if LLM fails/is offline
    vim.notify("Initializing Project Context... Mapping codebase structure.", vim.log.levels.INFO)
    CodeExtraction.build_and_save_call_graph(root)

    provider.make_call({
        model = model_name,
        messages = {{role = "user", content = prompt}},
        stream = false
    }, prompt, function(lines)
        local response = table.concat(lines, "\n")
        local hash, count = M.generate_project_skeleton(root)
        
        -- Clean any LLM-generated metadata blocks to prevent duplication
        local cleaned_response = response:gsub("<!%-%- METADATA: .- %-%->\n*", "")

        -- Programmatically prepend the actual metadata block
        local metadata_comment = string.format('<!-- METADATA: {"hash": "%s", "count": %d, "schema": %d} -->\n',
            hash, count, CodeExtraction.MAP_SCHEMA)
        local final_content = metadata_comment .. cleaned_response
        
        local output_path = root .. "qLLM.md"
        local f = io.open(output_path, "w")
        if f then
            f:write(final_content)
            f:close()
            vim.notify("Project Context architectural map initialized: " .. output_path, vim.log.levels.INFO)
        else
            vim.notify("Error: Could not write to " .. output_path, vim.log.levels.ERROR)
        end
        is_indexing = false
        if callback then callback() end
    end, -1)
end

---Returns the content of qLLM.md if it exists.
function M.get_active_context()
    local root = M.get_project_root()
    local path = root .. "qLLM.md"
    if vim.fn.filereadable(path) == 1 then
        return table.concat(vim.fn.readfile(path), "\n")
    end
    return nil
end

---Analyzes freshness and returns a status and recommendation.
---@return string status "missing" | "fresh" | "stale" | "significant_change"
function M.get_freshness_status()
    local context = M.get_active_context()
    if not context then return "missing" end

    local metadata_json = context:match("<!%-%- METADATA: (.-) %-%->")
    if not metadata_json then return "stale" end

    local ok, decoded = pcall(vim.json.decode, metadata_json)
    if not ok or not decoded.hash then return "stale" end

    local root = M.get_project_root()
    local current_hash, current_count = M.generate_project_skeleton(root)

    -- A map built by an older version indexes fewer kinds of definition. Report it as
    -- stale so the local graph is rebuilt; that path costs no LLM call.
    if (decoded.schema or 1) < CodeExtraction.MAP_SCHEMA then
        return "stale"
    end

    if current_hash == decoded.hash then
        return "fresh"
    end

    -- Check for "significant" change (e.g. 10+ files difference or count change)
    local diff = math.abs(current_count - (decoded.count or 0))
    if diff >= 10 then
        return "significant_change"
    end

    return "stale"
end

---Ensures project context is fresh, running init if needed based on auto_init setting.
---@param callback function The function to call once context is ready/checked.
function M.ensure_fresh_context(callback)
    local kb_opts = vim.g.qllm_kb_opts or {}
    local auto_init = kb_opts.auto_init ~= false
    local auto_check = kb_opts.auto_check_freshness ~= false

    if not auto_check then
        callback()
        return
    end

    local status = M.get_freshness_status()

    if status == "missing" then
        -- Truly Optional: If the map doesn't exist, we don't nag.
        -- We only start managing it once the user has manually run :Que init.
        callback()
    elseif status == "significant_change" then
        if auto_init then
            vim.notify("[qLLM] Syncing project map (significant changes detected)...", vim.log.levels.INFO)
            M.init_project(callback)
        else
            vim.notify("[qLLM] Project map is stale. Run :Que init to update.", vim.log.levels.WARN)
            callback()
        end
    else
        if status == "stale" then
            -- Rebuild local call graph map to keep line numbers accurate
            local root = M.get_project_root()
            local current_hash, current_count = M.generate_project_skeleton(root)
            local context = M.get_active_context()
            if context then
                local new_metadata = string.format('<!-- METADATA: {"hash": "%s", "count": %d, "schema": %d} -->',
                    current_hash, current_count, CodeExtraction.MAP_SCHEMA)
                local updated_context = context:gsub("<!%-%- METADATA: .- %-%->", new_metadata)
                local output_path = root .. "qLLM.md"
                local f = io.open(output_path, "w")
                if f then
                    f:write(updated_context)
                    f:close()
                end
            end
            CodeExtraction.build_and_save_call_graph(root)
        end
        callback()
    end
end

function M.check_freshness()
    local status = M.get_freshness_status()
    if status == "significant_change" then
        vim.notify("[qLLM] Project map is stale. Run :Que init to update.", vim.log.levels.WARN)
    end
end

---Builds the project AST call graph and saves it as qLLM_map.json.
---Delegates to CodeExtraction for implementation details.
---@param root string
function M.build_and_save_call_graph(root)
    CodeExtraction.build_and_save_call_graph(root)
end

---Displays the call graph or variable reference tree structure in a popup.
---@param query string The function or variable name to query.
---@param bufnr number The buffer number to associate with the popup.
function M.show_tree(query, bufnr)
    local root = M.get_project_root()
    local output_lines, err = CodeExtraction.query_call_tree(query, root)
    if err then
        vim.notify(err, vim.log.levels.WARN)
        return
    end

    -- Tag buffer metadata to identify it as a tree popup
    vim.b[bufnr].qllm_metadata = {
        command = "tree"
    }

    -- Render popup UI
    local Ui = require("qllm.ui")
    Ui.popup(output_lines, "markdown", bufnr)

    -- Save to queue based on heaviness
    local heaviness = vim.g.qllm_queue_heaviness or "low"
    if heaviness == "medium" or heaviness == "high" then
        local Queue = require("qllm.queue")
        Queue.add_message(bufnr, "user", "tree " .. query)
        Queue.add_message(bufnr, "assistant", table.concat(output_lines, "\n"), nil, "tree")
    end
end

---Performs dead code analysis and displays it in a popup.
function M.show_dead_code(bufnr)
    local root = M.get_project_root()
    local output_lines, err = CodeExtraction.analyze_dead_code(root)
    if err then
        vim.notify(err, vim.log.levels.WARN)
        return
    end

    -- Tag buffer metadata to identify it as a deadcode popup
    vim.b[bufnr].qllm_metadata = {
        command = "deadcode"
    }

    local Ui = require("qllm.ui")
    Ui.popup(output_lines, "markdown", bufnr)

    local heaviness = vim.g.qllm_queue_heaviness or "low"
    if heaviness == "medium" or heaviness == "high" then
        local Queue = require("qllm.queue")
        Queue.add_message(bufnr, "user", "deadcode")
        Queue.add_message(bufnr, "assistant", table.concat(output_lines, "\n"), nil, "deadcode")
    end
end

return M

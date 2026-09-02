vim.g.qllm_chat_completions_url = "https://api.openai.com/v1/chat/completions"

-- Read old config if it exists
if vim.g.qllm_openai_api_provider and #vim.g.qllm_openai_api_provider > 0 then
    vim.g.qllm_api_provider = vim.g.qllm_openai_api_provider
end

-- Alternative provider
vim.g.qllm_api_provider = vim.g.qllm_api_provider or "openai"

-- Default Models for Providers
vim.g.qllm_provider_defaults = vim.tbl_extend("force", {
    openai = {
        model = "gpt-5.4-nano",
        output_tokens = 8192,
        reasoning = { effort = "medium" },
    },
    ollama = {
        model = "qwen3:8b",
    },
    anthropic = {
        model = "claude-haiku-4-5-20251001",
        output_tokens = 4096,
    },
    gemini = {
        model = "gemini-2.5-flash",
    },
    groq = {
        model = "qwen/qwen3-32b",
    },
    local_grounding = {
        model = "qwen3:8b",
    },
}, vim.g.qllm_provider_defaults or {})

-- Default Search Models per Provider
vim.g.qllm_search_model_defaults = vim.tbl_extend("force", {
    gemini = { model = "gemini-2.5-flash" },
    anthropic = { model = "claude-sonnet-4-6" },
    openai = { model = "gpt-5.5" },
    local_grounding = { model = "qwen3:8b" },
}, vim.g.qllm_search_model_defaults or {})

-- Presets: Dynamically detect defined presets (up to Pre9)
local function is_preset_defined(i)
    if i == 1 then return true end -- Pre1 is always available as default fallback
    return vim.g["qllm_api_provider" .. i] ~= nil
        or vim.g["qllm_search_provider" .. i] ~= nil
        or vim.g["qllm_commands_defaults" .. i] ~= nil
        or vim.g["qllm_provider_defaults" .. i] ~= nil
        or vim.g["qllm_search_model" .. i] ~= nil
end

vim.schedule(function()
    for i = 1, 9 do
        if is_preset_defined(i) then
            local search_key = "qllm_search_provider" .. i
            vim.g[search_key] = vim.g[search_key] or "gemini"
        end
    end
end)

-- Clears visual selection after completion
vim.g.qllm_clear_visual_selection = true

-- Print the model name in a notification before each request
if vim.g.qllm_print_model == nil then
    vim.g.qllm_print_model = true
end

-- Ensure user commands table exists
vim.g.qllm_commands = vim.g.qllm_commands or {}

vim.g.qllm_hooks = {
    request_started = nil,
    request_finished = nil,
}

-- Style to use for the popup border (e.g. "rounded", "single", "double", "solid", "shadow")
vim.g.qllm_popup_style = "rounded"

-- Passes native Neovim window options (vim.wo) to the popup window.
-- For example: { wrap = true, spell = false, cursorline = true, foldenable = false }
vim.g.qllm_popup_window_options = {
    wrap = true,
    linebreak = true,
}

-- Set the filetype of a text popup is markdown
vim.g.qllm_text_popup_filetype = "markdown"

-- Set the type of ui to use for the popup, options are "popup", "vertical" or "horizontal"
vim.g.qllm_popup_type = "popup"

-- Whether to automatically expand the popup height as content streams in
if vim.g.qllm_auto_expand == nil then
    vim.g.qllm_auto_expand = true
end

-- Whether to show the thinking process in the UI (if supported by the provider)
vim.g.qllm_show_thinking = true

-- Set the layout of the popup window (position can be "50%" or a table, e.g. { row = "10%", col = "90%" })
vim.g.qllm_popup_layout = {
  relative = "editor",
  position = "50%",
  size = {
    width = "100%",
    height = "80%"
  }
}

-- Set the height of the horizontal popup
vim.g.qllm_horizontal_popup_size = "40%"

-- Set the width of the vertical popup
vim.g.qllm_vertical_popup_size = "50%"

-- Queue (short-term memory) configuration
vim.g.qllm_queue_heaviness = vim.g.qllm_queue_heaviness or vim.g.qllm_history_heaviness or "low"

vim.g.qllm_queue_opts = vim.tbl_extend("force", {
    summarize_style = "messages",
    -- "none"      -> no summarization, sliding window only
    -- "messages"  -> summarize when message count exceeds max_messages
    -- "tokens"    -> summarize when token count exceeds max_tokens
    max_messages = 60,
    max_tokens = 24000,
    summarize_percent = 50,
    time_based_expiry = false,
    timeout = 1800, -- 30 minutes
}, vim.g.qllm_queue_opts or vim.g.qllm_history_opts or {})

-- JSON explorer newline formatting (converts \n strings to real newlines)
if vim.g.qllm_json_newline == nil then
    vim.g.qllm_json_newline = true
end

-- Knowledge Base Namespace (Wiki & Project Context)
local kb_defaults = {
    -- 1. INFRASTRUCTURE
    db_path = vim.g.qllm_kb_db_path or (vim.fn.stdpath("data") .. "/qllm_kb.db"),
    sqlite_vec_path = vim.g.qllm_kb_sqlite_vec_path or "",

    -- 2. WIKI
    wiki_folder = vim.g.qllm_kb_folder or (vim.fn.getcwd() .. "/.qllm_kb"),
    style = vim.g.qllm_kb_style or "simple", -- simple | complex

    -- 3. EMBEDDINGS
    provider = vim.g.qllm_kb_provider or "ollama",
    model = vim.g.qllm_kb_embedding_model or "nomic-embed-text",
    dimension = vim.g.qllm_kb_embedding_dimension or 768,

    -- 4. CONTEXT GENERATION
    context_provider = (vim.g.qllm_project_defaults and vim.g.qllm_project_defaults.provider) or nil,
    context_model = (vim.g.qllm_project_defaults and vim.g.qllm_project_defaults.model) or nil, -- nil means use provider default
    auto_init = true,
    auto_check_freshness = true,

    -- 5. ORCHESTRATION
    scan_context = vim.g.qllm_scan_context or 3,
    scan_index_variables = true, -- Index module-level variables in the project map
    scan_use_ctags = true,       -- Use Universal Ctags (if installed) to cover languages
                                 -- with no Tree-sitter parser available

    -- Structural scan (searches qLLM_map.json and ranks by call-graph centrality)
    scan_mode = "hybrid",        -- "hybrid" | "structural" | "text"
    scan_max_results = 20,       -- Ranked definitions shown in the popup
    scan_max_defs = 5,           -- Definition bodies sent to the LLM
    scan_centrality_weight = 1.0, -- How strongly centrality boosts a name match
    scan_test_penalty = 0.5,     -- Score multiplier for test/mock/fixture paths
    scan_test_patterns = nil,    -- Override the default test path segments
    scan_text_budget = 4000,     -- Char cap on text matches when they supplement
                                 -- structural results (a -t search stays unbounded)
    sync_strategy = "auto",      -- "auto" (background) | "manual"
    neighborhood_size = 5,       -- Number of related files to weave
}

-- Apply backward compatibility for Project Defaults if they exist
if vim.g.qllm_project_defaults then
    if vim.g.qllm_project_defaults.auto_init ~= nil then
        kb_defaults.auto_init = vim.g.qllm_project_defaults.auto_init
    end
    if vim.g.qllm_project_defaults.auto_check_freshness ~= nil then
        kb_defaults.auto_check_freshness = vim.g.qllm_project_defaults.auto_check_freshness
    end
end

vim.g.qllm_kb_opts = vim.tbl_extend("force", kb_defaults, vim.g.qllm_kb_opts or {})

-- Model Intelligence Strategies (based on provider capabilities)
vim.g.qllm_provider_capabilities = {
    ["openai"] = { strategy = "god_prompt" },
    ["anthropic"] = { strategy = "god_prompt" },
    ["gemini"] = { strategy = "god_prompt" },
    ["ollama"] = { strategy = "lazy" },
    ["groq"] = { strategy = "lazy" },
}

-- Default Command Templates
vim.g.qllm_commands_defaults = {
    ["wiki"] = {
        provider = "knowledge_base",
        callback_type = "text_popup",
        user_message_template = "{{command_args}}",
        allow_empty_text_selection = true,
    },
    ["files"] = {
        user_message_template = "{{text_selection}}\n\n{{command_args}}",
        default_prompt = "Analyze the provided files and provide a summary of their purpose and contents.",
        allow_empty_text_selection = true,
    },
    ["scan"] = {
        user_message_template = "{{text_selection}}\n\n{{command_args}}",
        default_prompt = "Analyze the provided chunks and explain thier purpose and contents",
        allow_empty_text_selection = true,
    },
    ["complete"] = {
        user_message_template =
        "I have the following {{language}} code: \n\n{{text_selection}}\n\nComplete the rest. Use best practices and descriptive commenting. {{language_instructions}} Only return the code snippet and nothing else.",
        language_instructions = {
            ["*"] = "Use modern {{language}} syntax and features.",
        },
        callback_type = "replace_lines",
        allow_empty_text_selection = false,
        thinking = false,
    },
    ["edit"] = {
        user_message_template =
        "I have the following {{language}} code: \n{{filetype}}\n\n{{text_selection}}\n\n{{command_args}}.\n{{language_instructions}} Only return the code snippet and nothing else.",
        language_instructions = {
            ["*"] = "Use modern {{language}} syntax and features.",
        },
        callback_type = "replace_lines",
        allow_empty_text_selection = false,
    },
    ["explain"] = {
        user_message_template = "{{command_args}}\n{{text_selection}}",
        default_prompt = "Explain the provided {{language}} code as you were explaining to another developer:",
        callback_type = "text_popup",
    },
    ["debug"] = {
        user_message_template =
        "Analyze the following {{language}} code for bugs: ```{{filetype}}\n{{text_selection}}```",
        callback_type = "text_popup",
    },
    ["doc"] = {
        user_message_template =
        "I have the following {{language}} code:\n{{filetype}}\n\n{{text_selection}}\n\nWrite comprehensive documentation using best practices for the given language. Attention paid to documenting parameters, return types, any exceptions or errors.\n{{language_instructions}} Only return the code snippet and nothing else.",
        language_instructions = {
            ["*"] = "Use the standard documentation style (e.g. Docstrings, JSDoc, Doxygen) typical for {{language}}.",
        },
        callback_type = "replace_lines",
        allow_empty_text_selection = false,
    },
    ["opt"] = {
        user_message_template =
        "I have the following {{language}} code: \n{{filetype}}\n\n{{text_selection}}\n\nOptimize this code. {{language_instructions}} Only return the code snippet and nothing else.",
        language_instructions = {
            ["*"] = "Use modern {{language}} syntax and best practices.",
        },
        callback_type = "replace_lines",
        allow_empty_text_selection = false,
    },
    ["tests"] = {
        user_message_template =
        "I have the following {{language}} code: ```{{filetype}}\n{{text_selection}}```\nWrite robust unit tests using best practices for the given language. {{language_instructions}} Only return the unit tests. Only return the code snippet and nothing else. ",
        language_instructions = {
            ["*"] = "Use modern {{language}} syntax. Generate unit tests using a standard testing framework appropriate for {{language}}.",
        },
        callback_type = "text_popup",
    },
    ["query"] = {
        user_message_template = "{{command_args}}\n{{text_selection}}",
        callback_type = "text_popup",
        allow_empty_text_selection = true,
    },
    ["popup"]= {
        callback_type = "text_popup",
        allow_empty_text_selection = true,
    },
    ["search"] = {
        user_message_template = "{{command_args}}\n{{text_selection}}\nIf sufficient, use the provided search results as a source and don't justify the usege of search or mention that you are searching, just answer.",
        system_message_template = "You are a helpful assistant. Use the web search tool to find up-to-date information to answer the user's query comprehensively.",
        callback_type = "text_popup",
        allow_empty_text_selection = true,
        is_search_command = true,
        loading_message = "Searching the web...",
    },
}

-- Search Options
if vim.g.qllm_show_search_sources == nil then
    vim.g.qllm_show_search_sources = true
end

if vim.g.qllm_ground_include_queue == nil then
    vim.g.qllm_ground_include_queue = vim.g.qllm_ground_with_queue or vim.g.qllm_ground_with_history
    if vim.g.qllm_ground_include_queue == nil then
        vim.g.qllm_ground_include_queue = false
    end
end

-- Popup commands
vim.g.qllm_ui_commands = {
    quit = "q",
    use_as_output = "<c-o>",
    use_as_input = "<c-i>",
    search = "<c-s>",
}

-- Does the popup close when clicking outside the windod
if vim.g.qllm_close_on_leave == nil then
    vim.g.qllm_close_on_leave = true
end

-- Additional way to quit popup with double escape (within 500ms)
if vim.g.qllm_quit_with_double_esc == nil then
    vim.g.qllm_quit_with_double_esc = true
end

-- Troubleshooting & Debugging
vim.g.qllm_log_enabled = false
vim.g.qllm_debug = false

vim.g.qllm_ui_custom_commands = {}

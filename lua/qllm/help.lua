local Utils = require("qllm.utils")
local Ui = require("qllm.ui")

local M = {}

local command_descriptions = {
    query = "General purpose chat assistant. Use this for general questions, brainstorming, or when no code is selected. It maintains conversation queue.",
    search = "Triggers a web search (grounding) before answering to provide up-to-date information and reduce LLM hallucinations.",
    complete = "Completes the current code selection. Useful for finishing a function or block of code based on the context provided by the selection.",
    edit = "Modifies the selected code based on your instructions. Use this to refactor, change logic, or apply specific transformations to existing code.",
    explain = "Provides a detailed explanation of the selected code. It breaks down the logic and explains it in simple terms, useful for understanding complex legacy code.",
    files = "Reads multiple local project files (supports wildcards) and passes their content as context to the prompt.",
    scan = "Searches the project call graph for definitions matching the query, ranked by structural centrality, then adds text matches. Prefix `-s` for structural only, `-t` for text only.",
    init = "Analyzes the current project directory and creates a `qLLM.md` map to enable project-specific context orchestration.",
    tree = "Queries the call graph or reference map for the specified function or variable (e.g. `:Que tree my_func`), recursively walking symbol connections.",
    deadcode = "Runs static analysis on the mapped codebase to identify unused functions, stubs, and local variables.",
    wiki = "Performs a semantic search across your local Knowledge Base using Hierarchical RAG (Map & Territory).",
    wiki_index = "Scans your KB folder and performs a 'one-pass' indexing with LLM-generated summaries and vectors.",
    wiki_lint = "Runs the Global Auditor to find 'Shadow Concepts' and 'Orphan Files', populating the Quickfix list.",
    wiki_save = "Saves the current buffer or visual selection directly into the Knowledge Base for future retrieval.",
    doc = "Generates documentation for the selected code. It produces function/method documentation (e.g., Javadoc, Doxygen) following best practices for the language.",
    tests = "Generates unit tests for the selected code. It attempts to use standard testing frameworks appropriate for the language (e.g., JUnit for Java, gtest for C++).",
    opt = "Suggests optimizations for the selected code. It looks for performance improvements or cleaner ways to implement the same logic.",
    debug = "Analyzes the selected code for potential bugs or issues. It acts as a static analysis tool to spot logical errors or common pitfalls.",
    recall = "Displays the last response from the assistant in a popup window. Accepts an optional number to go further back (e.g., `:Que recall 2` for the second-to-last response).",
    recallq = "Displays the last prompt/question sent to the assistant in a popup window. Accepts an optional index (e.g., `:Que recallq 2`).",
    undo = "Removes the last exchange (your prompt and the assistant's response) from the chat queue. Useful for undoing a bad conversation turn.",
    clear = "Clears the chat queue for the current buffer. This resets the conversation context.",
    help = "Displays this help file, listing available commands, keybindings, and configuration options.",
    heavy = "Configures the heaviness level of the chat queue. Usage: `:Que heavy [low|medium|high]`. Defaults to low.",
    copy = "Copies chat queue from a source buffer into the current buffer. Usage: `:Que copy [src_bufnr] [merge]`.",
    list = "Lists all buffers with active chat queue in a popup table.",
    export = "Exports the current buffer's active conversation queue to a JSON file. Usage: `:Que export [filepath]`.",
    load = "Loads a text file as context or restores/merges a previously exported JSON session. Usage: `:Que load [filepath]`.",
    json = "Launches the interactive JSON explorer. Inside the popup, use `f` and `d` to cycle indexes.",
    listmodels = "Displays all configured models, providers, presets, and search defaults in a markdown popup.",
}

function M.get_help_lines()
    local lines = {
        "# qLLM.nvim Help",
        "",
        "## Usage",
        "- `:Que <prompt>`: Send a general query to the LLM.",
        "- `:Que <command>`: Execute a specific command (e.g., `:Que explain`).",
        "- `:'<,'>Que <command>`: Execute a command on a visual selection.",
        "",
        "## UI Keybindings",
    }

    local ui_cmds = vim.g.qllm_ui_commands
    table.insert(lines, "- `" .. ui_cmds.quit .. "`: Quit window")
    table.insert(lines, "- `" .. ui_cmds.use_as_output .. "`: Use as output (replace original selection with response)")
    table.insert(lines, "- `" .. ui_cmds.use_as_input .. "`: Use as input (select response and start new chat)")
    
    table.insert(lines, "")
    table.insert(lines, "## Commands")

    local commnds_listed = {
        "query", "search", "complete", "edit",
        "explain", "files", "scan", "init", "tree", "deadcode",
        "wiki", "wiki_index", "wiki_save", "wiki_lint",
        "doc", "tests", "opt", "debug",
        "recall", "recallq", "undo", "clear", "help",
        "heavy", "hcopy", "hlist", "listmodels", "export", "load", "json"
    }

    local all_commands = {}
    local seen = {}

    for _, name in ipairs(commnds_listed) do
        -- Only add it if it actually exists in the defaults or descriptions
        if command_descriptions[name] or (vim.g.qllm_commands_defaults and vim.g.qllm_commands_defaults[name]) then
            table.insert(all_commands, name)
            seen[name] = true
        end
    end
    
    local function collect_cmds(source)
        if not source then return end
        for name, _ in pairs(source) do
            if not seen[name] then
                table.insert(all_commands, name)
                seen[name] = true
            end
        end
    end

    collect_cmds(vim.g.qllm_commands_defaults)
    collect_cmds(vim.g.qllm_commands)

    for _, name in ipairs(all_commands) do
        local desc = command_descriptions[name] or "Custom user command."
        table.insert(lines, "### " .. name)
        table.insert(lines, desc)
        table.insert(lines, "")
    end

    table.insert(lines, "### Configuration")
    table.insert(lines, "You can customize qLLM by setting global variables in your Neovim config (init.lua).")
    table.insert(lines, "")
    
    table.insert(lines, "### Provider Settings")
    table.insert(lines, "`vim.g.qllm_api_provider` (string)")
    table.insert(lines, "Sets the active LLM provider. Default: `'openai'`.")
    table.insert(lines, "Available options: `'openai'`, `'anthropic'`, `'gemini'`, `'ollama'`, `'groq'`.")
    table.insert(lines, "")
    
    table.insert(lines, "### Model Configuration")
    table.insert(lines, "To change the model or other settings, use the unified defaults table.")
    table.insert(lines, "")
    
    table.insert(lines, "`vim.g.qllm_commands_defaults` (table)")
    table.insert(lines, "A dual-purpose table. Flat keys act as global defaults for all commands. Nested tables override settings for a specific command.")
    table.insert(lines, "Example:")
    table.insert(lines, "```lua")
    table.insert(lines, "vim.g.qllm_commands_defaults = {")
    table.insert(lines, "  model = 'gpt-5.4-nano', -- Global")
    table.insert(lines, "  thinking = true,      -- Global")
    table.insert(lines, "  complete = {")
    table.insert(lines, "    thinking = false    -- Override for 'complete'")
    table.insert(lines, "  }")
    table.insert(lines, "}")
    table.insert(lines, "```")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.qllm_commands` (table)")
    table.insert(lines, "User-defined commands. These have the highest precedence.")
    table.insert(lines, "")

    table.insert(lines, "### Search (Grounding)")
    table.insert(lines, "To set the search model.")
    table.insert(lines, "")
    table.insert(lines, "Example: `vim.g.qllm_search_provider = 'anthropic'`")
    table.insert(lines, "`vim.g.qllm_commands_defaults = { search_model = 'claude-sonnet-4-6' }`")
    table.insert(lines, "Overrides default grounding model. Be aware that API specs might be different for older models")
    table.insert(lines, "")

    table.insert(lines, "### Conversation Queue (Memory)")
    table.insert(lines, "`vim.g.qllm_queue_opts` (table)")
    table.insert(lines, "Configuration options for conversation queue and summarization.")
    table.insert(lines, "Options include: `summarize_style`, `max_messages`, `max_tokens`, `time_based_expiry`, `timeout`.")
    table.insert(lines, "")

    table.insert(lines, "### UI Customization")
    table.insert(lines, "`vim.g.qllm_popup_type` (string)")
    table.insert(lines, "Determines how the result window opens.")
    table.insert(lines, "Options:")
    table.insert(lines, "- `'popup'`: Centered floating window (default).")
    table.insert(lines, "- `'horizontal'`: Split window at the bottom.")
    table.insert(lines, "- `'vertical'`: Split window on the right.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.qllm_horizontal_popup_size` (string)")
    table.insert(lines, "Height of the horizontal split. Default: `'20%'`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.qllm_vertical_popup_size` (string)")
    table.insert(lines, "Width of the vertical split. Default: `'20%'`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.qllm_popup_border` (table)")
    table.insert(lines, "Border style for the popup window. Default: `{ style = 'rounded' }`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.qllm_text_popup_filetype` (string)")
    table.insert(lines, "Filetype for the result window (for syntax highlighting). Default: `'markdown'`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.qllm_ui_commands` (table)")
    table.insert(lines, "Customizes keybindings within the qLLM window.")
    table.insert(lines, "Default:")
    table.insert(lines, "```lua")
    table.insert(lines, "vim.g.qllm_ui_commands = {")
    table.insert(lines, "    quit = 'q',")
    table.insert(lines, "    use_as_output = '<c-o>',")
    table.insert(lines, "    use_as_input = '<c-i>'")
    table.insert(lines, "}")
    table.insert(lines, "```")
    table.insert(lines, "")
    
    table.insert(lines, "### Miscellaneous")
    table.insert(lines, "`vim.g.qllm_clear_visual_selection` (boolean)")
    table.insert(lines, "Whether to clear the visual selection after a command runs. Default: `true`.")

    table.insert(lines, "")
    table.insert(lines, "## Workflow Examples")
    
    table.insert(lines, "### 1. Multi-File Context Understanding")
    table.insert(lines, "1. Type `:Que files [src/main.lua src/utils.lua]` How do these files interact?")
    table.insert(lines, "2. Press Enter. The LLM will read both files and answer the query.")
    table.insert(lines, "3. *Tip*: Use `<Tab>` after typing `[` to use native file path autocomplete!")
    table.insert(lines, "")

    table.insert(lines, "### 2. Iterative Refactor (with Context Injection)")
    table.insert(lines, "1. Select a function visually.")
    table.insert(lines, "2. Press `<C-i>` inside an empty popup to start a query with that code.")
    table.insert(lines, "3. Type: `Make this more functional style` and hit Enter.")
    table.insert(lines, "4. The model answers. If it needs tweaking, select the new code and press `<C-i>` again.")
    table.insert(lines, "5. Type: `Also add type annotations.`")
    table.insert(lines, "6. If it looks good, press `<C-o>` (Use as Output) to replace the original code in the editor.")
    table.insert(lines, "")

    table.insert(lines, "### 3. Local Knowledge Base (RAG)")
    table.insert(lines, "Ask questions against your local markdown notes without sending data to the cloud.")
    table.insert(lines, "1. Ensure you have markdown files in the configured `wiki_folder`.")
    table.insert(lines, "2. Run `:Que wiki_index` to map the folder (only needed when files change).")
    table.insert(lines, "3. Ask a question: `:Que wiki What are our deployment steps?`")
    table.insert(lines, "4. The LLM will search your local files, find the right context, and synthesize an answer.")
    table.insert(lines, "")

    table.insert(lines, "### 4. Queue Navigation")
    table.insert(lines, "1. Run `:Que recall` to view the last assistant answer.")
    table.insert(lines, "2. Run `:Que recallq` to view the *query* you sent to get that answer.")
    table.insert(lines, "3. Once any recall/recallq popup is open, press `f` to go forward and `d` to go backward in-place.")
    
    return lines
end

function M.show_help(bufnr)
    local lines = M.get_help_lines()
    local start_row, start_col, end_row, end_col = Utils.get_visual_selection()
    
    -- If no visual selection, we still need generic coordinates for the popup
    -- The popup function handles "empty" coordinates gracefully by centering or defaulting
    Ui.popup(lines, "markdown", bufnr, start_row, start_col, end_row, end_col)
end

return M

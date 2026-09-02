# qLLM.nvim

qLLM (queue LLM) provides a way to interact with LLMs from within the Neovim editor. Running a command followed by a prompt opens the response in a popup window. The plugin is highly configurable and includes advanced context and knowledge management tools, as well as coding focused commands.

No Agentic Overhead - qLLM follows the philosophy: "developer is the agent orchestrator". This allows for a streamlined workflow with mid-size or large local language models and gives control back to the developer who may find themselves stuck in an agentic loop.

Focus is on context management, knowledge extraction and using direct commands to call tools and self-orchestrate the AI development workflow.

### Installation

| | Requirements |
|-------------|-------------|
| Dependencies | [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), [nui.nvim](https://github.com/MunifTanjim/nui.nvim), and [nvim-treesitter](https://github.com/neovim-treesitter/nvim-treesitter) (with parsers installed for target languages). |
| External (Code Map) | [tokei](https://github.com/XAMPPRocky/tokei) - CLI binary required for project mapping. <br> • macOS: `brew install tokei` <br> • Linux: `cargo install tokei` (or package manager) <br> • Windows: `scoop install tokei` (or cargo) |
| External (Wiki) | `sqlite3` CLI and the `sqlite-vec` shared library (see [setup guide](#vector-search-setup-sqlite-vec)). |

Set environment variable for your preferred API key e.g. `ANTHROPIC_API_KEY` [Claude API key](https://platform.claude.com/settings/workspaces/default/keys).

Installing with [lazy.nvim](https://github.com/folke/lazy.nvim).

```lua
{
   "filtercodes/qLLM.nvim",
   dependencies = {
      "MunifTanjim/nui.nvim",
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter", -- Required for AST parsing and code analysis
   },
   config = function()
      require("qllm.config")
      vim.g.qllm_api_provider = "ollama" -- Run a local model with ollama
      vim.g.qllm_provider_defaults = {
          ollama = { model = "gemma4" }
      }
      -- Add other settings or custom commands (explained below)
   end
}
```

Installing with [vim-plug](https://github.com/junegunn/vim-plug).

```vim
" Install plugins
Plug("nvim-lua/plenary.nvim")
Plug("MunifTanjim/nui.nvim")
Plug("neovim-treesitter/nvim-treesitter")
Plug('filtercodes/qLLM.nvim')

call plug#end()

" Configuration after the plugins are loaded
lua << EOF
    require("qllm.config")
    vim.g.qllm_api_provider = "gemini"
EOF
```

* Note on Neovim 0.12 and later - to fix problems with status line duplication, enable new UI engine

```lua
pcall(function() require('vim._core.ui2').enable() end)
```

## Commands

The top-level command is `:Que`. Without passing any additional args it triggers a general LLM request using as input text selection and/or prompt text. 'Que' stands for Query, Question, Queue... or whatever you'd like it to mean.

![chat](examples/chat.gif?raw=true)

#### Direct Provider commands & Presets
In addition to `:Que` (which uses globally configured default provider), you can invoke specific providers directly, bypassing default settings e.g.:
* `:Gemini <prompt>`
* `:Claude <prompt>` etc.

Using these commands works exactly like `:Que`, but routes the request to the specified API with its default model.

There are also configurable presets: `:Pre1`, `:Pre2`, `:Pre3`...up to `:Pre9`. To switch between more different models when needed (e.g., setting `:Pre2` to use Anthropic's Claude 4.6 Sonnet while `:Que` default runs a local Ollama instance). See [Overriding command configurations](#overriding-command-configurations) section below for details. Presets are dynamically created only if the seettings are found for it.

Commands are logically categorized into **Action** (direct text generation or editing) and **Analysis** (context and knowledge gathering). This distinction allows for orchestrating a development workflow by first building a context through analysis before executing targeted actions.

## List of default commands

#### General

| Command      | Input | Description |
|--------------|---- |------------------------------------|
| query  |  prompt and/or text selection | General query - Passes the given prompt to LLM and returns the response in a popup. |
| search |  prompt and/or text selection | Triggers a web search (grounding) before answering to provide up-to-date information. Shows the grounded answer in a popup. |

#### Code related commands

| Command      | Input | Description |
|--------------|---- |------------------------------------|
| complete |  text selection | Asks LLM to complete the selected code directly in the editor. |
| edit  |  text selection (optional prompt) | Asks LLM to apply the given instructions to the selected code in the editor. |
| tests  |  text selection | Asks LLM to write unit tests for the selected code in the popup window. |
| debug  |  text selection | Passes the code selection to LLM to analyze it for bugs, the results will be in a popup. |
| opt  |  text selection | Asks LLM to optimize the selected code. Updates the code directly in the editor. |
| doc  |  text selection | Asks LLM to document the selected code. Updates the text directly in the editor. |

#### Context commands

| Command      | Input | Description |
|--------------|---- |------------------------------------|
| init  |  none | Analyzes the local folder and subfolders to create an architectural map (`qLLM.md`) for the context orchestration. |
| explain  |  text selection | Asks LLM to explain the selected text or code and returns the explanation in a text popup.|
| files  |  [file paths] and prompt | Reads files content (supports wildcards) and passes it as context for the prompt. |
| scan  |  query -- prompt | Searches the project call graph for definitions matching the query, ranked by structural centrality, then supplements them with text matches. Divide query and prompt with space-double-dash-space. Prefix `-s` for structural only, `-t` for text only. |
| tree  |  symbol name | Queries the project call graph or reference map for the symbol, displaying its callers (upward) and callees (downward) in a text popup. |
| deadcode | none | Analyzes the project call graph to find disconnected/unused functions, unfinished stubs (with TODO/FIXME tags), and unused local variables. |

#### Wiki commands

| Command      | Input | Description |
|--------------|---- |------------------------------------|
| wiki  |  query | Performs a semantic search across your personal "Wiki" Knowledge Base using Hierarchical RAG. |
| wiki_index  |  none | Scans your Wiki folder and performs a one-pass indexing with LLM-generated summaries and vectors. |
| wiki_save  |  text selection or none | Saves current buffer or visual selection into the Wiki Knowledge Base for future retrieval. |
| wiki_lint  |  none | Runs the Auditor to find isolated notes or 'Shadow Concepts' in the Wiki. |

#### Conversation management

| Command      | Input | Description |
|--------------|---- |------------------------------------|
| recall  |  none or number | Displays the last assistant response from the chat queue in a popup without altering the queue. Optionally accept a number to go further back (e.g., `:Que recall 2`). |
| undo  |  none | Removes the last exchange (prompt and the assistant's response) from the chat queue. Useful for reverting a bad conversation turn. |
| clear  |  none | Completely clears the conversation to start fresh. |
| list  |  none | Shows the information about conversation queue: buffer number, the number of messages, estimated tokens, last model, name. |
| copy  |  number and "merge" | Copy entire buffer queue to another buffer. If passing merge command after buffer number, both buffers will be merged. |
| load   |  filepath or selection | Load text selection or file content into the chat queue. If the file is a qLLM exported JSON queue, it will restore or merge it. |
| export |  filepath or none | Export the current chat queue to a JSON file. If filepath is omitted, it auto-generates a filename based on the project folder and date. |
| heavy  |  "low", "medium", or "high" | Configures the heaviness level of the chat queue. Dynamically changes how much context (files, selections, search results) is preserved in subsequent turns. |


#### Other

| Command      | Input | Description |
|--------------|---- |------------------------------------|
| popup  |  none | Opens an empty popup window - to use for crafting multiline prompt, copy pasting text, etc. |
| json   |  filepath, none, or filepath + path | Opens JSON explorer in a popup. Supports keypath drilling, back navigation, and automatic index pagination. |
| listmodels |  none | Displays all configured models, providers, presets, and search defaults in a popup. |
| help  |  none | Displays the help guide. |

## Overriding command configurations

The main configuration table is `vim.g.qllm_commands_defaults`. It allows you to set options both globally (to all commands) and directly for specific commands.

#### Setting defaults

Any key placed directly in `qllm_commands_defaults` acts as a global default. To override a setting for a specific command, add a sub-table with the command's name.

```lua
vim.g.qllm_commands_defaults = {
    -- GLOBAL SETTINGS
    system_message_template = "You are a {{language}} coding assistant.",
    loading_message = "Generating...",

    -- COMMAND OVERRIDES
    complete = {
        thinking = false, -- Disable thinking for instant code completion
        temperature = 0.1, -- Better focus for completions
    },
    edit = {
        thinking = true, -- Apply background reasoning only when running edit command
    },
    explain = {
        model = "claude-opus-4-7", -- Use a smarter model just for explanations
        provider = "anthropic", -- Make sure to target the right API provider for the model
    }
}
```

#### Other supported overrides

| Name | Value | Description |
|------|---------|-------------|
| output_tokens | `nil` | The output limit of response tokens the model is allowed to generate. |
| user_message_template | "" | The primary prompt template. |
| callback_type | "text_popup" | Controls UI behavior (`replace_lines` or `text_popup`). |
| allow_empty_text_selection | true | If false, command doesn't run without a visual selection. |
| language_instructions | {} | Map of `filetype` -> specific instructions. |
| extra_params | {} | Table of custom parameters for the API (e.g., `top_p`, `stop_sequences`). |

#### Configuring Providers and Models

Define base models for each provider using `vim.g.qllm_provider_defaults`. This is the fallback model if no global or command-specific model is set.

```lua
vim.g.qllm_provider_defaults = {
    ollama = { 
        model = "qwen3:8b",
        thinking = true -- Enable reasoning for this provider
    },
    anthropic = { model = "claude-haiku-4-5" },
}

-- Search (grounding) command setup for different providers
vim.g.qllm_search_model_defaults = {
    local_grounding = { model = "gemma4" },
    gemini = { model = "gemini-3.5-flash" }
}

-- Global UI toggle: Show or hide the thinking context in the popup
vim.g.qllm_show_thinking = true
```

#### Configuring Presets (:Pre1, :Pre2, :Pre3)

Each preset has its own configuration scope. Append `1`, `2`, or `3` to the variables. This is useful for mapping a preset to a completely different stack.

```lua
-- Configure :Pre1 to be a "Local Dev" preset
vim.g.qllm_api_provider1 = "ollama"
vim.g.qllm_commands_defaults1 = {
    model = "qwen3-coder",
    thinking = true,
    temperature = 0.2
}
```

### Search (Grounding) configuration

`vim.g.qllm_search_provider` - Defines which provider to use for the default `:Que search` command. Current supported options are `"gemini"`, `"openai"`, `"anthropic"` and `"local_grounding"`. Defaults to `"gemini"`. Set [default grounding model](#configuring-providers-and-models) using `vim.g.qllm_search_model_defaults`.

`vim.g.qllm_show_search_sources` - Boolean (Default: `true`). Show or hide the links/citations used by LLM during a search in the popup UI. If you are using a smaller model you can set it to `false` to deal with strict context limits.

`vim.g.qllm_ground_include_queue` - Boolean (Default: `false`). If you want to send previous conversation queue to the grounding model set it to `true`. This might be useful for model to pick up more info about the search term from the context, but also conversation queue might confuse smaller local models or create biased grounding.

```lua
vim.g.qllm_search_provider = "local_grounding"
vim.g.qllm_show_search_sources = true
vim.g.qllm_ground_include_queue = true
```

* Note that `"local_grounding"` requires `TAVILY_API_KEY` as an environment variable! Local Ollama model uses internet search results from [Tavily](https://app.tavily.com/home) to construct a grounded answer.

## Context commands (project map)

If you have manually initialized the project with `:Que init`, qLLM creates an architectural map (`qLLM.md`). This map gets added to the background context of the `files`, `scan`, and `explain` commands which then automatically pull relevant content by querying the project graph.

*   `:Que init`: Analyzes current project directory and creates a `qLLM.md` map.
*   `:Que files [file1.py file2.js *.md] prompt`: Reads local files (supports wildcards and escaped quotes) and passes their content as the context for the prompt.
    *   Note: If no prompt is provided, it defaults to the `explain` command for all files.
*   `:Que scan [src/*.lua] query -- prompt`: Structural, centrality-ranked code search. It looks the `"query"` up in the project graph (`qLLM_map.json`) and returns the actual definitions that carry the name — functions, types and module-level variables — ranked by how central each is to the call graph, then appends plain text matches for anything a graph cannot hold (comments, config, markup).
    *   Ranking combines the quality of the name match with structural centrality: how many distinct files call a definition, how often, and how important its callers are in turn. A function called from twenty files outranks a same-named local helper, and definitions in test, mock or fixture paths are pushed down, so core API methods surface ahead of test doubles.
    *   Modes: `-s` searches only the graph, `-t` only the text (the pre-graph behaviour), `-a` forces both. Without a flag the `scan_mode` setting applies, which defaults to `hybrid`. If the project has never been initialized with `:Que init`, scan falls back to text search on its own.
    *   If the query names nothing in the graph, scan reports the definitions that *reference* it instead, ranked the same way — which is how symbols the indexer does not record as definitions still resolve.
    *   Note: If no prompt is provided, it displays the ranked results in a popup without calling the LLM. The result goes to the chat queue so the next LLM inference can see it. With a prompt, the LLM receives whole definition bodies with their callers and callees, rather than matching lines.
*   `:Que tree <function_or_variable>`: Queries the call graph or reference map for the specified function or variable. It parses the indexed map and walks symbol connections to trace upward callers and downward callees recursively.
*   `:Que deadcode`: Runs static analysis on the mapped codebase to identify unused/disconnected functions, unfinished stubs (including empty functions and those containing `TODO`/`FIXME` tags), and unused local variables. Selecting any detected item opens the file at the exact coordinate.
    *   Note: Exported public APIs, entry points, or dynamically registered callback functions may be reported as disconnected (having 0 callers) because they are invoked externally or dynamically.

For best results with code analysis, install the Tree-sitter parsers:
```lua
:TSInstall markdown markdown_inline lua python javascript
```
Otherwise the logic will fall back to the manual analysis which is flawed. This will also enable syntax highlighting inside the markdown response for the installed languages.

## Knowledge Base

Knowledge Base is inspired by the **[LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)** concept proposed by Andrej Karpathy, implementing a dual-layer retrieval system for semantic discovery.

#### The "Librarian" architecture
When running in `complex` mode, qLLM employs the strategy:
1.  Summaries: Retrieval finds the top relevant documents based on LLM-generated summaries and conceptual schema links.
2.  Chunks: Retrieval finds specific, granular evidence chunks using header-aware semantic splitting.

*   Librarian self-healing: When you save a note, qLLM identifies semantically related files and updates them in the background to include back-links and connections to the new note, keeping Wiki compounding over time.

#### Wiki management
These commands operate on your `~/knowledge_base` folder (or another folder of your preference).

*   `:Que wiki <query>`: Performs a semantic search across the Wiki Knowledge Base using the Hierarchical RAG.
*   `:Que wiki_index`: Scans the Wiki folder and performs a "one-pass" indexing. It uses an LLM to do cross-linking, generating summaries and schema connections while computing vectors. It includes sha256-based change detection to skip unchanged files.
*   `:Que wiki_save filename.md`: Saves the current buffer or visual selection directly into the Wiki and triggers a background index update for that file.
*   `:Que wiki_lint`: Runs the Auditor. It populates Neovim Quickfix list with "Shadow Concepts" (highly similar files with no shared tags) and "Orphan Files" (notes that are never mentioned elsewhere).

#### Configuration

All Knowledge Base and Project Context settings are unified under `vim.g.qllm_kb_opts`.

```lua
vim.g.qllm_kb_opts = {
    -- INFRASTRUCTURE
    db_path = vim.fn.stdpath("data") .. "/qllm_kb.db", -- SQLite database file
    sqlite_vec_path = "",        -- Path to the sqlite-vec extension (e.g. /path/to/vec0.so)

    -- WIKI (Knowledge Base)
    wiki_folder = vim.fn.getcwd() .. "/knowledge_base", -- Your Markdown notes directory
    style = "complex",           -- "simple" (fast) | "complex" (Hierarchical RAG)

    -- EMBEDDINGS
    provider = "ollama",         -- Provider for vectors (ollama, openai, gemini)
    model = "nomic-embed-text",  -- The specific embedding model
    dimension = 768,             -- Vector size (768 for nomic, 1536 for openai)

    -- CONTEXT GENERATION (Wiki & Project)
    context_provider = "ollama", -- Provider for local project mapping and Wiki metadata
    context_model = "gemma4",    -- Model used for indexing and context generation
    auto_init = true,            -- Auto-sync if qLLM.md is present and stale
    auto_check_freshness = true, -- Check for structural changes on every scan/files command

    -- ORCHESTRATION (The Librarian)
    scan_context = 3,            -- Lines of context around scan text matches
    scan_index_variables = true, -- Index module-level variables in the project map
    scan_use_ctags = true,       -- Use Universal Ctags (if installed) to cover languages
                                 -- with no Tree-sitter parser available

    -- Structural scan
    scan_mode = "hybrid",        -- "hybrid" | "structural" | "text"
    scan_max_results = 20,       -- Ranked definitions shown in the popup
    scan_max_defs = 5,           -- Definition bodies sent to the LLM
    scan_centrality_weight = 1.0, -- How strongly centrality boosts a name match
    scan_test_penalty = 0.5,     -- Score multiplier for test/mock/fixture paths
    scan_test_patterns = nil,    -- Override the default test path segments
    scan_text_budget = 4000,     -- Char cap on text matches supplementing structural ones
    sync_strategy = "auto",      -- "auto" (cross-linking) | "manual"
    neighborhood_size = 5,       -- Number of related files to weave
}

-- Model Intelligence Strategies
-- Defines if a provider can handle updating all neighbors in one pass ("god_prompt") 
-- or if it needs to update them one by one ("lazy").
vim.g.qllm_provider_capabilities = {
    ["anthropic"] = { strategy = "god_prompt" },
    ["ollama"] = { strategy = "lazy" },
}
```

#### Vector Search setup (sqlite-vec)

To enable semantic search for Knowledge Base, download the `sqlite-vec` shared library. This is a small, vector database extension for SQLite.

1.  Download the Extension: Get the pre-compiled binary from the [sqlite-vec releases](https://github.com/asg017/sqlite-vec/releases).
    *   macOS: `vec0.dylib`
    *   Linux: `vec0.so`
    *   Windows: `vec0.dll`
2.  Configure the Path: Update `kb_opts` with the absolute path to this file.

```lua
vim.g.qllm_kb_opts = {
    sqlite_vec_path = "/path/to/vec0.dylib", -- Path to downloaded extension
    -- ... other options
}
```

* Note: The `sqlite3` CLI must also be available in `$PATH` for the Knowledge Base to function.

## Chat Queue (short-term memory)

At the high level, context pipeline resembles a queue hence the name qLLM (queue LLM). It’s a First In First Out conversation pipeline that automatically manages itself. You can tune its behavior using the `vim.g.qllm_queue_opts` table.

| Option | Default | Description |
|--------|---------|-------------|
| summarize_style | "messages" | Select a way to track conversation buffer when `max_messages` (or `max_tokens`) is reached; Tokens and messages summarize, and none uses hard sliding window to drop the oldest conversation pairs. |
| summarize_model | *(Global)* | The model to use for background summarization. |
| summarize_provider | *(Global)* | The provider to use for background summarization. |
| summarize_percent | 50 | What percentage of messages will be summarized. Default is 50%. |
| max_messages | 50 | Total messages to retain before summarizing older ones. |
| max_tokens | 24000 | Number of tokens to reach for summarization logic to trigger. |
| time_based_expiry | false | If `true`, queue automatically clears after the `timeout`. |
| timeout | 1800 | Inactivity window (in seconds) before queue expires (if `time_based_expiry` set to `true`). |

`summarize_style` takes string as an input. Options are:
- `"none"`      -- no summarization, sliding window only
- `"messages"`  -- summarize when message count exceeds `max_messages`
- `"tokens"`    -- summarize when token count exceeds `max_tokens`

Example configuration (`init.lua`):

```lua
-- Modern queue setup with background summarization
vim.g.qllm_queue_opts = {
    summarize_style = "tokens",
    max_tokens = 80000,              -- 80k should be a safe zone for most modern models
    summarize_percent = 30,          -- Rather subtle summarise only 30% of oldest messages
    summarize_provider = "openai",
    summarize_model = "gpt-4o-mini", -- Use a cheap model for background work
    time_based_expiry = false,       -- Turn off amnesia mode
}
```

### Variable Queue Heaviness

To prevent the LLM context from cluttering quickly or sending stale versions of files, use the "Variable Queue Heaviness". You can control the amount of context (such as resolved file contents, visual selections, and search results) from the commands that is carried forward into subsequent conversation turns.

Default, heaviness setting is `"low"`. It can be set globally via `vim.g.qllm_queue_heaviness`, and there is also a command to change it dynamically when required using the `:Que heavy low|medium|high`.

#### Heaviness levels:
- `low` (Default): Only the clean query prompt/instruction (e.g., `"FILES: explain this in [queue.lua]"`) is recorded in the conversation queue. Visual selection code, Tavily search results, and raw file contents are discarded on subsequent turns. This is token-efficient and prevents the LLM from referencing stale, outdated code versions as you modify files.
- `medium`: Visual selections and search results are preserved and re-sent in queue, but full file contents are excluded. This is good for active, selection-based coding sessions without buffer-bloat.
- `high`: Everything (including raw file contents, selections, and search results) is appended to subsequent turns. This provides the LLM with complete memory of the input, at the cost of higher token consumption and potential confusion if file contents change.

The idea is that some context is preservable and static with high importance and requires high heaviness, while other context might be in the process of change or completely non-relevant for the major context of the conversation. Changing the heaviness level on demand, allows for higher granularity in context managent.

#### Queue navigation

View previous assistant responses in a popup window using keyboard shortcuts:

```lua
local qllm = require("qllm")

-- Map keys 1-9 to view specific queue items in a popup (e.g., <leader>q1 is last, q2 is one before, etc.)
for i = 1, 9 do
    vim.keymap.set("n", "<leader>q" .. i, function() qllm.recall(i) end)
end

-- Other queue actions
vim.keymap.set("n", "<leader>qu", function() qllm.undo() end)
vim.keymap.set("n", "<leader>qc", function() qllm.clear() end)
```

To traverse the queue without closing and reopening the window:
*   Press `f` to go forward (toward the most recent response/question).
*   Press `d` to go backward (toward older responses/questions).

#### Copy and Merge

To copy conversation queue from one buffer to another first use `list` command:

```
:Que list -- It will list the current conversation information in a popup list
```

| bufnr | messages | tokens | last model | buffer name |
|-------|----------|--------|------------|-------------|
| 3 | 12 | 492 | claude-3-5 | main.py  (2m ago) |
| 1 | 4 | 49 | gpt-4o | utils.py  (1h ago) |

```
:Que copy          -- copies from buf 3 (alternate buffer, the one you just left)
:Que copy 3        -- explicit — same result
:Que copy 3 merge  -- if buf 5 already had some queue, append buf 3's on it
```

The alternate buffer default (`vim.fn.bufnr('#')`) covers the most natural case — you just left the buffer you want to branch from, so number lookup is not needed at all.

#### Exporting and Importing Sessions

You can save and restore conversation queues to share them, backup your work, or resume them later using `export` and `load`:

- Exporting: Save the active buffer's chat queue to a JSON file:
  ```vim
  :Que export                 -- saves to qllm_<project>_<date>.json in the current directory
  :Que export my_session.json -- saves to the specified file path
  ```
- Loading: Load any file, visual selection, or exported queue:
  ```vim
  :Que load my_session.json   -- detects the exported queue format and restores or merges it
  :Que load rules.md          -- treats as a normal text file and loads its contents as context
  ```

If you load a text file or visual selection, it is appended to the chat queue as a user message and balanced with a mock assistant acknowledgment to maintain role alternation. If you load an exported `qllm` queue JSON file, it will restore the queue exactly as it was. If the active buffer already has queue, the imported messages are merged/appended onto the end of the current conversation (exactly like `copy merge` does).

### JSON Explorer

To inspect structured data and load specific keys or values into the LLM context use `:Que json`:

- Opening: Open the explorer on a JSON file:
  ```vim
  :Que json                  -- opens the current active buffer if it has a .json extension
  :Que json config.json      -- opens the specified JSON file
  :Que json config.json database.credentials.1.user -- opens directly at a nested path
  :Que json "search query"   -- opens active buffer and searches for matches
  :Que json config.json "search query" -- opens file and searches for matches
  ```
- Navigation Controls:
  - Press `<CR>` (Enter) on any line matching `▶ [key]` to go into it.
  - Press `<CR>` on `◀ [..]` or press `<BS>` (Backspace) anywhere to go back up to the parent directory.
  - Press `c` to jump forward to the next expandable child node (lines starting with `▶ ` or `◀ `), and `C` to jump backward to the previous child.
  - Press `u` to undo the last navigation action (pressing it again acts as a redo).
- Index Pagination (Folding Point Traversal):
  - If the path you are exploring contains a numeric array/object index (e.g. `users.1.name`), the first numeric coordinate (scanning left-to-right) acts as the active folding point.
  - While inside the JSON explorer popup, you can press `f` (forward) or `d` (backward) to automatically increment or decrement that index and page through different records (e.g., transitions to `users.2.name`, `users.3.name`) while preserving your deep nested position!
  - Multiple / Nested Indices: If you have multiple nested indices (e.g. `departments.2.employees.5.salary`), the leftmost index (`2`) is active by default. You can change the active folding point at any time by moving your cursor to the `Path:` line at the top of the buffer (line 2) and pressing `<CR>` (Enter) on any other number in the path (e.g., `5`). The active folding point is highlighted in the path string. To reset back to the default leftmost index, press `<CR>` on `root` or the prefix.
  - State Retention: The explorer caches your path position and active folding point for each JSON file. If you exit the popup and reopen the explorer for the same file (without specifying sub-path arguments), it will restore previous position and active folding index. This cache is saved in-memory and resets when Neovim is closed.
- Context Injection:
  - Since the explorer is a standard buffer, you can visually select any keys or values displayed and run `:'<,'>Que load` to dump them into the active conversation queue.
- Search:
  - You can search keys and values across the JSON structure either by passing a quoted search query on launch (`:Que json "search query"`) or by pressing `<c-s>` inside any open JSON explorer popup to open a search prompt.
  - While search mode is active, `f` (forward) and `d` (backward) cycle through all matching nodes across the JSON tree, navigating to the parent path.
  - Pressing `<Esc>` exits search mode and returns to normal folding navigation in-place. The explorer remembers the last search query and position per file.

## Popup options

#### Filetype and syntax

The default filetype of the text popup window is markdown. This can be changed by setting the popup filetype variable.

```lua
vim.g.qllm_text_popup_filetype = "markdown"
```

To make the internal code examples have syntax highlighting and enable better code analysis, add your preferred languages to treesitter:
```lua
require('nvim-treesitter').install { 'markdown', 'markdown_inline', 'python', 'javascript', 'lua' }
```

When using reasoning models, `qllm_show_thinking` configures popup to either display the thinking context or just show the label "Thinking..." instead.
```lua
-- Setting to true will show the thinking context in the popup
vim.g.qllm_show_thinking = true
```

#### Popup commands

```lua
vim.g.qllm_ui_commands = {
  -- some default commands, you can remap the keys
  quit = "q", -- key to quit the popup
  use_as_output = "<c-o>", -- key to use the popup content as output and replace the original lines
  use_as_input = "<c-i>", -- key to use the popup content as input for a new API request
  search = "<c-s>", -- Popup traversal search
}

vim.g.qllm_ui_custom_commands = {
  -- tables as defined by nui.nvim https://github.com/MunifTanjim/nui.nvim/tree/main/lua/nui/popup#popupmap
  {"n", "<c-l>", function() print("do something") end, {noremap = false, silent = false}}
}
```

#### Popup layouts

```lua
vim.g.qllm_popup_layout = {
  -- a table as defined by nui.nvim https://github.com/MunifTanjim/nui.nvim/tree/main/lua/nui/popup#popupupdate_layout
  relative = "editor",
  position = {
    row = "10%",
    col = "90%"
  },
  size = {
    width = "40%",
    height = "80%"
  }
}
```

* Note `size.height` becomes max height if auto expand is `true` - See [Popup UI settings](#popup-ui-settings)

#### Keymaps for popup resizing and movement

Set custom keymaps to adjust the size and position settings for the popup. This is useful for expanding or moving the window out of the way when reading long code blocks. Values set this way will persist till the end of the session/buffer.

The following example maps `<leader>q` + Arrow Keys to resize the dimensions by 10% increments, and `<leader>q` + `hjkl` keys to shift the position by 5% increments.

```lua
local qllm = require("qllm")

-- Increase/Decrease popup dimensions using arrow keys
vim.keymap.set("n", "<leader>q<Up>",    function() qllm.adjust_popup_size(0, 10)   end)
vim.keymap.set("n", "<leader>q<Down>",  function() qllm.adjust_popup_size(0, -10)  end)
vim.keymap.set("n", "<leader>q<Left>",  function() qllm.adjust_popup_size(10, 0)   end)
vim.keymap.set("n", "<leader>q<Right>", function() qllm.adjust_popup_size(-10, 0)  end)

-- Shift popup position by using hjkl keys
vim.keymap.set("n", "<leader>qh",       function() qllm.adjust_popup_position(-5, 0) end)
vim.keymap.set("n", "<leader>qj",       function() qllm.adjust_popup_position(0, 5)  end)
vim.keymap.set("n", "<leader>qk",       function() qllm.adjust_popup_position(0, -5) end)
vim.keymap.set("n", "<leader>ql",       function() qllm.adjust_popup_position(5, 0)  end)
```

#### Popup UI settings

```lua
-- Border style (e.g., "rounded", "single", "double", "solid")
vim.g.qllm_popup_style = "rounded"
-- Whether to automatically expand the popup height as content streams in
vim.g.qllm_auto_expand = true
-- Minimum height for the popup if resizing is true (defaults to 5 lines)
vim.g.qllm_min_popup_height = 5
```

#### Popup window options

This block of settings is passed directly to nui.nvim plugin.

```lua
-- Enable text wrapping and line numbers
vim.g.qllm_popup_window_options = {
  wrap = true,
  linebreak = true,
  relativenumber = true,
  number = true,
}
```

#### Popup window color setup

An example of custom dark mode in vimscript.

```vim
highlight NormalFloat guibg=#2f2f2f ctermbg=235
highlight FloatBorder guifg=#8ec07c ctermfg=108
```

#### Move completion to popup window

For any command, you can override the callback type to move the completion to a popup window. An example below is for overriding the `complete` command.

```lua
require("qllm.config")

vim.g.qllm_commands = {
  complete = {
    callback_type = "text_popup",
  },
}
```

#### Horizontal or vertical split window

If you prefer a horizontal or vertical split window, you can change the popup type to `horizontal` or `vertical`.

```lua
-- options are "horizontal", "vertical", or "popup". Default is "popup"
vim.g.qllm_popup_type = "horizontal"
```

To set the height of the horizontal window or the width of the vertical popup, you can use `qllm_horizontal_popup_size` and `qllm_vertical_popup_size` variables.

```lua
vim.g.qllm_horizontal_popup_size = "40%"
vim.g.qllm_vertical_popup_size = "40%"
```

## More configuration options

#### Custom status hooks

You can add custom hooks to update status line or other ui elements, for example, this code updates the status line colour to yellow while the request is in progress.

```lua
vim.g.qllm_hooks = {
	request_started = function()
		vim.cmd("hi StatusLine ctermbg=NONE ctermfg=yellow")
	end,
  request_finished = vim.schedule_wrap(function()
		vim.cmd("hi StatusLine ctermbg=NONE ctermfg=NONE")
	end)
}
```

#### Lualine status component

There is a convenience function `get_status` to add a status component to lualine. This function provides an animated progress spinner while a request is running, followed by the name of the last command and the active LLM model (e.g., `⠋ query  🤖 qwen3.6:27b`).

```lua
local qllmModule = require("qllm")

require('lualine').setup({
    sections = {
        -- ...
        lualine_x = { qllmModule.get_status, "encoding", "fileformat" },
        -- ...
    }
})
```

To enable the animation of the progress spinner, add `require('lualine').refresh()` to the qLLM hooks in configuration so that the status bar redraws during the request:

```lua
vim.g.qllm_hooks = {
  request_started = function()
    require('lualine').refresh()
  end,
  request_finished = vim.schedule_wrap(function()
    require('lualine').refresh()
  end)
}
```

Alternatively if you don't use `lualine`, a `vim.notify` message will display the current model. If you do use `lualine` you might want to set this to `false`.

```lua
vim.g.qllm_print_model = false
```

#### Optimizing local models (Ollama)

For the faster inference speed with local models via Ollama, you may want to set an empty system prompt for better prompt caching. If you configured a custom one in your `Modelfile`, then be sure to disable it globally in the Ollama provider settings:

```lua
-- Optimize a preset (e.g., :Pre1)
vim.g.qllm_api_provider1 = "ollama"
vim.g.qllm_commands_defaults1 = {
    system_message_template = "", -- Empty system prompt for better caching
    search = {
        provider = "local_grounding",
        system_message_template = "" -- Also clear for search
    }
}
```

Additionally, look into how to enable KV Cache, and for MacOS use [NVFP4](https://ollama.com/blog/mlx) models to utilise MLX framework natively.

## Troubleshooting & Logging

Enable logging to inspect the raw JSON payloads sent to and from the LLM providers.

#### Enabling logs

Logging can be enabled for the entire session or just for the next request.

```lua
-- Enable logging for the entire session
vim.g.qllm_log_enabled = true

-- Enable "One-Shot" logging (logs only the next request, then disables itself)
vim.g.qllm_debug = true
```

#### Viewing logs

Logs are written to a file in local Neovim state directory. Find the exact path by running `:lua print(require("qllm.logger").get_log_path())`

View in real-time:

```bash
tail -f ~/.local/state/nvim/qllm.log
```

The logs contain full JSON request payload and the assistant response.

## Writing new commands

#### Custom commands

Custom commands can be added to the `vim.g.qllm_commands` configuration option to extend the available commands.

```lua
vim.g.qllm_commands = {
  modernize = {
      user_message_template = "I have the following {{language}} code: ```{{filetype}}\n{{text_selection}}```\nModernize the above code. Use current best practices. Only return the code snippet and comments. {{language_instructions}}",
      language_instructions = {
          cpp = "Refactor the code to use trailing return type, and the auto keyword where applicable.",
      },
  }
}
```
The above configuration adds the command `:Que modernize` that attempts to modernize the selected code snippet.

#### Command args

Commands are normally a single value, for example `:Que complete`. You can make commands accept additional arguments by using the `{{command_args}}` macro anywhere in either `user_message_template` or `system_message_template`. For example:

```lua
vim.g.qllm_commands = {
  testwith = {
      user_message_template =
        "Write tests for the following code: ```{{filetype}}\n{{text_selection}}```\n{{command_args}} " ..
        "Only return the code snippet and nothing else."
  }
}
```

After defining this command, any `:Que` command that has `testwith` as its first argument will be handled. For example, `:Que testwith some additional instructions` will be interpreted as `testwith` with `"some additional instructions"`.

#### Language instructions

Some commands have templates that use the `{{language_instructions}}` macro to allow for additional instructions for specific [filetypes](https://neovim.io/doc/user/filetype.html).

```lua
vim.g.qllm_commands_defaults = {
  complete = {
      language_instructions = {
          cpp = "Use trailing return type.",
      },
  }
}
```

The above adds a specific `Use trailing return type.` to the command `complete` for the filetype `cpp`.

#### Templates

| Macro | Description |
|------|-------------|
| `{{filetype}}` | The `filetype` of the current buffer. |
| `{{text_selection}}` | The selected text in the current buffer. |
| `{{language}}` | The name of the programming language in the current buffer. |
| `{{command_args}}` | Everything passed to the command as an argument, joined with spaces. |
| `{{language_instructions}}` | The found value in the `language_instructions` map. |

#### Callback types

| Name      | Description |
|--------------|----------|
| replace_lines | Replaces the current lines with the response. If no text is selected it inserts the response at the cursor. |
| text_popup | Displays the result in a text popup window using Markdown (default). |


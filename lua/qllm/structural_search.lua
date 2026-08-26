---Structural, centrality-ranked code search over qLLM_map.json.
---
---Where a text search reports every line that happens to contain a string, this reports
---the definitions that a term actually names, ordered by how central each one is to the
---call graph. A function called from twenty files outranks a same-named helper called
---from one, and definitions living in test or fixture paths are pushed down.
local M = {}

local CodeExtraction = require("qllm.code_extraction")

---Weights of the three centrality signals, before normalisation.
local CENTRALITY_WEIGHTS = {
    caller_files = 1.0,   -- how widely a definition is used
    caller_count = 0.5,   -- how often
    second_order = 0.35,  -- how important the things that use it are
}

---Match tiers, from an exact hit down to a loose containment.
local MATCH_EXACT = 1.0
local MATCH_EXACT_ICASE = 0.92
local MATCH_TAIL = 0.85
local MATCH_TAIL_ICASE = 0.8
local MATCH_PREFIX = 0.7
local MATCH_SUBSTRING = 0.6
local MATCH_FUZZY_MAX = 0.5
local MATCH_FUZZY_MIN = 0.15

---Kinds are weighted very slightly, so an exactly-named variable still outranks a
---fuzzily-matched function, but a function wins a tie against a variable.
local KIND_WEIGHT = {
    ["function"] = 1.0,
    ["class"] = 1.0,
    ["variable"] = 0.92,
}

---Returns the merged Knowledge Base options with search defaults applied.
---@return table
local function options()
    local kb_opts = vim.g.qllm_kb_opts or {}
    return {
        max_results = kb_opts.scan_max_results or 20,
        max_defs = kb_opts.scan_max_defs or 5,
        centrality_weight = kb_opts.scan_centrality_weight or 1.0,
        test_penalty = kb_opts.scan_test_penalty or 0.5,
        test_patterns = kb_opts.scan_test_patterns or {
            "test", "tests", "spec", "specs", "mock", "mocks",
            "fixture", "fixtures", "example", "examples", "__tests__",
        },
    }
end

---Reports whether a path looks like test, mock or example code.
---Matches whole path segments and the usual filename affixes (`foo_test.go`,
---`foo.spec.js`, `test_foo.py`) so a `src/contest/` directory is not caught by `test`.
---@param path string Project-relative path.
---@param patterns table
---@return boolean
local function is_test_path(path, patterns)
    local lower = path:lower()
    for _, pattern in ipairs(patterns) do
        local escaped = vim.pesc(pattern)
        if lower:find("^" .. escaped .. "/")
            or lower:find("/" .. escaped .. "/")
            or lower:find("[_%.%-]" .. escaped .. "%.")
            or lower:find("/" .. escaped .. "[_%.%-]")
            or lower:find("^" .. escaped .. "[_%.%-]") then
            return true
        end
    end
    return false
end

---Scores how well a definition's name answers the query.
---@param name string
---@param query string
---@return number score Between 0 and 1; 0 means no direct match.
local function match_score(name, query)
    if name == query then return MATCH_EXACT end

    local lower_name, lower_query = name:lower(), query:lower()
    if lower_name == lower_query then return MATCH_EXACT_ICASE end

    -- `popup` should find `Ui.popup`; the tail after a dot or colon is the bare name.
    local tail = name:match("[%.:]([%w_]+)$")
    if tail then
        if tail == query then return MATCH_TAIL end
        if tail:lower() == lower_query then return MATCH_TAIL_ICASE end
    end

    if lower_name:sub(1, #lower_query) == lower_query then return MATCH_PREFIX end
    if lower_name:find(lower_query, 1, true) then return MATCH_SUBSTRING end

    return 0
end

---Indexes the map for lookup by `name@file` signature.
---@param map_data table
---@return table index
local function index_by_signature(map_data)
    local index = {}
    for _, entry in ipairs(map_data) do
        index[entry.name .. "@" .. entry.file] = entry
    end
    return index
end

---Counts the distinct files a definition is referenced from.
---@param entry table
---@return number
local function distinct_caller_files(entry)
    local files = {}
    local count = 0
    for _, caller in ipairs(entry.callers or {}) do
        if not files[caller.file] then
            files[caller.file] = true
            count = count + 1
        end
    end
    return count
end

---Computes raw centrality for every entry, plus the maximum, so scores can be normalised
---against the project rather than against an absolute scale that varies with repo size.
---@param map_data table
---@return table centrality Keyed by `name@file`.
---@return number max_raw
local function compute_centrality(map_data)
    local index = index_by_signature(map_data)

    local caller_files = {}
    for _, entry in ipairs(map_data) do
        caller_files[entry.name .. "@" .. entry.file] = distinct_caller_files(entry)
    end

    local centrality = {}
    local max_raw = 0
    for _, entry in ipairs(map_data) do
        local signature = entry.name .. "@" .. entry.file
        local direct_files = caller_files[signature] or 0
        local direct_count = #(entry.callers or {})

        -- Second order: being called by widely-used code counts for more than being
        -- called by a leaf, which is what separates a core API from a popular utility.
        local second_order = 0
        for _, caller in ipairs(entry.callers or {}) do
            second_order = second_order + (caller_files[caller.name .. "@" .. caller.file] or 0)
        end

        local raw = CENTRALITY_WEIGHTS.caller_files * math.log(1 + direct_files)
            + CENTRALITY_WEIGHTS.caller_count * math.log(1 + direct_count)
            + CENTRALITY_WEIGHTS.second_order * math.log(1 + second_order)

        centrality[signature] = {
            raw = raw,
            caller_files = direct_files,
            caller_count = direct_count,
        }
        if raw > max_raw then max_raw = raw end
    end

    return centrality, max_raw, index
end

---Adds fuzzy-matched candidates when nothing matched by name.
---@param map_data table
---@param query string
---@param scored table Accumulator of results.
---@param limit number
local function add_fuzzy_matches(map_data, query, scored, limit)
    local names = {}
    local seen = {}
    for _, entry in ipairs(map_data) do
        if not seen[entry.name] then
            seen[entry.name] = true
            table.insert(names, entry.name)
        end
    end

    local ok, fuzzy = pcall(vim.fn.matchfuzzy, names, query)
    if not ok or type(fuzzy) ~= "table" or #fuzzy == 0 then return end

    local ranked = {}
    local take = math.min(#fuzzy, limit)
    for rank = 1, take do
        -- Decay from MATCH_FUZZY_MAX down to MATCH_FUZZY_MIN across the taken results.
        local decay = (take > 1) and ((rank - 1) / (take - 1)) or 0
        ranked[fuzzy[rank]] = MATCH_FUZZY_MAX - decay * (MATCH_FUZZY_MAX - MATCH_FUZZY_MIN)
    end

    for _, entry in ipairs(map_data) do
        local score = ranked[entry.name]
        if score then
            table.insert(scored, { entry = entry, match = score, fuzzy = true })
        end
    end
end

---Searches definitions whose bodies reference a symbol that is not itself defined.
---Reads the referencing files, so it only runs when the name search found nothing.
---@param map_data table
---@param query string
---@param root string
---@return table results
local function reference_search(map_data, query, root)
    local file_cache = {}
    local function file_lines(rel_path)
        if not file_cache[rel_path] then
            local abs_path = root .. rel_path
            file_cache[rel_path] = (vim.fn.filereadable(abs_path) == 1)
                and vim.fn.readfile(abs_path) or {}
        end
        return file_cache[rel_path]
    end

    local pattern = "%f[%w_]" .. vim.pesc(query) .. "%f[^%w_]"
    local results = {}
    for _, entry in ipairs(map_data) do
        local lines = file_lines(entry.file)
        local body = {}
        for i = entry.start_line, math.min(entry.end_line, #lines) do
            table.insert(body, lines[i] or "")
        end
        if table.concat(body, "\n"):find(pattern) then
            table.insert(results, entry)
        end
    end
    return results
end

---Runs a structural search over the project map.
---@param query string The term to search for.
---@param root string Project root (with trailing slash).
---@param opts table? { limit, files (list of absolute or project-relative paths), kinds }
---@return table|nil results Ranked results, highest score first.
---@return string|nil error_msg
---@return boolean is_reference True when nothing carries the name and the results are
---        definitions that reference it instead.
function M.search(query, root, opts)
    opts = opts or {}
    local settings = options()
    local limit = opts.limit or settings.max_results

    query = vim.trim(query or "")
    if query == "" then
        return nil, "Structural search needs a term to look for."
    end

    local map_data, err = CodeExtraction.load_map(root)
    if not map_data then
        return nil, err
    end

    -- Optional restriction to an explicit file set (`:Que scan [src/*.lua] term`).
    local allowed = nil
    if opts.files and #opts.files > 0 then
        allowed = {}
        for _, path in ipairs(opts.files) do
            local rel = path
            if rel:sub(1, #root) == root then
                rel = rel:sub(#root + 1)
            end
            allowed[rel] = true
        end
    end

    local candidates = {}
    for _, entry in ipairs(map_data) do
        local included = (not allowed) or allowed[entry.file]
        if included and opts.kinds then
            included = opts.kinds[entry.kind or "function"] == true
        end
        if included then
            table.insert(candidates, entry)
        end
    end

    local centrality, max_raw = compute_centrality(map_data)

    local scored = {}
    for _, entry in ipairs(candidates) do
        local score = match_score(entry.name, query)
        if score > 0 then
            table.insert(scored, { entry = entry, match = score })
        end
    end

    if #scored == 0 then
        add_fuzzy_matches(candidates, query, scored, limit)
    end

    local is_reference_search = false
    if #scored == 0 then
        -- Nothing is named this; report what refers to it instead. This is how symbols
        -- the extractor does not record as definitions still resolve.
        is_reference_search = true
        for _, entry in ipairs(reference_search(candidates, query, root)) do
            table.insert(scored, { entry = entry, match = MATCH_SUBSTRING, reference = true })
        end
    end

    local results = {}
    for _, item in ipairs(scored) do
        local entry = item.entry
        local signature = entry.name .. "@" .. entry.file
        local stats = centrality[signature] or { raw = 0, caller_files = 0, caller_count = 0 }
        local normalized = (max_raw > 0) and (stats.raw / max_raw) or 0

        local penalty = is_test_path(entry.file, settings.test_patterns)
            and settings.test_penalty or 1.0
        local kind_weight = KIND_WEIGHT[entry.kind or "function"] or 1.0

        local score = item.match * (1 + settings.centrality_weight * normalized) * penalty * kind_weight

        table.insert(results, {
            name = entry.name,
            kind = entry.kind or "function",
            file = entry.file,
            start_line = entry.start_line,
            end_line = entry.end_line,
            length = entry.length,
            callers = entry.callers or {},
            calls = entry.calls or {},
            caller_files = stats.caller_files,
            caller_count = stats.caller_count,
            centrality = normalized,
            match = item.match,
            fuzzy = item.fuzzy or false,
            reference = item.reference or false,
            score = score,
        })
    end

    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.caller_files ~= b.caller_files then return a.caller_files > b.caller_files end
        if a.file ~= b.file then return a.file < b.file end
        return a.start_line < b.start_line
    end)

    while #results > limit do
        table.remove(results)
    end

    return results, nil, is_reference_search
end

---Pluralises a count for display.
---@param count number
---@param singular string
---@return string
local function pluralize(count, singular)
    return string.format("%d %s%s", count, singular, count == 1 and "" or "s")
end

---Summarises a result's callers for display, most-connected first.
---@param result table
---@param max_shown number
---@return string
local function caller_summary(result, max_shown)
    if #result.callers == 0 then return "no callers" end

    local names = {}
    for index, caller in ipairs(result.callers) do
        if index > max_shown then break end
        table.insert(names, string.format("%s (%s)", caller.name, vim.fn.fnamemodify(caller.file, ":t")))
    end

    local summary = table.concat(names, ", ")
    local remaining = #result.callers - #names
    if remaining > 0 then
        summary = summary .. string.format(", +%d more", remaining)
    end
    return summary
end

---Formats results as Markdown for the popup.
---@param results table
---@param query string
---@param root string
---@param is_reference boolean?
---@return table lines
function M.format_results(results, query, root, is_reference)
    local lines = {}

    if is_reference then
        table.insert(lines, string.format("# Structural Search: '%s' (references)", query))
        table.insert(lines, "*No definition carries this name; showing what refers to it, most central first.*")
    else
        table.insert(lines, string.format("# Structural Search: '%s'", query))
        table.insert(lines, "*Definitions ranked by name match and call-graph centrality.*")
    end
    table.insert(lines, "")

    if #results == 0 then
        table.insert(lines, "No structural matches found.")
        return lines
    end

    for rank, result in ipairs(results) do
        table.insert(lines, string.format("## %d. %s  *(%s)*%s",
            rank, result.name, result.kind, result.fuzzy and " — fuzzy match" or ""))
        table.insert(lines, string.format("[%s:L%d-L%d](file://%s%s#L%d)",
            result.file, result.start_line, result.end_line,
            root, result.file, result.start_line))
        table.insert(lines, string.format("- **Score**: %.2f  ·  **Used by**: %s across %s  ·  %s",
            result.score,
            pluralize(result.caller_count, "caller"),
            pluralize(result.caller_files, "file"),
            pluralize(result.length, "line")))
        table.insert(lines, string.format("- **Called by**: %s", caller_summary(result, 4)))
        table.insert(lines, "")
    end

    return lines
end

---Builds LLM context from the top results: the real definition bodies, each carrying its
---position in the call graph. This is what replaces grep-style chunks in the scan
---pipeline, so the model receives whole definitions rather than matching lines.
---@param results table
---@param root string
---@param opts table? { max_defs, max_chars }
---@return string context
function M.format_for_llm(results, root, opts)
    opts = opts or {}
    local settings = options()
    local max_defs = opts.max_defs or settings.max_defs
    local max_chars = opts.max_chars or 24000

    local parts = {}
    local total = 0

    for index, result in ipairs(results) do
        if index > max_defs or total >= max_chars then break end

        local abs_path = root .. result.file
        local body = ""
        if vim.fn.filereadable(abs_path) == 1 then
            local file_lines = vim.fn.readfile(abs_path)
            local chunk = {}
            for i = result.start_line, math.min(result.end_line, #file_lines) do
                table.insert(chunk, file_lines[i] or "")
            end
            body = table.concat(chunk, "\n")
        end

        local filetype = vim.filetype.match({ filename = abs_path }) or "text"
        local calls = {}
        for i, call in ipairs(result.calls) do
            if i > 8 then break end
            table.insert(calls, call.name)
        end

        local block = string.format(
            "\n## %s (%s) — %s:L%d-L%d\nUsed by: %s across %s%s\nCalls: %s\n```%s\n%s\n```\n---\n",
            result.name, result.kind, result.file, result.start_line, result.end_line,
            pluralize(result.caller_count, "caller"), pluralize(result.caller_files, "file"),
            (#result.callers > 0) and (" — " .. caller_summary(result, 5)) or "",
            (#calls > 0) and table.concat(calls, ", ") or "none",
            filetype, body)

        table.insert(parts, block)
        total = total + #block
    end

    if #parts == 0 then return "" end
    return "[STRUCTURAL SEARCH RESULTS]\n" .. table.concat(parts, "")
end

return M

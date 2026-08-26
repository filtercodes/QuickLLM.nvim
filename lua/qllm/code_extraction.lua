local M = {}

---Schema version of qLLM_map.json.
---v1: functions only (records without a `kind` field).
---v2: functions, classes/types and module-level variables (records carry `kind`).
M.MAP_SCHEMA = 2

---Node types that represent a type/class-like definition.
---
---Generated rather than enumerated, so a grammar installed later is recognised without
---any change here. Tree-sitter names definition nodes as <what-it-is><how-it-is-declared>,
---and every one of these words is unambiguous: no grammar uses `class` or `trait` for
---anything but a definition. The combination must match the node type exactly — Swift's
---`protocol_function_declaration` is a method inside a protocol, not a protocol.
local CLASS_NODE_TYPES = {}
do
    local subjects = {
        "class", "struct", "interface", "trait", "enum", "record", "protocol",
        "union", "object", "namespace", "module", "impl", "actor", "data",
        "mixin", "annotation", "package",
    }
    local forms = { "_definition", "_declaration", "_item", "_specifier", "_spec" }

    for _, subject in ipairs(subjects) do
        for _, form in ipairs(forms) do
            CLASS_NODE_TYPES[subject .. form] = true
        end
    end

    -- `type` is the one subject that cannot join the rule: grammars use it for type
    -- *expressions* as much as for definitions (`type_specifier` in C is a usage,
    -- `array_type` and `function_type` describe shapes). These four are the definition
    -- spellings, listed explicitly because the name alone cannot distinguish them.
    for _, exact in ipairs({
        "type_definition", "type_declaration", "type_item", "type_alias_declaration",
    }) do
        CLASS_NODE_TYPES[exact] = true
    end
end

---Reports whether a node might declare a module-level variable.
---Only ever asked about direct children of the file root, so scope is guaranteed, and
---being wrong is cheap: target extraction yields nothing for a node that turns out not to
---declare anything, and a declaration co-located with a function or class is dropped as a
---duplicate later. That lets this accept any declaration-shaped node from any grammar
---rather than naming the ones this plugin happens to know.
---@param node_type string
---@return boolean
local function is_variable_declaration_node(node_type)
    local t = node_type:lower()

    local known = {
        variable_declaration = true,    -- lua, js (var)
        lexical_declaration = true,     -- js/ts (const, let)
        assignment_statement = true,    -- lua
        expression_statement = true,    -- python / js wrapper around an assignment
        const_item = true,              -- rust
        static_item = true,             -- rust
        var_declaration = true,         -- go
        const_declaration = true,       -- go
        declaration = true,             -- c / c++
    }
    if known[t] then return true end

    for _, form in ipairs({ "_declaration", "_definition", "_statement", "_item", "_spec" }) do
        if t:sub(-#form) == form then return true end
    end
    return false
end

---Returns the set of literal keywords for a language, derived from its Tree-sitter
---grammar. Keywords are exactly the grammar's anonymous symbols, so the list is
---always complete and correct for whatever parser the user has installed.
---@param lang string? A Tree-sitter language name (not a Neovim filetype).
---@return table keywords Set of keyword -> true (empty when no parser is available).
local grammar_keyword_cache = {}
local grammar_keyword_union = nil
function M.grammar_keywords(lang)
    if not lang or lang == "" then return {} end
    if grammar_keyword_cache[lang] then return grammar_keyword_cache[lang] end

    local keywords = {}
    local ok, info = pcall(vim.treesitter.language.inspect, lang)
    if ok and info and type(info.symbols) == "table" then
        for symbol, named in pairs(info.symbols) do
            -- Anonymous symbols are the grammar's literal tokens; keep the word-shaped ones.
            if named == false and type(symbol) == "string" then
                local word = symbol:match('^"([%a_][%w_]*)"$') or symbol:match("^([%a_][%w_]*)$")
                if word then keywords[word] = true end
            end
        end
    end

    grammar_keyword_cache[lang] = keywords
    return keywords
end

---Union of the keywords of every parser installed on this machine.
---Used only by the regex fallback, which by definition runs when the file's own grammar
---is unavailable. It is an approximation: a function genuinely named after another
---language's keyword (a C `map()` where a Go parser is installed) is skipped. That is
---preferred over admitting `if`/`while` as function names, which would surface as noise
---in both the call graph and the dead-code report.
---@return table keywords Set of keyword -> true.
function M.grammar_keywords_union()
    if grammar_keyword_union then return grammar_keyword_union end

    local union = {}
    local seen_lang = {}
    for _, parser_path in ipairs(vim.api.nvim_get_runtime_file("parser/*.so", true)) do
        local lang = vim.fn.fnamemodify(parser_path, ":t:r")
        if not seen_lang[lang] then
            seen_lang[lang] = true
            for word in pairs(M.grammar_keywords(lang)) do
                union[word] = true
            end
        end
    end

    grammar_keyword_union = union
    return union
end

---Maps Neovim's standard `locals.scm` definition captures onto the kinds recorded in the
---project map. This is a closed vocabulary defined by Neovim (`:h treesitter-locals`),
---not an enumeration of per-grammar node names, so it holds for every language whose
---parser ships a locals query.
local LOCALS_CAPTURE_KIND = {
    ["function"] = "function",
    ["method"] = "function",
    ["macro"] = "function",
    ["type"] = "class",
    ["namespace"] = "class",
    ["enum"] = "class",
    ["constant"] = "variable",
    ["var"] = "variable",
    ["import"] = "import",
}

---Rebuilds a qualified name from a captured identifier. `locals.scm` captures only the
---final identifier, so `function Ui.popup()` arrives as `popup`; the map has always
---recorded such definitions under their dotted path, and callers rely on that.
---@param ident userdata The captured identifier node.
---@param src string
---@return string name
local function qualified_name(ident, src)
    local text = vim.trim(vim.treesitter.get_node_text(ident, src) or "")
    local parent = ident:parent()
    if not parent or text == "" then return text end

    local parent_text = vim.trim(vim.treesitter.get_node_text(parent, src) or "")
    -- A qualified reference is a plain path (no whitespace, no call) ending in this name.
    if #parent_text > #text
        and parent_text:sub(-#text) == text
        and parent_text:match("^[%w_%.:%[%]]+$") then
        return parent_text
    end
    return text
end

---Finds the node that constitutes the whole definition a captured identifier names.
---Climbs out of wrappers that open on the same line, stopping at scope boundaries, which
---turns `popup` into the enclosing `function ... end` and `MAX` into its assignment.
---@param ident userdata
---@param scope_ids table Set of node ids captured as `@local.scope`.
---@return userdata node
local function definition_node_for(ident, scope_ids)
    local node = ident:parent()
    if not node then return ident end

    while true do
        local parent = node:parent()
        if not parent or scope_ids[parent:id()] then break end
        -- Never climb into the file root. Not every grammar captures it as a scope, and
        -- it shares a start row with anything declared on line 1, which would otherwise
        -- swallow the whole file as that declaration's body.
        if not parent:parent() then break end
        local node_row = node:range()
        local parent_row = parent:range()
        if node_row ~= parent_row then break end
        node = parent
    end
    return node
end

---Reports whether a declaration binds a function outright (`wait = { ... }`), as opposed
---to merely mentioning one somewhere in its value (`snd = { WhiteNoise.ar } ! 5`). Only
---the former names a function. Languages where every definition lives inside a block
---(nested JS closures) depend on this to be indexed
---at all, so such bindings are exempt from the module-level restriction.
---@param def_node userdata The resolved definition node.
---@return boolean
local function binds_a_function(def_node)
    local value = nil
    for child in def_node:iter_children() do
        if child:named() then value = child end
    end
    if not value then return false end

    local t = value:type():lower()
    -- Invoking a function is not binding one, and some grammars name their call node
    -- `function_call`, which would otherwise match below.
    if t:find("call") then return false end

    -- Deliberately not matching a bare "block": that is a plain body in most grammars.
    return t:find("function") ~= nil
        or t:find("lambda") ~= nil
        or t:find("closure") ~= nil
        or t:find("arrow") ~= nil
end

---Reads a literal node as a definition name, if it looks like one.
---Handles quoted strings and the symbol/atom notations (`\signal`, `:name`). Anything
---path-shaped, dotted or containing whitespace is rejected, which is what keeps
---`readFile("config.json", cb)` and `app.get("/users", h)` from being read as
---definitions.
---@param node userdata
---@param src string
---@return string? name
local function literal_as_name(node, src)
    -- Grammars wrap literals to differing depths (SuperCollider nests symbol inside
    -- literal), so descend through single-child wrappers before judging the type.
    local function is_literal(t)
        return t:find("string") or t:find("symbol") or t:find("atom")
    end

    for _ = 1, 3 do
        if is_literal(node:type():lower()) then break end
        local only_child = nil
        for child in node:iter_children() do
            if child:named() then
                if only_child then
                    only_child = nil
                    break
                end
                only_child = child
            end
        end
        if not only_child then break end
        node = only_child
    end

    -- It must genuinely be a literal. A variable passed as the first argument
    -- (`table.sort(unused_vars, function() end)`) is identifier-shaped too, and naming
    -- a definition after it would invent one out of an ordinary call.
    if not is_literal(node:type():lower()) then
        return nil
    end

    local text = vim.trim(vim.treesitter.get_node_text(node, src) or "")
    if text == "" then return nil end

    text = text:gsub("^[\"'`]", ""):gsub("[\"'`]$", "")
    text = text:gsub("^\\", ""):gsub("^:", "")

    -- Identifier-shaped only: letters, digits, underscore and dashes.
    if #text >= 3 and text:match("^[%a_][%w_%-]*$") then
        return text
    end
    return nil
end

---Recognises a definition declared through a call idiom: a call whose first argument
---names something and which is handed a function body, as in `SynthDef(\bass, { ... })`,
---`describe("Auth", () => {})` or `Vue.component("widget", { ... })`. No library or
---framework name is involved; the shape of the call is the whole signal.
---Only direct arguments count, so a function buried in an options table (an autocommand
---callback, for instance) does not turn its event name into a definition.
---@param node userdata A call node.
---@param src string
---@param content_lines table
---@param rel_path string
---@return table? definition
local function call_idiom_definition(node, src, content_lines, rel_path)
    local args = {}
    for child in node:iter_children() do
        local ctype = child:type():lower()
        if ctype:find("argument") or ctype:find("parameter") then
            for arg in child:iter_children() do
                if arg:named() then
                    -- Unwrap single-child wrappers
                    local inner = arg
                    local only_child = nil
                    for candidate in arg:iter_children() do
                        if candidate:named() then
                            if only_child then
                                only_child = nil
                                break
                            end
                            only_child = candidate
                        end
                    end
                    if only_child and arg:type():lower():find("argument") then
                        inner = only_child
                    end
                    table.insert(args, inner)
                end
            end
        end
    end

    if #args < 2 then return nil end

    local name = literal_as_name(args[1], src)
    if not name then return nil end

    local has_function_argument = false
    for index = 2, #args do
        local t = args[index]:type():lower()
        if not t:find("call") and (t:find("function") or t:find("lambda")
            or t:find("closure") or t:find("arrow")) then
            has_function_argument = true
            break
        end
    end
    if not has_function_argument then return nil end

    local start_row, _, end_row, _ = node:range()
    local start_line = start_row + 1
    local end_line = end_row + 1
    local body_lines = {}
    for i = start_line, end_line do
        table.insert(body_lines, content_lines[i] or "")
    end

    return {
        name = name,
        kind = "class",
        file = rel_path,
        start_line = start_line,
        end_line = end_line,
        length = end_line - start_line + 1,
        body = table.concat(body_lines, "\n"),
    }
end

---Extracts definitions using the language's own `locals.scm` query.
---Kind classification and module-level scoping both come from the grammar's query file,
---so languages whose node types this plugin has never seen are handled correctly.
---@param tree_root userdata Root node of the tree to walk.
---@param src string Source text.
---@param rel_path string Project-relative path.
---@param lang string Tree-sitter language name.
---@param index_variables boolean Whether module-level variables should be collected.
---@return table definitions
local function extract_definitions_via_locals(tree_root, src, rel_path, lang, index_variables)
    local ok, query = pcall(vim.treesitter.query.get, lang, "locals")
    if not ok or not query then return {} end

    -- Scope nodes first, so nesting depth is known before definitions are classified.
    local scope_ids = {}
    for id, node in query:iter_captures(tree_root, src) do
        if query.captures[id] == "local.scope" then
            scope_ids[node:id()] = true
        end
    end

    local function scope_depth(node)
        local depth = 0
        local current = node:parent()
        while current do
            if scope_ids[current:id()] then depth = depth + 1 end
            current = current:parent()
        end
        return depth
    end

    local definitions = {}
    local src_lines = vim.split(src, "\n", { plain = true })

    for id, node in query:iter_captures(tree_root, src) do
        local capture = query.captures[id]
        local suffix = capture:match("^local%.definition%.(.+)$")
        local kind = suffix and LOCALS_CAPTURE_KIND[suffix]

        -- Parameters, fields and import bindings are deliberately not definitions here:
        -- an import names another module rather than declaring anything in this file.
        if kind and kind ~= "import" then
            local is_variable = (kind == "variable")
            local def_node = definition_node_for(node, scope_ids)

            -- A binding whose value is a function is a named function, whatever its
            -- depth, matching how the map has always treated nested function statements.
            if is_variable and binds_a_function(def_node) then
                is_variable = false
                kind = "function"
            end

            -- Only module-level variables are indexed; functions and types are kept at
            -- any depth.
            if not is_variable or (index_variables and scope_depth(node) <= 1) then
                local start_row, _, end_row, _ = def_node:range()
                local start_line = start_row + 1
                local end_line = end_row + 1
                local name = qualified_name(node, src)

                -- Some grammars capture a receiver (`&self`) as a plain variable.
                -- A parameter is never a definition of this file.
                if def_node:type():find("parameter") then
                    name = ""
                end

                -- A namespace with no body is a file-level marker rather than a
                -- definition: Go's `package main` opens nothing, Ruby's `module X` does.
                if suffix == "namespace" and end_row == start_row then
                    name = ""
                end

                if name ~= "" then
                    local body_lines = {}
                    for i = start_line, end_line do
                        table.insert(body_lines, src_lines[i] or "")
                    end
                    table.insert(definitions, {
                        name = name,
                        kind = kind,
                        file = rel_path,
                        start_line = start_line,
                        end_line = end_line,
                        length = end_line - start_line + 1,
                        body = table.concat(body_lines, "\n"),
                        ident_line = node:range() + 1,
                    })
                end
            end
        end
    end

    return definitions
end

---Merges locals-derived definitions into the node-type derived ones.
---The node-type walk resolves definition ranges well, so it wins on geometry; the
---locals query knows what each definition *is*, so it wins on kind and contributes
---anything the walk missed entirely (Ruby's bare `class`/`module`/`method` nodes).
---@param primary table Definitions from the node-type walk.
---@param from_locals table Definitions from locals.scm.
---@return table merged
local function merge_definitions(primary, from_locals)
    local merged = {}
    for _, d in ipairs(primary) do
        table.insert(merged, d)
    end

    for _, candidate in ipairs(from_locals) do
        local matched = nil
        for _, existing in ipairs(merged) do
            -- Same definition if the captured identifier sits inside an existing range
            -- and they agree on the name (or the name is the unqualified tail of it).
            local ident_line = candidate.ident_line or candidate.start_line
            if ident_line >= existing.start_line and ident_line <= existing.end_line then
                local tail = existing.name:match("[%.:]([%w_]+)$") or existing.name
                if existing.name == candidate.name or tail == candidate.name then
                    matched = existing
                    break
                end
            end
        end

        if matched then
            matched.kind = candidate.kind
        else
            candidate.ident_line = nil
            table.insert(merged, candidate)
        end
    end

    return merged
end

---Resolves the Tree-sitter language for a Neovim filetype, tolerating unknown types.
---@param filetype string?
---@return string? lang
local function lang_for_filetype(filetype)
    if not filetype or filetype == "" then return nil end
    local ok, lang = pcall(vim.treesitter.language.get_lang, filetype)
    if ok and lang and lang ~= "" then return lang end
    return filetype
end

---Node types that terminate a declaration target (the declared name itself).
local TARGET_LEAF_TYPES = {
    identifier = true,
    dot_index_expression = true,
    field_expression = true,
    attribute = true,
    property_identifier = true,
    type_identifier = true,
    field_identifier = true,
}

---Node types worth descending into when hunting for declaration targets.
local TARGET_CONTAINER_TYPES = {
    variable_declaration = true, lexical_declaration = true, variable_declarator = true,
    assignment = true, assignment_statement = true, variable_list = true,
    expression_statement = true, export_statement = true,
    var_spec = true, const_spec = true,
    const_item = true, static_item = true,
    declaration = true, init_declarator = true, pointer_declarator = true, array_declarator = true,
}

---Collects the names declared by a declaration node, straight from the AST.
---Keywords are anonymous nodes in Tree-sitter, so nothing collected here can be one.
---@param node userdata The declaration node.
---@param src string Source text the tree was parsed from.
---@param out table Accumulator for the collected names.
---@param depth number? Recursion guard.
local function collect_declaration_targets(node, src, out, depth)
    depth = depth or 0
    if depth > 6 then return end

    -- A function signature is not a variable, however C-like its declaration looks.
    if node:type() == "function_declarator" then return end

    local function take(list, d)
        for _, n in ipairs(list) do
            if TARGET_LEAF_TYPES[n:type()] then
                local text = vim.trim(vim.treesitter.get_node_text(n, src) or "")
                if text ~= "" then table.insert(out, text) end
            else
                collect_declaration_targets(n, src, out, d)
            end
        end
    end

    -- Grammars expose the declared name through one of these fields (rust, go, js, c).
    for _, field in ipairs({ "name", "left", "declarator" }) do
        local nodes = node:field(field)
        if nodes and nodes[1] then
            take(nodes, depth + 1)
            return
        end
    end

    if TARGET_LEAF_TYPES[node:type()] then
        local text = vim.trim(vim.treesitter.get_node_text(node, src) or "")
        if text ~= "" then table.insert(out, text) end
        return
    end

    -- Otherwise descend, but only through target-bearing children. This is what keeps
    -- the right-hand side of an assignment (lua's expression_list) out of the results.
    for child in node:iter_children() do
        if child:named() then
            local ctype = child:type()
            if TARGET_LEAF_TYPES[ctype] then
                take({ child }, depth + 1)
            elseif TARGET_CONTAINER_TYPES[ctype] then
                collect_declaration_targets(child, src, out, depth + 1)
            end
        end
    end
end

---Extracts declared name(s) from the raw text of a module-level declaration.
---Used only when no parser is available, so it relies on structure rather than on a
---keyword vocabulary: the declared name is the last identifier before the assignment,
---which holds for `local x`, `const x`, `static int x` and `public final Foo x` alike.
---@param text string The declaration source (first line is enough for most languages).
---@return table names A list of declared identifiers (may be empty).
local function parse_declared_names(text)
    local line = vim.trim((text:match("^[^\n]*") or ""))
    if line == "" then return {} end

    -- Everything left of the first assignment (ignoring ==, <=, >=, ~=, !=)
    local eq_start = nil
    local idx = 1
    while idx <= #line do
        local s, e = line:find("=", idx, true)
        if not s then break end
        local prev = line:sub(s - 1, s - 1)
        local next_char = line:sub(s + 1, s + 1)
        if next_char ~= "=" and prev ~= "=" and prev ~= "<" and prev ~= ">" and prev ~= "~" and prev ~= "!" then
            eq_start = s
            break
        end
        idx = e + 1
    end
    -- Require a real assignment: keeps `return M`, `import x` and bare keywords out.
    if not eq_start then return {} end
    local lhs = line:sub(1, eq_start - 1)

    -- A declaration target list contains no calls and no indexing.
    if lhs:find("[%(%[]") then return {} end

    local names = {}
    for part in lhs:gmatch("[^,]+") do
        -- Drop a type annotation (`foo: Bar`) so the target is taken, not the type.
        local target = part:match("^%s*(.-)%s*:[^:]*$") or part
        local candidate = nil
        for word in target:gmatch("[%w_][%w_%.]*") do
            candidate = word
        end
        if candidate then
            candidate = candidate:gsub("%.$", "")
            if candidate ~= "" and not candidate:match("^%d") then
                table.insert(names, candidate)
            end
        end
    end
    return names
end

local function match_pattern(path, pat)
    local rel_path = vim.fn.fnamemodify(path, ":.")
    local filename = vim.fn.fnamemodify(path, ":t")
    
    -- Strip leading slash
    local clean_pat = pat:gsub("^/", "")
    
    -- 1. Extension match (e.g. *.o)
    if clean_pat:match("^%*%.") then
        local ext = clean_pat:sub(3)
        return vim.fn.fnamemodify(path, ":e"):lower() == ext:lower()
    end
    
    -- 2. Directory match (e.g. build/)
    if clean_pat:sub(-1) == "/" then
        local dir = clean_pat:sub(1, -2)
        return rel_path:find("/" .. dir .. "/") or rel_path:find("^" .. dir .. "/")
    end
    
    -- 3. Standard filename match
    if clean_pat == filename then
        return true
    end
    
    -- 4. Simple substring/glob translation
    local lua_pat = clean_pat
        :gsub("%%", "%%%%")
        :gsub("%.", "%%.")
        :gsub("%+", "%%+")
        :gsub("%-", "%%-")
        :gsub("%^", "%%^")
        :gsub("%$", "%%$")
        :gsub("%(", "%%(")
        :gsub("%)", "%%)")
        :gsub("%[", "%%[")
        :gsub("%]", "%%]")
        :gsub("%*", ".*")
        :gsub("%?", ".")
    
    if pat:sub(1, 1) == "/" then
        lua_pat = "^" .. lua_pat
    end
    
    return rel_path:find(lua_pat) ~= nil
end

local function is_binary_file(path)
    local f = io.open(path, "rb")
    if not f then return true end -- Treat unreadable as binary/ignored
    local bytes = f:read(1024)
    f:close()
    if not bytes then return false end
    return bytes:find("%z") ~= nil
end

function M.should_ignore(path, root, ignore_patterns)
    local rel_path = vim.fn.fnamemodify(path, ":.")
    
    -- Exclude standard project context files from the map
    if rel_path == "qLLM.md" or rel_path == "qLLM_map.json" then
        return true
    end

    -- Check default ignores first
    local defaults = {
        "node_modules", "%.git", "venv", "%.venv", "env", "build", "dist",
        "bin", "obj", "target", "__pycache__", "%.pytest_cache", "%.cache", "out"
    }
    for _, d in ipairs(defaults) do
        if rel_path:find("/" .. d .. "/") or rel_path:find("^" .. d .. "/") then
            return true
        end
    end

    -- Ignore binary files based on content signature (null byte check)
    if is_binary_file(path) then
        return true
    end

    -- Check custom patterns loaded from .gitignore
    for _, pat in ipairs(ignore_patterns) do
        if match_pattern(path, pat) then
            return true
        end
    end
    return false
end

---Parses the .gitignore file and returns list of patterns
---@param root string
---@return table ignore_patterns
function M.get_gitignore_patterns(root)
    local path = root .. ".gitignore"
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end
    local lines = vim.fn.readfile(path)
    local patterns = {}
    for _, line in ipairs(lines) do
        line = vim.trim(line)
        if line ~= "" and not line:match("^#") then
            table.insert(patterns, line)
        end
    end
    return patterns
end

---Parses a file using Treesitter and extracts its definitions: functions, classes/types
---and module-level variables. Each record carries a `kind` field naming which it is.
---@param path string
---@param root string
---@param detected_filetype string? Optional pre-detected Neovim filetype.
---@return table definitions List of extracted definition metadata.
function M.extract_functions_from_file(path, root, detected_filetype)
    local rel_path = vim.fn.fnamemodify(path, ":.")
    local content_lines = vim.fn.readfile(path)
    local content = table.concat(content_lines, "\n")
    local filetype = detected_filetype or vim.filetype.match({ filename = path }) or "text"
    local kb_opts = vim.g.qllm_kb_opts or {}
    local index_variables = kb_opts.scan_index_variables ~= false

    local ok, parser = pcall(vim.treesitter.get_string_parser, content, filetype)
    if not ok or not parser then
        -- Fallback to regex-based parser when Treesitter is not available
        local functions = {}
        local ext = vim.fn.fnamemodify(path, ":e"):lower()

        -- Prefer this language's own grammar (the parse may have failed for other
        -- reasons); fall back to every installed grammar when it has none.
        local keywords = M.grammar_keywords(lang_for_filetype(filetype))
        if next(keywords) == nil then
            keywords = M.grammar_keywords_union()
        end

        -- Unified fallback configuration based on regex matching and scope extraction
        local lang_configs = {
            python = {
                name_pattern = "def%s+([%w_]+)",
                parse_body = function(start_line, lines)
                    local base_indent = #lines[start_line]:match("^%s*")
                    local end_line = start_line
                    for k = start_line + 1, #lines do
                        local l = lines[k]
                        if l:match("^%s*$") == nil then
                            local indent = #l:match("^%s*")
                            if indent <= base_indent then
                                break
                            end
                            end_line = k
                        end
                    end
                    return end_line
                end
            },
            lua = {
                name_pattern = "function%s+([%w_.:]+)",
                parse_body = function(start_line, lines)
                    local end_line = nil
                    local count = 1
                    for k = start_line + 1, #lines do
                        local l = lines[k]
                        local clean_line = l:gsub("%-%-.*", "")
                        for word in clean_line:gmatch("[%w_]+") do
                            if word == "function" or word == "do" or word == "then" then
                                count = count + 1
                            elseif word == "end" then
                                count = count - 1
                            end
                        end
                        if count <= 0 then
                            end_line = k
                            break
                        end
                    end
                    return end_line
                end
            },
            braces = {
                -- Fallback configuration for brace-delimited languages (C, C++, Rust, Go, JS, TS, Java, C#)
                parse_name = function(line, file_ext, ft)
                    if file_ext == "rs" or ft == "rust" then
                        return line:match("fn%s+([%w_]+)")
                    elseif file_ext == "go" or ft == "go" then
                        return line:match("func%s+([%w_]+)") or line:match("func%s*%([^)]*%)%s*([%w_]+)")
                    else
                        return line:match("[%w_:]+%s+([%w_:]+)%s*%(")
                    end
                end,
                parse_body = function(start_line, lines)
                    local end_line = nil
                    local brace_count = 0
                    local found_start = false
                    for k = start_line, #lines do
                        local l = lines[k]
                        local clean_line = l:gsub("//.*", ""):gsub("/%*.-%*/", ""):gsub('"[^"]*"', ""):gsub("'[^']*'", "")
                        if not found_start then
                            if clean_line:find("{") then
                                found_start = true
                                brace_count = 1
                                for char in clean_line:gmatch(".") do
                                    if char == "}" then
                                        brace_count = brace_count - 1
                                    end
                                end
                                if brace_count == 0 then
                                    end_line = k
                                    break
                                end
                            end
                        else
                            for char in clean_line:gmatch(".") do
                                if char == "{" then
                                    brace_count = brace_count + 1
                                elseif char == "}" then
                                    brace_count = brace_count - 1
                                end
                            end
                            if brace_count <= 0 then
                                end_line = k
                                break
                            end
                        end
                    end
                    return end_line
                end
            }
        }

        -- Determine language config
        local cfg = nil
        if ext == "py" or filetype == "python" then
            cfg = lang_configs.python
        elseif ext == "lua" or filetype == "lua" then
            cfg = lang_configs.lua
        elseif ext == "rs" or filetype == "rust" or ext == "go" or filetype == "go"
            or ext == "cpp" or ext == "c" or ext == "h" or ext == "hpp" or ext == "js"
            or ext == "ts" or ext == "java" or ext == "cs" or filetype == "cpp"
            or filetype == "c" or filetype == "javascript" or filetype == "typescript"
            or filetype == "tsx" or filetype == "java" or filetype == "cs" then
            cfg = lang_configs.braces
        end

        if cfg then
            -- Type/class declarations recognised without Tree-sitter
            local class_patterns = {
                "^class%s+([%w_]+)",
                "^struct%s+([%w_]+)",
                "^interface%s+([%w_]+)",
                "^trait%s+([%w_]+)",
                "^enum%s+([%w_]+)",
                "^impl%s+([%w_]+)",
                "^type%s+([%w_]+)%s+struct",
                "^public%s+class%s+([%w_]+)",
                "^export%s+class%s+([%w_]+)",
            }

            local idx = 1
            while idx <= #content_lines do
                local line = content_lines[idx]

                -- Class-like declaration (must start at column 0 to stay top-level)
                local class_name = nil
                if cfg ~= lang_configs.lua then
                    for _, pat in ipairs(class_patterns) do
                        class_name = line:match(pat)
                        if class_name then break end
                    end
                end

                if class_name and not keywords[class_name] then
                    local end_line = cfg.parse_body(idx, content_lines) or idx
                    local body_lines = {}
                    for k = idx, end_line do
                        table.insert(body_lines, content_lines[k] or "")
                    end
                    table.insert(functions, {
                        name = class_name,
                        kind = "class",
                        file = rel_path,
                        start_line = idx,
                        end_line = end_line,
                        length = end_line - idx + 1,
                        body = table.concat(body_lines, "\n")
                    })
                    idx = end_line
                else
                    -- Module-level variable: an unindented assignment. Definition lines are
                    -- filtered by parse_declared_names, which rejects any target list
                    -- containing a call, so no keyword patterns are needed here.
                    if index_variables and line:match("^[%w_]") then
                        for _, var_name in ipairs(parse_declared_names(line)) do
                            if not keywords[var_name] then
                                table.insert(functions, {
                                    name = var_name,
                                    kind = "variable",
                                    file = rel_path,
                                    start_line = idx,
                                    end_line = idx,
                                    length = 1,
                                    body = line
                                })
                            end
                        end
                    end

                    local name = nil
                    if cfg.name_pattern then
                        name = line:match(cfg.name_pattern)
                    elseif cfg.parse_name then
                        name = cfg.parse_name(line, ext, filetype)
                    end

                    if name then
                        name = name:match("^([%w_.:]+)") or name
                        if keywords[name] then name = nil end
                    end

                    if name and name ~= "" then
                        local end_line = cfg.parse_body(idx, content_lines)
                        if end_line then
                            local body_lines = {}
                            for k = idx, end_line do
                                table.insert(body_lines, content_lines[k] or "")
                            end
                            table.insert(functions, {
                                name = name,
                                kind = "function",
                                file = rel_path,
                                start_line = idx,
                                end_line = end_line,
                                length = end_line - idx + 1,
                                body = table.concat(body_lines, "\n")
                            })
                            idx = end_line
                        end
                    end
                end
                idx = idx + 1
            end
        end

        return functions
    end

    local functions = {}

    parser:parse()
    -- Parse all parsed sub-trees (including injected languages like inline scripts inside HTML)
    parser:for_each_tree(function(tree, lang_tree)
        local root_node = tree:root()
        if not root_node then return end

        -- Keywords come from the grammar of the tree actually being walked, which may be
        -- an injected language (inline script inside HTML), not the host filetype.
        local tree_lang = (lang_tree and lang_tree.lang and lang_tree:lang()) or lang_for_filetype(filetype)
        local keywords = M.grammar_keywords(tree_lang)

        ---Classifies a node as a definition of a given kind, or nil if it is not one.
        ---@param node_type string
        ---@return string? kind "function" | "class"
        local function classify_node(node_type)
            local t = node_type:lower()
            if t:find("call") or t:find("argument") or t:find("parameter") or t:find("comment") or t:find("string") or t:find("expression") then
                return nil
            end
            -- A declarator is the signature fragment of a definition, not a definition:
            -- counting it would report every C/C++ function two or three times.
            if t:find("declarator") then
                return nil
            end
            -- A node ending in `_type` describes a type rather than defining anything.
            -- Grammars reuse the same words in both roles (`function_type` for a callback
            -- signature, `array_type`, `union_type`), so a signature such as
            -- `let handler: (a: number) => void` would otherwise register as a function.
            if t:sub(-5) == "_type" then
                return nil
            end
            if CLASS_NODE_TYPES[t] then
                return "class"
            end
            if t == "function" or t == "method" or t == "fn" then
                return nil
            end
            if t:find("function")
                or t:find("method")
                or t == "func_literal"
                or t == "function_item"
                or t == "local_function" then
                return "function"
            end
            return nil
        end

        ---Resolves the name of a type/class-like node.
        ---@param node userdata
        ---@param start_line number
        ---@return string? name
        local function get_type_name(node, start_line)
            local function scan_children(target)
                for child in target:iter_children() do
                    local ctype = child:type()
                    if ctype == "type_identifier" or ctype == "identifier" or ctype == "name" or ctype == "constant" then
                        local text = vim.trim(vim.treesitter.get_node_text(child, content) or "")
                        if text ~= "" then
                            return text:match("^([%w_.:]+)") or text
                        end
                    end
                end
                return nil
            end

            local name = scan_children(node)
            if not name then
                -- Go wraps the identifier one level deeper (type_declaration > type_spec)
                for child in node:iter_children() do
                    local ctype = child:type()
                    if ctype == "type_spec" or ctype == "declaration" or ctype == "type_definition" then
                        name = scan_children(child)
                        if name then break end
                    end
                end
            end

            if not name then
                local first_line = (content_lines[start_line] or ""):gsub("^%s*", "")
                name = first_line:match("class%s+([%w_]+)")
                    or first_line:match("struct%s+([%w_]+)")
                    or first_line:match("interface%s+([%w_]+)")
                    or first_line:match("trait%s+([%w_]+)")
                    or first_line:match("enum%s+([%w_]+)")
                    or first_line:match("impl%s+([%w_]+)")
                    or first_line:match("type%s+([%w_]+)")
                    or first_line:match("typedef%s+.*%f[%w_]([%w_]+)%s*;")
            end

            if name then
                local keywords = { ["class"]=true, ["struct"]=true, ["enum"]=true, ["type"]=true,
                    ["interface"]=true, ["trait"]=true, ["impl"]=true, ["typedef"]=true, ["union"]=true }
                if keywords[name] then return nil end
            end
            return name
        end

        local function get_function_name(node)
            -- Try to find child identifier/name
            for child in node:iter_children() do
                local ctype = child:type()
                if ctype == "identifier" or ctype == "name" or ctype == "field_expression" or ctype == "declarator" then
                    local text = vim.trim(vim.treesitter.get_node_text(child, content) or "")
                    if text ~= "" and not text:find("^function") then
                        text = text:match("^([%w_.:]+)") or text
                        return text
                    end
                end
            end
            return nil
        end

        local function traverse(node)
            local ntype = node:type()
            local node_kind = classify_node(ntype)

            -- Calls are not definitions in the grammar, but a call carrying a name and a
            -- body declares one in practice (describe, component registration).
            -- Argument lists are excluded: some grammars name them `parameter_call_list`,
            -- which would otherwise be mistaken for the call itself.
            local lower_type = ntype:lower()
            if lower_type:find("call")
                and not lower_type:find("list")
                and not lower_type:find("argument")
                and not lower_type:find("parameter") then
                local idiom = call_idiom_definition(node, content, content_lines, rel_path)
                if idiom and not keywords[idiom.name] then
                    table.insert(functions, idiom)
                end
            end

            if node_kind == "class" then
                local start_row, _, end_row, _ = node:range()
                local start_line = start_row + 1
                local end_line = end_row + 1
                local name = get_type_name(node, start_line)

                if name and name ~= "" then
                    local body_lines = {}
                    for idx = start_line, end_line do
                        table.insert(body_lines, content_lines[idx] or "")
                    end
                    table.insert(functions, {
                        name = name,
                        kind = "class",
                        file = rel_path,
                        start_line = start_line,
                        end_line = end_line,
                        length = end_line - start_line + 1,
                        body = table.concat(body_lines, "\n")
                    })
                end
            elseif node_kind == "function" then
                local start_row, _, end_row, _ = node:range()
                local start_line = start_row + 1
                local end_line = end_row + 1
                local length = end_line - start_line + 1

                local name = get_function_name(node)
                if not name then
                    -- First line regex fallback
                    local first_line = content_lines[start_line] or ""
                    first_line = first_line:gsub("^%s*", "")
                    name = first_line:match("function%s+([%w_.:]+)")
                        or first_line:match("def%s+([%w_]+)")
                        or first_line:match("func%s+([%w_]+)")
                        or first_line:match("fn%s+([%w_]+)")
                        or first_line:match("[%w_:]+%s+([%w_:]+)%s*%(")
                end

                -- Clean name if matched. The first-line regexes above can return a bare
                -- keyword, so reject anything the grammar itself declares to be one.
                if name then
                    name = name:match("^([%w_.:]+)") or name
                    -- Separators are allowed inside a qualified name but never at its end,
                    -- where they are punctuation the pattern happened to absorb.
                    name = name:gsub("[%.:]+$", "")
                    if name == "" or keywords[name] then
                        name = nil
                    end
                end

                if name and name ~= "" then
                    -- Get body text
                    local body_lines = {}
                    for idx = start_line, end_line do
                        table.insert(body_lines, content_lines[idx] or "")
                    end
                    table.insert(functions, {
                        name = name,
                        kind = "function",
                        file = rel_path,
                        start_line = start_line,
                        end_line = end_line,
                        length = length,
                        body = table.concat(body_lines, "\n")
                    })
                end
            end

            for child in node:iter_children() do
                traverse(child)
            end
        end

        traverse(root_node)

        -- Module-level variables: only direct children of the file root are inspected,
        -- so declarations nested inside functions or classes are never picked up.
        -- This is the fallback for languages without a locals query; anything it misses
        -- (or mis-kinds) is corrected by the locals pass below.
        if index_variables then
            for child in root_node:iter_children() do
                -- A node the walk already recognised as a function or a type is that
                -- definition, not a variable binding of the same name.
                if is_variable_declaration_node(child:type())
                    and classify_node(child:type()) == nil then
                    local start_row, _, end_row, _ = child:range()
                    local start_line = start_row + 1
                    local end_line = end_row + 1
                    local decl_text = vim.treesitter.get_node_text(child, content) or ""

                    -- Names come from the AST itself, so a keyword can never be collected.
                    local targets = {}
                    collect_declaration_targets(child, content, targets)
                    if #targets == 0 and decl_text:find("=") then
                        targets = parse_declared_names(decl_text)
                    end

                    for _, name in ipairs(targets) do
                        if not keywords[name] then
                            table.insert(functions, {
                                name = name,
                                kind = "variable",
                                file = rel_path,
                                start_line = start_line,
                                end_line = end_line,
                                length = end_line - start_line + 1,
                                body = decl_text
                            })
                        end
                    end
                end
            end
        end

        -- Ask the grammar's own locals query what these definitions are. It corrects the
        -- kind of anything the node-type walk guessed at, and supplies definitions whose
        -- node types this plugin has never seen (Ruby's bare `class`/`module`/`method`).
        local from_locals = extract_definitions_via_locals(
            root_node, content, rel_path, tree_lang, index_variables)
        if #from_locals > 0 then
            functions = merge_definitions(functions, from_locals)
        end
    end)

    return functions
end

---Builds a lookup of the project's own modules, keyed by every path suffix a module
---reference could plausibly use. `lua/qllm/queue.lua` is reachable as `queue`,
---`qllm/queue` and `lua/qllm/queue`, whichever separator style the language prefers.
---@param file_paths table List of project-relative source paths.
---@return table suffixes Set of module path -> true.
local function build_module_suffixes(file_paths)
    local suffixes = {}
    for _, rel_path in ipairs(file_paths) do
        local without_ext = rel_path:gsub("%.[%w_]+$", "")
        local segments = {}
        for segment in without_ext:gmatch("[^/]+") do
            table.insert(segments, segment)
        end
        for start_idx = 1, #segments do
            local parts = {}
            for i = start_idx, #segments do
                table.insert(parts, segments[i])
            end
            suffixes[table.concat(parts, "/")] = true
        end
    end
    return suffixes
end

---Reports whether a declaration merely binds another project module to a local name
---(`local Queue = require("qllm.queue")`). Detected structurally: the declaration makes
---a call, and one of its string arguments resolves to a file that exists in this
---project. No import function needs to be named for this to work in any language.
---@param body string The declaration source.
---@param module_suffixes table Set produced by build_module_suffixes.
---@return boolean
local function is_module_alias(body, module_suffixes)
    if not body:find("[%w_.:]%s*%(") then return false end

    for literal in body:gmatch("['\"]([^'\"]+)['\"]") do
        local normalized = literal:gsub("^%./", ""):gsub("[%.\\]", "/"):gsub("/+$", "")
        if module_suffixes[normalized] then
            return true
        end
    end
    return false
end

---Drops module-level variables that would pollute the graph.
---Short base names collide with ordinary identifiers during weaving, and a name declared
---at module level across most of the project (the ubiquitous `local M = {}`) carries no
---structural signal. Import aliases describe another module rather than defining
---anything. Variables sharing a location with a function or class are the same
---definition seen twice (`M.handler = function() ... end`) and are dropped as duplicates.
---@param definitions table All extracted definitions.
---@param file_paths table List of project-relative source paths.
---@return table kept
function M.filter_noisy_variables(definitions, file_paths)
    file_paths = file_paths or {}
    local module_suffixes = build_module_suffixes(file_paths)
    local files_per_name = {}
    local occupied = {}

    local defined_as_symbol = {}
    for _, d in ipairs(definitions) do
        if d.kind == "variable" then
            if not files_per_name[d.name] then files_per_name[d.name] = {} end
            files_per_name[d.name][d.file] = true
        else
            occupied[d.file .. ":" .. d.start_line] = true
            -- A forward declaration (`local render` above `function render()`) names a
            -- definition that appears later in the same file, not a separate variable.
            defined_as_symbol[d.file .. ":" .. d.name] = true
        end
    end

    local ubiquitous = {}
    local threshold = math.max(3, math.ceil(#file_paths * 0.4))
    for name, files in pairs(files_per_name) do
        local count = 0
        for _ in pairs(files) do count = count + 1 end
        if count >= threshold then
            ubiquitous[name] = true
        end
    end

    -- A forward declaration (`int compute(int);` above the real body) is captured as a
    -- definition by some locals queries. Where a name is declared twice in one file and
    -- one of the two has no body to speak of, the bodiless one is the declaration.
    local widest = {}
    for _, d in ipairs(definitions) do
        local key = d.file .. ":" .. d.name .. ":" .. (d.kind or "function")
        local current = widest[key]
        if not current or d.length > current then
            widest[key] = d.length
        end
    end

    local kept = {}
    local seen_exact = {}
    for _, d in ipairs(definitions) do
        local drop = false
        local key = d.file .. ":" .. d.name .. ":" .. (d.kind or "function")
        if d.length == 1 and (widest[key] or 1) > 1 then
            drop = true
        end

        -- Two passes can resolve the same definition to the same range; keep one.
        local exact_key = key .. ":" .. d.start_line .. ":" .. d.end_line
        if seen_exact[exact_key] then
            drop = true
        end
        seen_exact[exact_key] = true

        if not drop and d.kind == "variable" then
            local base = d.name:match("[.:]([%w_]+)$") or d.name
            drop = #base < 3
                or ubiquitous[d.name] ~= nil
                or occupied[d.file .. ":" .. d.start_line] ~= nil
                or defined_as_symbol[d.file .. ":" .. d.name] ~= nil
                or is_module_alias(d.body or "", module_suffixes)
        end
        if not drop then
            table.insert(kept, d)
        end
    end

    return kept
end

---Builds the project AST call graph and saves it as qLLM_map.json.
---@param root string
function M.build_and_save_call_graph(root)
    local source_files = {}
    local tokei_executable = vim.fn.executable("tokei") == 1

    if tokei_executable then
        -- Run tokei on the root directory to find all code files and detect their languages.
        local cmd = string.format("tokei -f -o json %s", vim.fn.shellescape(root))
        local raw_json = vim.fn.system(cmd)
        local ok, decoded = pcall(vim.json.decode, raw_json)

        if ok and decoded then
            -- Parse each language key except "Total"
            for lang_name, lang_data in pairs(decoded) do
                if lang_name ~= "Total" and type(lang_data) == "table" and lang_data.reports then
                    for _, report in ipairs(lang_data.reports) do
                        if report.name and report.stats and (report.stats.code or 0) > 0 then
                            -- Tokei returns paths relative to root or execution dir. Resolve it properly.
                            local path = report.name
                            if path:sub(1, 2) == "./" then
                                path = path:sub(3)
                            end
                            local abs_path = path
                            if not (path:sub(1, 1) == "/" or path:match("^%a:")) then
                                abs_path = root .. path
                            end
                            abs_path = vim.fn.fnamemodify(abs_path, ":p")

                            if vim.fn.filereadable(abs_path) == 1 then
                                -- Dynamically match filetype using Neovim's built-in filetype database.
                                -- If Neovim doesn't recognize it, fall back to lowercase of tokei's language name.
                                local filetype = vim.filetype.match({ filename = abs_path }) or string.lower(lang_name)
                                table.insert(source_files, {
                                    path = abs_path,
                                    filetype = filetype
                                })
                            end
                        end
                    end
                end
            end
        else
            tokei_executable = false -- Fall back to native scanner if decode failed
        end
    end

    if not tokei_executable then
        -- Fallback to native Lua globbing and gitignore parsing
        local gitignore_patterns = M.get_gitignore_patterns(root)
        local all_files = vim.fn.globpath(root, "**", true, true)
        for _, file in ipairs(all_files) do
            if vim.fn.filereadable(file) == 1 and not M.should_ignore(file, root, gitignore_patterns) then
                table.insert(source_files, {
                    path = file,
                    filetype = nil -- Will match dynamically
                })
            end
        end
    end

    -- Extract definitions (functions, classes/types and module-level variables)
    local definitions = {}
    local source_paths = {}
    for _, file_info in ipairs(source_files) do
        table.insert(source_paths, vim.fn.fnamemodify(file_info.path, ":."))
        local file_defs = M.extract_functions_from_file(file_info.path, root, file_info.filetype)
        for _, d in ipairs(file_defs) do
            table.insert(definitions, d)
        end
    end

    -- Universal Ctags recognises far more languages than there are parsers installed, so
    -- it backfills whatever the Tree-sitter passes could not reach. Absent, the map is
    -- exactly what the grammars produced.
    local ctags_defs = M.extract_definitions_via_ctags(root)
    if #ctags_defs > 0 then
        local merged, added = M.merge_ctags_definitions(definitions, ctags_defs)
        definitions = merged
        if added > 0 then
            vim.notify(string.format("Project map: ctags added %d definition(s) beyond Tree-sitter.", added),
                vim.log.levels.INFO)
        end
    end

    definitions = M.filter_noisy_variables(definitions, source_paths)

    local name_to_defs = {}
    for _, d in ipairs(definitions) do
        if not name_to_defs[d.name] then
            name_to_defs[d.name] = {}
        end
        table.insert(name_to_defs[d.name], d)
    end

    -- Weave caller and callee connections
    for _, d in ipairs(definitions) do
        d.calls = {}
        d.callers = {}
        d._call_seen = {}
        d._caller_seen = {}
    end

    -- Index name groups by base name. A word-boundary search for a base name succeeds
    -- exactly when that base name is one of the body's whole-word tokens, so the tokens
    -- can be looked up directly instead of running a pattern search per (body, name) pair.
    local base_index = {}
    for name, defs in pairs(name_to_defs) do
        local base = name:match("[.:]([%w_]+)$") or name
        if not base_index[base] then
            base_index[base] = {}
        end
        table.insert(base_index[base], defs)
    end

    for _, f in ipairs(definitions) do
        local seen_token = {}
        for token in f.body:gmatch("[%w_]+") do
            if not seen_token[token] then
                seen_token[token] = true
                local groups = base_index[token]
                if groups then
                    for _, defs in ipairs(groups) do
                        -- Skip the group containing this definition (self / recursion)
                        local is_self = false
                        for _, def in ipairs(defs) do
                            if def == f then
                                is_self = true
                                break
                            end
                        end

                        if not is_self then
                            for _, def in ipairs(defs) do
                                local call_key = def.name .. "@" .. def.file
                                if not f._call_seen[call_key] then
                                    f._call_seen[call_key] = true
                                    table.insert(f.calls, { name = def.name, file = def.file })
                                end

                                local caller_key = f.name .. "@" .. f.file
                                if not def._caller_seen[caller_key] then
                                    def._caller_seen[caller_key] = true
                                    table.insert(def.callers, { name = f.name, file = f.file })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Prepare serializable representation without bodies
    local function by_file_then_name(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.name < b.name
    end

    local serializable = {}
    for _, d in ipairs(definitions) do
        -- Stable ordering keeps re-indexing from churning the whole file
        table.sort(d.calls, by_file_then_name)
        table.sort(d.callers, by_file_then_name)
        table.insert(serializable, {
            name = d.name,
            kind = d.kind or "function",
            file = d.file,
            start_line = d.start_line,
            end_line = d.end_line,
            length = d.length,
            calls = d.calls,
            callers = d.callers
        })
    end

    local json_path = root .. "qLLM_map.json"
    local f_json = io.open(json_path, "w")
    if f_json then
        f_json:write(vim.json.encode(serializable))
        f_json:close()
        vim.notify("Project call graph saved to " .. json_path, vim.log.levels.INFO)
    else
        vim.notify("Error: Could not write call graph to " .. json_path, vim.log.levels.ERROR)
    end
end

---Kinds that name something ctags found but that are not definitions in this project:
---forward declarations, and bindings that point at another file.
local CTAGS_SKIP_KINDS = {
    prototype = true, import = true, include = true, header = true,
    file = true, ["local"] = true, parameter = true, label = true,
}

---Maps a ctags kind name onto the three kinds the project map records.
---ctags uses a finite, documented vocabulary shared across its parsers
---(`ctags --list-kinds-full=all`), so unlike Tree-sitter node types — which every grammar
---invents independently — these map by word family. Order matters: the narrower entries
---come first, so `enumerator` is read as an enum member rather than as an enum.
local CTAGS_KIND_FAMILIES = {
    { "enumerator", "variable" },
    { "enumconstant", "variable" },
    { "func", "function" },
    { "method", "function" },
    { "subroutine", "function" },
    { "procedure", "function" },
    { "macro", "function" },
    { "singleton", "function" },
    { "class", "class" },
    { "struct", "class" },
    { "interface", "class" },
    { "trait", "class" },
    { "protocol", "class" },
    { "record", "class" },
    { "union", "class" },
    { "enum", "class" },
    { "typedef", "class" },
    { "namespace", "class" },
    { "module", "class" },
    { "package", "class" },
    { "object", "class" },
    { "type", "class" },
    { "const", "variable" },
    { "var", "variable" },
    { "field", "variable" },
    { "property", "variable" },
    { "member", "variable" },
}

---Kinds whose meaning differs between parsers: ctags calls a Python method and a C struct
---field both `member`. They are told apart by extent — something with a body spanning
---several lines is callable, a one-line declaration holds a value.
local CTAGS_AMBIGUOUS_KINDS = {
    member = true,
    property = true,
}

---Translates a ctags kind into one of the map's kinds.
---@param ctags_kind string?
---@param span number? Lines the definition covers; disambiguates kinds whose meaning
---       differs between parsers.
---@param callable boolean? True when the declaration takes a parameter list, which
---       settles the one-line cases the span alone cannot.
---@return string? kind nil when the tag should not be recorded at all.
function M.ctags_kind_to_map_kind(ctags_kind, span, callable)
    if not ctags_kind or ctags_kind == "" then return nil end
    local lower = ctags_kind:lower()
    if CTAGS_SKIP_KINDS[lower] then return nil end

    if CTAGS_AMBIGUOUS_KINDS[lower] then
        if callable then return "function" end
        return ((span or 1) > 1) and "function" or "variable"
    end

    for _, entry in ipairs(CTAGS_KIND_FAMILIES) do
        if lower:find(entry[1], 1, true) then
            return entry[2]
        end
    end

    -- An unrecognised kind still names a definition worth finding. "class" is the
    -- neutral bucket for a named entity that is neither callable nor a plain value.
    return "class"
end

---Reports whether Universal Ctags is available.
---The `ctags` on a stock macOS is an unrelated BSD tool that shares the name and supports
---none of these options, so the banner is checked rather than the binary's presence.
---@return boolean
local ctags_probe = nil
function M.ctags_available()
    if ctags_probe ~= nil then return ctags_probe end

    local kb_opts = vim.g.qllm_kb_opts or {}
    if kb_opts.scan_use_ctags == false then
        ctags_probe = false
        return false
    end

    if vim.fn.executable("ctags") ~= 1 then
        ctags_probe = false
        return false
    end

    local banner = vim.fn.system("ctags --version 2>&1")
    ctags_probe = (banner:find("Universal Ctags") ~= nil)
    return ctags_probe
end

---Extracts definitions for the whole project with Universal Ctags.
---This is the coverage backstop: it recognises far more languages than there are
---Tree-sitter parsers installed, so files no grammar can parse still contribute
---definitions to the map.
---@param root string
---@return table definitions
function M.extract_definitions_via_ctags(root)
    if not M.ctags_available() then return {} end

    local excludes = {
        "node_modules", ".git", "venv", ".venv", "build", "dist", "bin", "obj",
        "target", "__pycache__", ".cache", "out",
    }
    local exclude_args = {}
    for _, dir in ipairs(excludes) do
        table.insert(exclude_args, "--exclude=" .. vim.fn.shellescape(dir))
    end

    -- `-f -` writes to stdout; `--fields=+ne` adds the end line and the kind name.
    local cmd = string.format(
        "ctags -R --output-format=json --fields=+ne --sort=no %s -f - %s 2>/dev/null",
        table.concat(exclude_args, " "), vim.fn.shellescape(root))

    local output = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 and #output == 0 then return {} end

    return M.parse_ctags_output(output, root)
end

---Parses Universal Ctags JSON Lines output into definition records.
---Kept separate from the command so the mapping can be exercised without the binary.
---@param lines table Raw output lines.
---@param root string Project root, with trailing slash.
---@return table definitions
function M.parse_ctags_output(lines, root)
    local definitions = {}
    local file_cache = {}

    local function file_lines(abs_path)
        if file_cache[abs_path] == nil then
            file_cache[abs_path] = (vim.fn.filereadable(abs_path) == 1)
                and vim.fn.readfile(abs_path) or false
        end
        return file_cache[abs_path] or nil
    end

    for _, line in ipairs(lines) do
        local ok, tag = pcall(vim.json.decode, line)
        if ok and type(tag) == "table" and tag._type == "tag" and tag.name and tag.path then
            local start_line = tonumber(tag.line)

            if start_line then
                local abs_path = tag.path
                if not (abs_path:sub(1, 1) == "/" or abs_path:match("^%a:")) then
                    abs_path = root .. abs_path
                end
                abs_path = vim.fn.fnamemodify(abs_path, ":p")
                local rel_path = vim.fn.fnamemodify(abs_path, ":.")

                -- Not every ctags parser reports an end line; a definition of unknown
                -- extent is recorded as its own single line rather than dropped.
                local end_line = tonumber(tag["end"]) or start_line
                if end_line < start_line then end_line = start_line end

                local body = tag.name
                local content = file_lines(abs_path)
                if content then
                    local chunk = {}
                    for i = start_line, math.min(end_line, #content) do
                        table.insert(chunk, content[i] or "")
                    end
                    if #chunk > 0 then body = table.concat(chunk, "\n") end
                end

                -- The declaration taking a parameter list settles the ambiguous kinds
                -- that a one-line span cannot.
                local callable = body:find(vim.pesc(tag.name) .. "%s*%(") ~= nil
                local kind = M.ctags_kind_to_map_kind(tag.kind, end_line - start_line + 1, callable)
                if kind then
                    -- ctags reports a member's own name; qualify it the way the map does.
                    local name = tag.name
                    if tag.scope and tag.scope ~= "" and tag.scopeKind ~= "file" then
                        name = tag.scope .. "." .. tag.name
                    end

                    table.insert(definitions, {
                        name = name,
                        kind = kind,
                        file = rel_path,
                        start_line = start_line,
                        end_line = end_line,
                        length = end_line - start_line + 1,
                        body = body,
                    })
                end
            end
        end
    end

    return definitions
end

---Adds ctags definitions that the Tree-sitter passes did not already find.
---Tree-sitter wins wherever it produced something: its ranges are exact and its output is
---the behaviour verified across the test languages. ctags fills the gaps — whole files
---no installed grammar can parse, and definitions whose node types nothing recognised.
---@param primary table Definitions from the Tree-sitter passes.
---@param from_ctags table
---@return table merged
---@return number added
function M.merge_ctags_definitions(primary, from_ctags)
    local by_file = {}
    for _, d in ipairs(primary) do
        by_file[d.file] = by_file[d.file] or {}
        table.insert(by_file[d.file], d)
    end

    local merged = {}
    for _, d in ipairs(primary) do
        table.insert(merged, d)
    end

    local added = 0
    for _, candidate in ipairs(from_ctags) do
        local existing = by_file[candidate.file] or {}
        local duplicate = false

        for _, d in ipairs(existing) do
            -- Same definition if the names agree (qualified or bare) and the ranges touch.
            local same_name = d.name == candidate.name
                or (d.name:match("[%.:]([%w_]+)$") or d.name) == candidate.name
                or (candidate.name:match("[%.:]([%w_]+)$") or candidate.name) == d.name
            if same_name and candidate.start_line <= d.end_line and candidate.end_line >= d.start_line then
                duplicate = true
                break
            end
        end

        if not duplicate then
            table.insert(merged, candidate)
            added = added + 1
        end
    end

    return merged, added
end

---Loads and decodes qLLM_map.json, caching by modification time so repeated queries in
---one session do not re-read and re-decode the whole map.
---@param root string The project root path.
---@return table|nil map_data
---@return string|nil error_msg
local map_cache = { path = nil, mtime = nil, data = nil }
function M.load_map(root)
    local map_path = root .. "qLLM_map.json"
    if vim.fn.filereadable(map_path) ~= 1 then
        return nil, "Project call graph not initialized. Please run :Que init first."
    end

    local stat = vim.loop.fs_stat(map_path)
    local mtime = stat and stat.mtime and string.format("%d.%d", stat.mtime.sec, stat.mtime.nsec or 0)
    if map_cache.path == map_path and map_cache.mtime == mtime and map_cache.data then
        return map_cache.data
    end

    local json_content = table.concat(vim.fn.readfile(map_path), "\n")
    local ok, map_data = pcall(vim.json.decode, json_content)
    if not ok or not map_data then
        return nil, "Error reading call graph metadata."
    end

    map_cache = { path = map_path, mtime = mtime, data = map_data }
    return map_data
end

---Queries the call tree or variable reference tree structure for a given query.
---@param query string The function or variable name to query.
---@param root string The project root path.
---@return table|nil output_lines The list of formatted Markdown lines, or nil if an error occurs.
---@return string|nil error_msg An error message if something fails.
function M.query_call_tree(query, root)
    local map_data, load_err = M.load_map(root)
    if not map_data then
        return nil, load_err
    end

    local functions_by_name = {}
    local functions_by_signature = {}
    for _, f in ipairs(map_data) do
        if not functions_by_name[f.name] then
            functions_by_name[f.name] = {}
        end
        table.insert(functions_by_name[f.name], f)
        functions_by_signature[f.name .. "@" .. f.file] = f
    end

    local output_lines = {}

    local function traverse_downward(func_sig, path_visited, global_visited, lines, prefix)
        local f = functions_by_signature[func_sig]
        if not f or not f.calls then return end
        for i, call in ipairs(f.calls) do
            local is_last = (i == #f.calls)
            local branch = is_last and "└─ " or "├─ "
            local call_sig = call.name .. "@" .. call.file
            if path_visited[call_sig] then
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s) (cycle)", call.name, call.file))
            elseif global_visited[call_sig] then
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s) (already shown)", call.name, call.file))
            else
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s)", call.name, call.file))
                path_visited[call_sig] = true
                global_visited[call_sig] = true
                traverse_downward(call_sig, path_visited, global_visited, lines, prefix .. (is_last and "   " or "│  "))
                path_visited[call_sig] = nil
            end
        end
    end

    local function traverse_upward(func_sig, path_visited, global_visited, lines, prefix)
        local f = functions_by_signature[func_sig]
        if not f or not f.callers then return end
        for i, caller in ipairs(f.callers) do
            local is_last = (i == #f.callers)
            local branch = is_last and "└─ " or "├─ "
            local caller_sig = caller.name .. "@" .. caller.file
            if path_visited[caller_sig] then
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s) (cycle)", caller.name, caller.file))
            elseif global_visited[caller_sig] then
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s) (already shown)", caller.name, caller.file))
            else
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s)", caller.name, caller.file))
                path_visited[caller_sig] = true
                global_visited[caller_sig] = true
                traverse_upward(caller_sig, path_visited, global_visited, lines, prefix .. (is_last and "   " or "│  "))
                path_visited[caller_sig] = nil
            end
        end
    end

    local matched_funcs = functions_by_name[query]
    local matched_name = nil
    local alt_matches = {}

    if matched_funcs then
        matched_name = query
    else
        -- Try suffix match first
        for name, funcs in pairs(functions_by_name) do
            if name:match("[.:]" .. query .. "$") then
                matched_funcs = funcs
                matched_name = name
                break
            end
        end

        -- Try fuzzy matching if still not matched
        if not matched_funcs then
            local function_names = {}
            for name, _ in pairs(functions_by_name) do
                table.insert(function_names, name)
            end
            local fuzzy = vim.fn.matchfuzzy(function_names, query)
            if #fuzzy > 0 then
                matched_name = fuzzy[1]
                matched_funcs = functions_by_name[matched_name]
                for idx = 2, math.min(#fuzzy, 5) do
                    table.insert(alt_matches, fuzzy[idx])
                end
            end
        end
    end

    if matched_funcs then
        if matched_name == query then
            table.insert(output_lines, string.format("# Call Tree for '%s'", query))
        else
            table.insert(output_lines, string.format("# Call Tree for '%s' (fuzzy matched to '%s')", query, matched_name))
        end
        if #alt_matches > 0 then
            table.insert(output_lines, string.format("*(alternative matches: %s)*", table.concat(alt_matches, ", ")))
        end
        table.insert(output_lines, "")
        for _, f in ipairs(matched_funcs) do
            table.insert(output_lines, string.format("### Defined in: [%s](file://%s#L%d)", f.file, root .. f.file, f.start_line))
            table.insert(output_lines, string.format("- **Kind**: %s", f.kind or "function"))
            table.insert(output_lines, string.format("- **Range**: Lines %d-%d (length: %d lines)", f.start_line, f.end_line, f.length))
            table.insert(output_lines, "")

            -- Upward / Callers
            table.insert(output_lines, "▲ CALLERS (Upward callers):")
            local path_visited = {}
            local global_visited_up = {}
            local sig = f.name .. "@" .. f.file
            path_visited[sig] = true
            global_visited_up[sig] = true
            local caller_lines = {}
            traverse_upward(sig, path_visited, global_visited_up, caller_lines, "  ")
            if #caller_lines == 0 then
                table.insert(output_lines, "  └─ None")
            else
                for _, line in ipairs(caller_lines) do
                    table.insert(output_lines, line)
                end
            end
            table.insert(output_lines, "")

            -- Downward / Callees
            table.insert(output_lines, "▼ CALLEES (Downward calls):")
            path_visited = {}
            local global_visited_down = {}
            path_visited[sig] = true
            global_visited_down[sig] = true
            local callee_lines = {}
            traverse_downward(sig, path_visited, global_visited_down, callee_lines, "  ")
            if #callee_lines == 0 then
                table.insert(output_lines, "  └─ None")
            else
                for _, line in ipairs(callee_lines) do
                    table.insert(output_lines, line)
                end
            end
            table.insert(output_lines, "")
            table.insert(output_lines, string.rep("─", 50))
            table.insert(output_lines, "")
        end
    else
        -- Scan file bodies for references representing variable/symbol usage
        local file_cache = {}
        local function get_file_lines(filepath)
            if not file_cache[filepath] then
                local abs_path = root .. filepath
                if vim.fn.filereadable(abs_path) == 1 then
                    file_cache[filepath] = vim.fn.readfile(abs_path)
                else
                    file_cache[filepath] = {}
                end
            end
            return file_cache[filepath]
        end

        local references = {}
        local pattern = "%f[%w_]" .. vim.pesc(query) .. "%f[^%w_]"
        for _, f in ipairs(map_data) do
            local file_lines = get_file_lines(f.file)
            local body_lines = {}
            for idx = f.start_line, math.min(f.end_line, #file_lines) do
                table.insert(body_lines, file_lines[idx] or "")
            end
            local body_text = table.concat(body_lines, "\n")
            if body_text:find(pattern) then
                table.insert(references, f)
            end
        end

        table.insert(output_lines, string.format("# Reference Tree for Symbol '%s'", query))
        table.insert(output_lines, "")
        table.insert(output_lines, "The symbol was not found as a function definition. Showing referencing functions:")
        table.insert(output_lines, "")

        if #references == 0 then
            table.insert(output_lines, "  └─ No references found in project functions.")
        else
            for i, ref in ipairs(references) do
                local is_last = (i == #references)
                local branch = is_last and "└─ " or "├─ "
                table.insert(output_lines, string.format("  %s[%s] (%s:L%d-L%d, length: %d lines)", branch, ref.name, ref.file, ref.start_line, ref.end_line, ref.length))
            end
        end
    end

    return output_lines
end

---Helper to detect the syntactic style of a file (c, javascript, lua) using filetype and structural heuristics.
local function detect_language_style(filetype, content)
    local c_family = {
        c = true, cpp = true, objc = true, objcpp = true, cuda = true,
        metal = true, glsl = true, hlsl = true, java = true, cs = true,
        rust = true, go = true, swift = true
    }
    local js_family = {
        javascript = true, typescript = true, javascriptreact = true, typescriptreact = true,
        vue = true, svelte = true
    }
    if c_family[filetype] then return "c" end
    if js_family[filetype] then return "javascript" end
    if filetype == "lua" then return "lua" end

    -- Heuristics fallback: check first 100 lines for structural markers
    local semicolon_count = 0
    local brace_count = 0
    local end_count = 0
    local lines = vim.split(content, "\n")
    local max_lines = math.min(100, #lines)
    for i = 1, max_lines do
        local line = lines[i]
        if line then
            if line:find(";") then semicolon_count = semicolon_count + 1 end
            if line:find("{") or line:find("}") then brace_count = brace_count + 1 end
            if line:match("%f[%w]end%f[^%w]") then end_count = end_count + 1 end
        end
    end
    if semicolon_count > 5 and brace_count > 2 then return "c" end
    if end_count > 2 then return "lua" end
    return nil
end

local function is_valid_local_definition(node, lang)
    -- Ignore member/field expressions (e.g. self.foo, obj.prop, vim.b[bufnr].foo)
    local parent = node:parent()
    if parent then
        local ptype = parent:type()
        if ptype == "dot_index_expression" or ptype == "bracket_index_expression" or ptype == "member_expression" or ptype == "attribute" or ptype == "field_expression" then
            return false
        end
    end

    local current = node
    while current do
        local ctype = current:type()
        -- Stop walking if we cross an outer function scope boundary
        if ctype:find("function") or ctype:find("method") or ctype == "func_literal" then
            if current ~= node and current ~= parent then
                return false
            end
        end

        if lang == "lua" then
            if ctype == "variable_declaration" or ctype == "local_declaration" or ctype == "local_function" or ctype == "parameters" then
                return true
            end
        elseif lang == "javascript" or lang == "typescript" or lang == "tsx" then
            if ctype == "variable_declarator" or ctype == "formal_parameters" then
                return true
            end
        elseif lang == "c" or lang == "cpp" then
            if ctype == "declaration" or ctype == "parameter_declaration" then
                return true
            end
        end
        current = current:parent()
    end

    return true
end

local function detect_unused_vars_ts(file_path, filetype, start_line, end_line)
    if vim.fn.filereadable(file_path) ~= 1 then return {} end
    local file_content = table.concat(vim.fn.readfile(file_path), "\n")

    local lang = vim.treesitter.language.get_lang(filetype) or filetype
    if lang == "" or lang == nil then
        local style = detect_language_style(filetype, file_content)
        if style == "c" then
            lang = "c"
        elseif style == "lua" then
            lang = "lua"
        elseif style == "javascript" then
            lang = "javascript"
        else
            return {}
        end
    end

    local ok, parser = pcall(vim.treesitter.get_string_parser, file_content, lang)
    if not ok or not parser then return {} end

    local tree = parser:parse()[1]
    if not tree then return {} end
    local root_node = tree:root()

    local query = vim.treesitter.query.get(lang, "locals")
    if not query then return {} end

    local target_node = nil
    local function find_node(node)
        local ntype = node:type()
        if ntype:find("function") or ntype:find("method") or ntype == "func_literal" then
            local r, _, _, _ = node:range()
            if (r + 1) == start_line then
                target_node = node
                return
            end
        end
        for child in node:iter_children() do
            find_node(child)
            if target_node then return end
        end
    end
    find_node(root_node)

    if not target_node then
        local function find_enclosing(node)
            local ntype = node:type()
            if ntype:find("function") or ntype:find("method") or ntype == "func_literal" then
                local sr, _, er, _ = node:range()
                if (sr + 1) <= start_line and (er + 1) >= end_line then
                    target_node = node
                    return
                end
            end
            for child in node:iter_children() do
                find_enclosing(child)
                if target_node then return end
            end
        end
        find_enclosing(root_node)
    end

    if not target_node then return {} end

    local start_row, _, end_row, _ = target_node:range()
    local definitions = {}
    local references = {}

    for id, node, metadata in query:iter_captures(target_node, file_content, start_row, end_row) do
        local capture_name = query.captures[id]
        if capture_name then
            local text = vim.treesitter.get_node_text(node, file_content)
            local r, c = node:range()

            if capture_name:find("definition.var") or capture_name:find("definition.local") then
                if text ~= "self" and text ~= "_" then
                    if is_valid_local_definition(node, lang) then
                        if not definitions[text] then definitions[text] = {} end
                        table.insert(definitions[text], { row = r, col = c })
                    end
                end
            elseif capture_name:find("reference") then
                if not references[text] then references[text] = {} end
                table.insert(references[text], { row = r, col = c })
            end
        end
    end

    local unused = {}
    for var, defs in pairs(definitions) do
        local refs = references[var] or {}

        table.sort(defs, function(a, b)
            if a.row ~= b.row then return a.row < b.row end
            return a.col < b.col
        end)

        for i, def in ipairs(defs) do
            local next_def = defs[i + 1]
            local has_ref = false
            for _, ref in ipairs(refs) do
                local is_after = (ref.row > def.row) or (ref.row == def.row and ref.col > def.col)
                local is_before_next = true
                if next_def then
                    is_before_next = (ref.row < next_def.row) or (ref.row == next_def.row and ref.col < next_def.col)
                end
                if is_after and is_before_next then
                    has_ref = true
                    break
                end
            end
            if not has_ref then
                table.insert(unused, { name = var, line = def.row + 1 })
            end
        end
    end

    return unused
end

---Performs dead code analysis on the project structure and function bodies.
---@param root string The project root path.
---@return table|nil output_lines The list of formatted Markdown lines, or nil if an error occurs.
---@return string|nil error_msg An error message if something fails.
function M.analyze_dead_code(root)
    local map_data, load_err = M.load_map(root)
    if not map_data then
        return nil, load_err
    end

    local unused_funcs = {}
    local unused_types = {}
    local unused_module_vars = {}
    local unfinished_funcs = {}
    local unused_vars = {}

    -- 1. Unreferenced definitions, reported per kind so a type or a module-level
    -- variable is never described as an uncalled function.
    local function by_location(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.start_line < b.start_line
    end

    for _, f in ipairs(map_data) do
        if not f.callers or #f.callers == 0 then
            local kind = f.kind or "function"
            if kind == "class" then
                table.insert(unused_types, f)
            elseif kind == "variable" then
                table.insert(unused_module_vars, f)
            else
                table.insert(unused_funcs, f)
            end
        end
    end

    table.sort(unused_funcs, by_location)
    table.sort(unused_types, by_location)
    table.sort(unused_module_vars, by_location)

    -- Helper to read body lines
    local function get_file_lines(file_path, start_line, end_line)
        if vim.fn.filereadable(file_path) ~= 1 then return {} end
        local all_lines = vim.fn.readfile(file_path)
        local lines = {}
        for i = start_line, end_line do
            if all_lines[i] then
                table.insert(lines, all_lines[i])
            end
        end
        return lines
    end

    -- 2. Unfinished/Stub Functions & Unused Variables
    -- Stub and local-variable analysis only makes sense for function bodies.
    for _, f in ipairs(map_data) do
        local full_path = root .. f.file
        local body_lines = (f.kind or "function") == "function"
            and get_file_lines(full_path, f.start_line, f.end_line)
            or {}
        if #body_lines > 0 then
            local filetype = vim.filetype.match({ filename = full_path }) or ""
            local file_content = table.concat(body_lines, "\n")
            local lang_style = detect_language_style(filetype, file_content)

            local has_todo = false
            local has_code = false
            local is_stub = false

            local clean_lines = {}
            for _, line in ipairs(body_lines) do
                local clean = line
                -- Strip string literals first so embedded comment tokens are ignored
                clean = clean:gsub('"[^"]*"', ""):gsub("'[^']*'", ""):gsub("`[^`]*`", ""):gsub("%%[%%[.-%%]%%]", "")
                if clean:match("TODO") or clean:match("FIXME") then
                    has_todo = true
                end

                -- Strip comments
                if lang_style == "lua" then
                    clean = clean:gsub("%-%-.*", "")
                elseif filetype == "python" or filetype == "yaml" or filetype == "sh" or lang_style == nil then
                    clean = clean:gsub("#.*", "")
                else
                    clean = clean:gsub("//.*", ""):gsub("/%*.-%*/", "")
                end

                -- Check if it contains code statements
                local trimmed = vim.trim(clean)
                if trimmed ~= "" then
                    local is_boilerplate = false
                    if lang_style == "lua" then
                        is_boilerplate = trimmed:match("^local%s+function") or trimmed:match("^function") or trimmed == "end" or trimmed == "return" or trimmed == "return nil"
                    elseif filetype == "python" or lang_style == nil then
                        is_boilerplate = trimmed:match("^def%s+") or trimmed == "pass" or trimmed == "return" or trimmed == "return None"
                    elseif lang_style == "javascript" then
                        is_boilerplate = trimmed:match("^function%s+") or trimmed:match("^const%s+[%w_]+%s*=%s*%([^%)]*%)%s*=>") or trimmed == "}" or trimmed == "return" or trimmed == "return null"
                    end

                    if not is_boilerplate then
                        has_code = true
                    end
                end
                table.insert(clean_lines, clean)
            end

            if not has_code then
                is_stub = true
            end

            if has_todo then
                table.insert(unfinished_funcs, { func = f, reason = "contains TODO/FIXME comments" })
            elseif is_stub then
                table.insert(unfinished_funcs, { func = f, reason = "empty or stub function" })
            end

            -- Detect Unused local variables
            local unused_ts = detect_unused_vars_ts(full_path, filetype, f.start_line, f.end_line)
            for _, item in ipairs(unused_ts) do
                table.insert(unused_vars, {
                    name = item.name,
                    file = f.file,
                    line = item.line
                })
            end
        end
    end

    table.sort(unfinished_funcs, function(a, b)
        if a.func.file ~= b.func.file then return a.func.file < b.func.file end
        return a.func.start_line < b.func.start_line
    end)
    table.sort(unused_vars, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.line < b.line
    end)

    -- Format Markdown
    local output_lines = {}
    table.insert(output_lines, "# Dead Code Analysis")
    table.insert(output_lines, "")

    local has_any_dead_code = false

    if #unused_funcs > 0 then
        has_any_dead_code = true
        table.insert(output_lines, "## Unused / Disconnected Functions")
        table.insert(output_lines, "*Functions defined in the project but never called by other mapped functions.*")
        table.insert(output_lines, "")
        for _, f in ipairs(unused_funcs) do
            table.insert(output_lines, string.format("- [%s] (%s:L%d) - 0 callers", f.name, f.file, f.start_line))
        end
        table.insert(output_lines, "")
    end

    if #unused_types > 0 then
        has_any_dead_code = true
        table.insert(output_lines, "## Unreferenced Types")
        table.insert(output_lines, "*Classes, structs and interfaces never referenced elsewhere in the project.*")
        table.insert(output_lines, "")
        for _, t in ipairs(unused_types) do
            table.insert(output_lines, string.format("- [%s] (%s:L%d) - 0 references", t.name, t.file, t.start_line))
        end
        table.insert(output_lines, "")
    end

    if #unused_module_vars > 0 then
        has_any_dead_code = true
        table.insert(output_lines, "## Unreferenced Module Variables")
        table.insert(output_lines, "*Module-level variables never referenced outside their own declaration.*")
        table.insert(output_lines, "")
        for _, v in ipairs(unused_module_vars) do
            table.insert(output_lines, string.format("- [%s] (%s:L%d) - 0 references", v.name, v.file, v.start_line))
        end
        table.insert(output_lines, "")
    end

    if #unfinished_funcs > 0 then
        has_any_dead_code = true
        table.insert(output_lines, "## Unfinished / Stub Functions")
        table.insert(output_lines, "*Functions that contain TODO/FIXME tags or have empty/stub bodies.*")
        table.insert(output_lines, "")
        for _, entry in ipairs(unfinished_funcs) do
            table.insert(output_lines, string.format("- [%s] (%s:L%d) - %s", entry.func.name, entry.func.file, entry.func.start_line, entry.reason))
        end
        table.insert(output_lines, "")
    end

    if #unused_vars > 0 then
        has_any_dead_code = true
        table.insert(output_lines, "## Unused Local Variables")
        table.insert(output_lines, "*Variables declared but never referenced within their enclosing scope.*")
        table.insert(output_lines, "")
        for _, v in ipairs(unused_vars) do
            table.insert(output_lines, string.format("- [%s] (%s:L%d) - declared but never referenced", v.name, v.file, v.line))
        end
        table.insert(output_lines, "")
    end

    if not has_any_dead_code then
        table.insert(output_lines, "All code clean!")
    end

    return output_lines
end

return M

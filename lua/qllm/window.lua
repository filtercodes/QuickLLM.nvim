local Popup = require("nui.popup")
local Split = require("nui.split")

local Window = {}

function Window.create_horizontal(existing_bufnr)
    local size = vim.g.qllm_horizontal_popup_size or "40%"

    local split_obj = Split({
        bufnr = existing_bufnr,
        relative = "editor",
        position = "bottom",
        size = size,
    })

    -- Calculate height for tracking (but split will remain static)
    local height = 0
    if type(size) == "string" and size:match("%%$") then
        height = math.floor(vim.o.lines * (tonumber(size:sub(1, -2)) / 100))
    else
        height = tonumber(size) or 10
    end

    -- Split doesn't use row/col/midpoint logic for dynamic resizing
    return split_obj, height, 0, vim.o.columns, 0
end

function Window.create_vertical(existing_bufnr)
    local size = vim.g.qllm_vertical_popup_size or "50%"

    local split_obj = Split({
        bufnr = existing_bufnr,
        relative = "editor",
        position = "right",
        size = size,
    })

    local width = 0
    if type(size) == "string" and size:match("%%$") then
        width = math.floor(vim.o.columns * (tonumber(size:sub(1, -2)) / 100))
    else
        width = tonumber(size) or 40
    end

    return split_obj, vim.o.lines, 0, width, 0
end

function Window.create_popup(is_full_height, existing_bufnr)
    -- 1. Resolve window options (wrap, etc.)
    is_full_height = is_full_height or false -- Default to false
    local window_options = vim.deepcopy(vim.g.qllm_popup_window_options or {})

    -- 2. Resolve base options from user config
    local options = vim.deepcopy(vim.g.qllm_popup_layout or {
        relative = "editor",
        position = "50%",
        size = { width = "80%", height = "60%" }
    })

    -- 3. Calculate MAX Dimensions
    local lines = vim.o.lines
    local columns = vim.o.columns

    local statusline_h = (vim.o.laststatus > 0) and 1 or 0
    local tabline_h = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
    local cmdline_h = vim.o.cmdheight

    local usable_h = math.max(1, lines - statusline_h - tabline_h - cmdline_h - 2)

    local function parse_dim(val, total)
        if type(val) == "string" and val:match("%%$") then
            return math.floor(total * (tonumber(val:sub(1, -2)) / 100))
        end
        return tonumber(val) or val
    end

    local width_raw = options.size and options.size.width or "80%"
    local height_raw = options.size and options.size.height or "60%"

    local max_width = parse_dim(width_raw, columns)
    local max_height = parse_dim(height_raw, usable_h)

    local pos_row = "50%"
    local pos_col = "50%"
    if type(options.position) == "table" then
        pos_row = options.position.row or "50%"
        pos_col = options.position.col or "50%"
    elseif options.position then
        pos_row = options.position
    end

    local pos_row_val = parse_dim(pos_row, usable_h)
    local pos_col_val = parse_dim(pos_col, columns)

    -- Calculate centered position within usable area for the MAX height
    local max_row = math.floor(pos_row_val - (max_height / 2)) + tabline_h
    local col = math.floor(pos_col_val - (max_width / 2))

    -- Clamp coordinates to keep the popup fully on-screen
    max_row = math.max(tabline_h, math.min(max_row, tabline_h + usable_h - max_height))
    col = math.max(0, math.min(col, columns - max_width))

    -- Calculate initial row for 1-line height to start centered
    local midpoint = max_row + (max_height / 2)
    local initial_row = math.floor(midpoint - (1 / 2))

    -- Set a minimum aesthetic height (default to 5 lines)
    local min_height = vim.g.qllm_min_popup_height or 5
    -- Safety: Ensure our min_height isn't taller than the terminal height limits
    min_height = math.min(min_height, max_height)

    -- If clean window, use max_height and max_row
    local start_height = is_full_height and max_height or min_height
    -- TOP-DOWN ANCHORING: start_row is always max_row to keep the top border fixed
    local start_row = max_row

    -- 4. Return the element and its max constraints
    local ui_elem = Popup({
        bufnr = existing_bufnr,
        enter = true,
        focusable = true,
        border = { style = vim.g.qllm_popup_style or "rounded" },
        relative = options.relative or "editor",
        position = {
            row = start_row,
            col = col,
        },
        size = {
            width = max_width,
            height = start_height,
        },
        win_options = window_options,
    })

    return ui_elem, max_height, max_row, max_width, col
end

---Syncs the window height to match the buffer content.
---@param ui_bufnr number The buffer to sync
---@param info table The popup info from active_popups
function Window.sync_size(ui_bufnr, info)
    if not info or not info.ui_elem then return 0, 0 end

    -- Safety Guard: Ensure to never operate on a 0 or invalid buffer
    if ui_bufnr <= 0 or not vim.api.nvim_buf_is_valid(ui_bufnr) then
        return 0, 0
    end

    -- Dynamic resizing only applies to 'popup' type
    if vim.g.qllm_popup_type ~= "popup" then
        return 0, 0
    end

    -- Skip shrinking for full-height input windows or if the user has manually resized the window
    if info.is_full_height or info.user_resized then
        return 0, 0
    end

    local lines = vim.api.nvim_buf_get_lines(ui_bufnr, 0, -1, false)
    local visual_height = 0
    local available_width = info.max_w
    -- Account for potential border/padding if NUI doesn't subtract them from max_w
    -- Most borders take 2 columns (one for each side).
    local wrap_width = math.max(1, available_width - 2)

    local num_lines = #lines
    for i, line in ipairs(lines) do
        local line_len = #line
        if line_len == 0 then
            -- PHANTOM LINE: Only count empty lines if they are not a trailing
            -- phantom line from a split or if it's the only line in the buffer.
            -- This prevents the window from being 1 line taller than the actual text.
            if i < num_lines or num_lines == 1 then
                visual_height = visual_height + 1
            end
        else
            visual_height = visual_height + math.ceil(line_len / wrap_width)
        end
    end

    -- Standard dynamic auto-sizing with a visual floor
    local min_height = vim.g.qllm_min_popup_height or 5
    local target_h = math.min(info.max_h, math.max(visual_height, min_height))
    local target_w = info.max_w

    if target_h ~= info.current_h or target_w ~= info.current_w then
        -- TOP-DOWN EXPANSION:
        -- Lock the starting row to max_row (the highest point). 
        -- This forces the window to only grow downwards.
        info.ui_elem:update_layout({
            size = { height = target_h, width = target_w },
            position = { row = info.max_row, col = info.col }
        })
        info.current_h = target_h
        info.current_w = target_w
    end

    return visual_height, info.max_h
end

---Calculates new layout constraints from global configuration.
function Window.get_layout_constraints()
    local options = vim.g.qllm_popup_layout or {
        relative = "editor",
        position = "50%",
        size = { width = "80%", height = "60%" }
    }

    local lines = vim.o.lines
    local columns = vim.o.columns
    local statusline_h = (vim.o.laststatus > 0) and 1 or 0
    local tabline_h = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
    local cmdline_h = vim.o.cmdheight
    local usable_h = math.max(1, lines - statusline_h - tabline_h - cmdline_h - 2)

    local function parse_dim(val, total)
        if type(val) == "string" and val:match("%%$") then
            return math.floor(total * (tonumber(val:sub(1, -2)) / 100))
        end
        return tonumber(val) or val
    end

    local max_w = parse_dim(options.size and options.size.width or "80%", columns)
    local max_h = parse_dim(options.size and options.size.height or "60%", usable_h)
    local pos_row = "50%"
    local pos_col = "50%"
    if type(options.position) == "table" then
        pos_row = options.position.row or "50%"
        pos_col = options.position.col or "50%"
    elseif options.position then
        pos_row = options.position
    end

    local pos_row_val = parse_dim(pos_row, usable_h)
    local pos_col_val = parse_dim(pos_col, columns)

    local max_row = math.floor(pos_row_val - (max_h / 2)) + tabline_h
    local col = math.floor(pos_col_val - (max_w / 2))

    -- Clamp coordinates to keep the popup fully on-screen
    max_row = math.max(tabline_h, math.min(max_row, tabline_h + usable_h - max_h))
    col = math.max(0, math.min(col, columns - max_w))

    return max_h, max_row, max_w, col
end

---Updates the global popup layout configuration.
function Window.update_global_layout(delta_w, delta_h)
    local layout = vim.deepcopy(vim.g.qllm_popup_layout or {
        relative = "editor",
        position = "50%",
        size = { width = "80%", height = "60%" }
    })

    layout.size = layout.size or { width = "80%", height = "60%" }

    local function to_num(val, default)
        if type(val) == "string" then
            return tonumber(val:match("%d+")) or default
        end
        return tonumber(val) or default
    end

    local w = to_num(layout.size.width, 80)
    local h = to_num(layout.size.height, 60)

    local new_w = math.max(10, math.min(100, w + (delta_w or 0)))
    local new_h = math.max(10, math.min(100, h + (delta_h or 0)))

    layout.size.width = new_w .. "%"
    layout.size.height = new_h .. "%"
    
    vim.g.qllm_popup_layout = layout
    vim.notify(string.format("qLLM Window Size: %d%% x %d%%", new_w, new_h), vim.log.levels.INFO, { title = "qLLM" })
    return new_w, new_h
end

---Updates the global popup position configuration.
function Window.move_global_layout(delta_col, delta_row)
    local layout = vim.deepcopy(vim.g.qllm_popup_layout or {
        relative = "editor",
        position = "50%",
        size = { width = "80%", height = "60%" }
    })

    local pos_row = "50%"
    local pos_col = "50%"
    if type(layout.position) == "table" then
        pos_row = layout.position.row or "50%"
        pos_col = layout.position.col or "50%"
    elseif layout.position then
        pos_row = layout.position
    end

    local function to_num(val, default)
        if type(val) == "string" then
            return tonumber(val:match("%d+")) or default
        end
        return tonumber(val) or default
    end

    local r = to_num(pos_row, 50)
    local c = to_num(pos_col, 50)

    local new_r = math.max(0, math.min(100, r + (delta_row or 0)))
    local new_c = math.max(0, math.min(100, c + (delta_col or 0)))

    layout.position = {
        row = new_r .. "%",
        col = new_c .. "%"
    }

    vim.g.qllm_popup_layout = layout
    vim.notify(string.format("qLLM Window Position: %d%%, %d%%", new_c, new_r), vim.log.levels.INFO, { title = "qLLM" })
    return new_c, new_r
end

return Window

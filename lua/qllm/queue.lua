--/lua/qllm/queue.lua
-- This module manages the chat conversation queue on a per-buffer basis.

local M = {}
local Utils = require("qllm.utils")

-- In-memory store for chat conversation queues, keyed by buffer number.
-- Each queue is a list of messages.
-- e.g., queue[bufnr] = { { role = "user", content = "...", timestamp = 123 }, ... }
local queue = {}

-- Lock to track if summarization is in progress for a buffer
local is_summarizing = {}

---Adds a message to the queue for a given buffer.
---Triggers summarization if queue exceeds limit.
---@param bufnr number: The buffer number.
---@param role string: "user" or "assistant".
---@param content string: The message content.
---@param model string|nil: Optional explicit model.
---@param command string|nil: Optional explicit command.
---@param extra table|nil: Optional structured metadata for heaviness resolution.
function M.add_message(bufnr, role, content, model, command, extra)
    -- Guard against invalid buffer IDs (like -1 used for global/background context)
    if not bufnr or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    if not queue[bufnr] then
        queue[bufnr] = {}
    end

    -- If metadata isn't explicitly provided
    -- try to retrieve it from the buffer-local source of truth.
    if not model or not command then
        local metadata = vim.b[bufnr] and vim.b[bufnr].qllm_metadata
        if metadata then
            model = model or metadata.model
            command = command or metadata.command
        end
    end

    -- Filter out <think> tags and their contents before saving to queue
    if role == "assistant" and content then
        content = Utils.strip_thinking_tags(content)
    end

    -- Filter extra metadata based on active heaviness level at the time of message insertion
    if role == "user" and extra then
        local heaviness = vim.g.qllm_queue_heaviness or "low"
        local filtered_extra = {}
        if heaviness == "high" then
            filtered_extra.files = extra.files
            filtered_extra.search_results = extra.search_results
            filtered_extra.selection = extra.selection
        elseif heaviness == "medium" then
            filtered_extra.search_results = extra.search_results
            filtered_extra.selection = extra.selection
        end
        extra = filtered_extra
    end

    local message = {
        role = role,
        content = content,
        timestamp = os.time(),
        model = model,
        command = command,
        extra = extra,
    }
    table.insert(queue[bufnr], message)

    local opts = vim.g.qllm_queue_opts or {}
    local max_messages = opts.max_messages or 50
    local max_tokens   = opts.max_tokens   or 24000

    local summarize_mode = opts.summarize_style
    if summarize_mode == true  then summarize_mode = "messages" end
    if summarize_mode == false then summarize_mode = "none"     end
    summarize_mode = summarize_mode or "messages"

    local should_summarize = false

    if summarize_mode == "messages" then
        should_summarize = #queue[bufnr] > max_messages

    elseif summarize_mode == "tokens" then
        -- Token counting is async/expensive; only run it when the buffer
        -- has grown past a cheap pre-check (avoids calling tiktoken on every keystroke).
        local pre_check = #queue[bufnr] > 5
        if pre_check then
            local full_text = ""
            for _, msg in ipairs(queue[bufnr]) do
                full_text = full_text .. (msg.content or "")
            end
            local ok, token_count = Utils.get_accurate_tokens(full_text)
            if ok and token_count and token_count > max_tokens then
                should_summarize = true
            end
        end

    -- "none" falls through: should_summarize stays false
    end

    if should_summarize then
        if not is_summarizing[bufnr] then
            M.summarize_queue(bufnr)
        end
    elseif summarize_mode == "none" then
        -- Sliding window: keep the buffer trimmed to max_messages
        if #queue[bufnr] > max_messages then
            table.remove(queue[bufnr], 1)
        end
    end

    -- Safety cap regardless of mode: never let queue grow to 2× the message limit.
    if #queue[bufnr] > (max_messages * 2) then
        table.remove(queue[bufnr], 1)
    end
end

---Retrieves the message queue for a buffer, handling granular timeouts.
---@param bufnr number: The buffer number.
---@return table: A list of messages ready to be sent to the API.
function M.get_messages(bufnr)
    local bufnr_queue = queue[bufnr]

    if not bufnr_queue or #bufnr_queue == 0 then
        return {}
    end

    local opts = vim.g.qllm_queue_opts or {}
    local time_based_expiry = opts.time_based_expiry or false

    local current_time = os.time()
    local timeout = opts.timeout or 900
    
    local valid_queue = {}
    local expired_count = 0

    if time_based_expiry then
        -- Granular expiry: Keep only messages within the timeout window
        for _, msg in ipairs(bufnr_queue) do
            if (current_time - msg.timestamp) <= timeout then
                table.insert(valid_queue, msg)
            else
                expired_count = expired_count + 1
            end
        end
        
        -- Update the internal queue with filtered list
        queue[bufnr] = valid_queue
        bufnr_queue = valid_queue -- update local ref for return loop below

        if expired_count > 0 and #valid_queue == 0 then
             -- vim.notify("qLLM chat queue cleared due to inactivity.", vim.log.levels.INFO, { title = "qLLM" })
             return {}
         end
    end

    -- Return messages in API format
    local messages_to_send = {}
    for _, msg in ipairs(bufnr_queue) do
        local content = msg.content
        if msg.role == "user" and msg.extra then
            if msg.extra.files and #msg.extra.files > 0 then
                -- Lazy require to avoid circular dependency
                local ContextEngine = require("qllm.context_engine")
                content = content .. "\n" .. ContextEngine.format_files_as_context(msg.extra.files)
            end
            if msg.extra.search_results and msg.extra.search_results ~= "" then
                content = content .. "\n" .. msg.extra.search_results
            end
            if msg.extra.selection and msg.extra.selection ~= "" then
                content = content .. "\n[USER SELECTION]\n" .. msg.extra.selection
            end
        end
        -- We only need role and content for the API
        table.insert(messages_to_send, { role = msg.role, content = content })
    end

    return messages_to_send
end

---Returns the total token count for a buffer's queue, or nil if unavailable.
---Uses Utils.get_accurate_tokens; returns nil gracefully if tiktoken is not installed.
---@param bufnr number
---@return number|nil token_count, string|nil err
function M.get_queue_token_count(bufnr)
    local msgs = M.get_messages(bufnr)
    if #msgs == 0 then
        return 0, nil
    end

    local full_text = ""
    for _, msg in ipairs(msgs) do
        full_text = full_text .. (msg.content or "")
    end

    local ok, result = Utils.get_accurate_tokens(full_text)
    if ok and result then
        return result, nil
    else
        -- result contains the error string when ok == false
        return nil, tostring(result or "tiktoken unavailable")
    end
end

---Clears the queue for a given buffer.
---@param bufnr number: The buffer number to clear.
function M.clear_queue(bufnr)
    if queue[bufnr] then
        queue[bufnr] = nil
    end
    is_summarizing[bufnr] = false
end

---Retrieves a previous assistant response from the buffer's queue.
---@param bufnr number: The buffer number.
---@param offset number|nil: 1-based index from the end (default 1).
---@return string|nil, string|nil, string|nil, table|nil, string|nil: content, model, command, cursor_pos, question
function M.get_last_response(bufnr, offset)
    local buf_queue = queue[bufnr]
    if not buf_queue or #buf_queue == 0 then
        return nil, nil, nil, nil, nil
    end
    
    local target = offset or 1
    local count = 0
    
    -- Iterate backwards to find the nth assistant message
    for i = #buf_queue, 1, -1 do
        if buf_queue[i].role == "assistant" then
            count = count + 1
            if count == target then
                local msg = buf_queue[i]
                local question = nil
                -- The question is the message immediately preceding the answer
                if i > 1 and buf_queue[i-1].role == "user" then
                    local user_msg = buf_queue[i-1]
                    local content = user_msg.content
                    if user_msg.extra then
                        if user_msg.extra.files and #user_msg.extra.files > 0 then
                            local ContextEngine = require("qllm.context_engine")
                            content = content .. "\n" .. ContextEngine.format_files_as_context(user_msg.extra.files)
                        end
                        if user_msg.extra.search_results and user_msg.extra.search_results ~= "" then
                            content = content .. "\n" .. user_msg.extra.search_results
                        end
                        if user_msg.extra.selection and user_msg.extra.selection ~= "" then
                            content = content .. "\n[USER SELECTION]\n" .. user_msg.extra.selection
                        end
                    end
                    question = content
                end
                return msg.content, msg.model, msg.command, msg.cursor_pos, question
            end
        end
    end
    return nil, nil, nil, nil, nil
end

---Searches the conversation queue for exchanges containing query string.
---@param bufnr number The owner buffer number.
---@param query string The search query.
---@param show_question boolean? Whether to prioritize/search user questions.
---@return table match_offsets List of recall offset indices (1-indexed from newest to oldest) that match the query.
function M.search_queue(bufnr, query, show_question)
    local buf_queue = queue[bufnr]
    if not buf_queue or #buf_queue == 0 or not query or query == "" then
        return {}
    end

    local query_lower = string.lower(query)
    local matches = {}
    local count = 0

    for i = #buf_queue, 1, -1 do
        if buf_queue[i].role == "assistant" then
            count = count + 1
            local assistant_content = string.lower(buf_queue[i].content or "")
            local question_content = ""
            if i > 1 and buf_queue[i - 1].role == "user" then
                question_content = string.lower(buf_queue[i - 1].content or "")
            end

            local matched = false
            if show_question then
                if string.find(question_content, query_lower, 1, true) then
                    matched = true
                elseif string.find(assistant_content, query_lower, 1, true) then
                    matched = true
                end
            else
                if string.find(assistant_content, query_lower, 1, true) then
                    matched = true
                elseif string.find(question_content, query_lower, 1, true) then
                    matched = true
                end
            end

            if matched then
                table.insert(matches, count)
            end
        end
    end

    return matches
end

---Updates the cursor position for a specific assistant response in queue.
---@param bufnr number
---@param offset number
---@param cursor_pos table {row, col}
function M.save_cursor_pos(bufnr, offset, cursor_pos)
    local buf_queue = queue[bufnr]
    if not buf_queue then return end

    local count = 0
    for i = #buf_queue, 1, -1 do
        if buf_queue[i].role == "assistant" then
            count = count + 1
            if count == offset then
                buf_queue[i].cursor_pos = cursor_pos
                return
            end
        end
    end
end

---Removes the last exchange (assistant response + user prompt) from the queue.
---@param bufnr number: The buffer number.
---@return boolean: True if something was removed, False otherwise.
function M.undo_last_exchange(bufnr)
    local buf_queue = queue[bufnr]
    if not buf_queue or #buf_queue == 0 then
        return false
    end
    
    local popped_something = false
    -- Remove the last message if it's an assistant response
    if #buf_queue > 0 and buf_queue[#buf_queue].role == "assistant" then
        table.remove(buf_queue)
        popped_something = true
    end
    -- Also remove the corresponding user prompt that triggered it
    if #buf_queue > 0 and buf_queue[#buf_queue].role == "user" then
        table.remove(buf_queue)
        popped_something = true
    end
    
    return popped_something
end

---Returns a list of all buffers that have active queue.
---@return table: list of { bufnr, message_count, last_command, last_model, last_timestamp }
function M.list_queue_buffers()
    local result = {}
    for bufnr, msgs in pairs(queue) do
        if msgs and #msgs > 0 then
            -- Find last assistant message for metadata
            local last_model, last_command, last_ts
            for i = #msgs, 1, -1 do
                if msgs[i].role == "assistant" then
                    last_model   = msgs[i].model
                    last_command = msgs[i].command
                    last_ts      = msgs[i].timestamp
                    break
                end
            end

            -- Get a human-readable buffer name
            local buf_name = vim.api.nvim_buf_is_valid(bufnr)
                and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
                or ("[invalid buf " .. bufnr .. "]")

            if buf_name == "" then
                buf_name = "[No Name]"
            end

            table.insert(result, {
                bufnr       = bufnr,
                buf_name    = buf_name,
                msg_count   = #msgs,
                last_model  = last_model or "unknown",
                last_command= last_command or "unknown",
                last_ts     = last_ts,
            })
        end
    end

    -- Sort by most recently active
    table.sort(result, function(a, b)
        return (a.last_ts or 0) > (b.last_ts or 0)
    end)

    return result
end

---Returns the raw in-memory queue table for a given buffer.
---@param bufnr number
---@return table|nil
function M.get_raw_queue(bufnr)
    return queue[bufnr]
end

---Copies the queue from one buffer (or raw queue table) to another.
---Merges into destination if destination already has queue.
---@param src_bufnr_or_queue number|table
---@param dst_bufnr number
---@param opts table|nil  { merge: bool (default false = replace) }
---@return boolean, string  success, error_message
function M.copy_queue(src_bufnr_or_queue, dst_bufnr, opts)
    opts = opts or {}

    local src_queue
    if type(src_bufnr_or_queue) == "table" then
        src_queue = src_bufnr_or_queue
    else
        local src_bufnr = src_bufnr_or_queue
        if src_bufnr == dst_bufnr then
            return false, "Source and destination buffers are the same."
        end
        src_queue = queue[src_bufnr]
    end

    if not src_queue or #src_queue == 0 then
        return false, "No queue found to copy."
    end

    -- Deep copy so dst mutations don't affect src
    local copied = {}
    for _, msg in ipairs(src_queue) do
        table.insert(copied, vim.deepcopy(msg))
    end

    if opts.merge and queue[dst_bufnr] and #queue[dst_bufnr] > 0 then
        -- Append src onto dst
        for _, msg in ipairs(copied) do
            table.insert(queue[dst_bufnr], msg)
        end
    else
        -- Replace
        queue[dst_bufnr] = copied
    end

    return true, nil
end

--- Resolves how many messages constitute the "summarizable" portion of queue.
---@param max_messages number
---@return number
local function resolve_summary_cutoff(max_messages)
    local opts = vim.g.qllm_queue_opts or {}
    local pct  = tonumber(opts.summarize_percent) or 50
    -- Clamp to [1, 100] so nonsense values don't break things
    pct = math.max(1, math.min(100, pct))
    return math.max(1, math.floor(max_messages * pct / 100))
end

---@param bufnr
---@param summary_text string
function M.apply_summary(bufnr, summary_text)
    local msgs = queue[bufnr]
    local opts = vim.g.qllm_queue_opts or {}
    local max_messages = opts.max_messages or 50
    local half = resolve_summary_cutoff(max_messages)

    if not msgs or #msgs < half then return end
    
    -- Use metadata from the message at the cutoff point
    local marker_msg = msgs[half]
    
    local summary_msg = {
        role = "system", -- System role implies context/instruction
        content = "Summary of previous conversation:\n" .. summary_text,
        timestamp = marker_msg.timestamp,
        is_summary = true,
        model = marker_msg.model,
        command = marker_msg.command
    }
    
    -- Remove the first half of messages
    for _ = 1, half do
        table.remove(msgs, 1)
    end
    
    -- Insert summary at the beginning
    table.insert(msgs, 1, summary_msg)
end

---Initiates background summarization of the first half of the message buffer.
---@param bufnr number
function M.summarize_queue(bufnr)
    is_summarizing[bufnr] = true
    
    local opts = vim.g.qllm_queue_opts or {}
    local max_messages = opts.max_messages or 50
    local half = resolve_summary_cutoff(max_messages)

    -- Lazy require to avoid circular dependency
    local Providers = require("qllm.providers")
    local CommandsList = require("qllm.commands_list")
    
    local msgs = queue[bufnr]
    if not msgs or #msgs < half then
        is_summarizing[bufnr] = false
        return
    end
    
    -- Prepare text to summarize
    local text_block = ""
    for i = 1, half do
        local msg = msgs[i]
        text_block = text_block .. string.upper(msg.role) .. ": " .. msg.content .. "\n\n"
    end
    
    local prompt = "Summarize the following conversation flow to retain key context. Keep it concise."
    local full_request_text = prompt .. "\n\nConversation:\n" .. text_block
    
    -- Use a dummy buffer ID (-1) to prevent `make_request` from fetching existing queue
    -- and `make_call` (via handle_response) from polluting the real queue.
    local dummy_bufnr = -1
    
    -- Resolve provider and opts with potential summarization overrides
    local overrides = {
        provider = opts.summarize_provider,
        model = opts.summarize_model
    }
    local provider = Providers.get_provider(overrides)
    local cmd_opts = CommandsList.get_cmd_opts("query", overrides)
    
    if not opts then
         -- Should not happen if chat command exists, but safe guard
        is_summarizing[bufnr] = false
        return
    end
    
    -- Construct request
    local request, user_msg = provider.make_request("query", cmd_opts, full_request_text, "", dummy_bufnr)
    
    local callback = function(lines)
        if lines and #lines > 0 then
            local summary = table.concat(lines, "\n")
            -- Schedule update on main loop
            vim.schedule(function()
                M.apply_summary(bufnr, summary)
                -- Cleanup dummy queue if any was created
                M.clear_queue(dummy_bufnr)
            end)
        end
        is_summarizing[bufnr] = false
    end
    
    -- Execute
    provider.make_call(request, user_msg, callback, dummy_bufnr)
end

return M

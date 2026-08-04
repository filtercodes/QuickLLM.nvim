local curl = require("plenary.curl")
local Render = require("qllm.template_render")
local Utils = require("qllm.utils")
local Api = require("qllm.api")
local Queue = require("qllm.queue")
local Ui = require("qllm.ui")
local Logger = require("qllm.logger")

OpenAIProvider = {}

OpenAIProvider.has_streaming = true

function OpenAIProvider.make_request(command, cmd_opts, command_args, text_selection, bufnr)
    local past_messages = Queue.get_messages(bufnr)
    local new_user_message_text = Render.render(command, cmd_opts.user_message_template, command_args, text_selection, cmd_opts)
    local system_message_text = Render.render(command, cmd_opts.system_message_template, command_args, text_selection, cmd_opts)

    local model = cmd_opts.model
    -- Detect if we should use the new "Responses" API (gpt-5.5, search commands, etc.)
    local use_responses_api = model:find("^gpt%-5%.5") or cmd_opts.is_search_command
    -- Detect if this is a standard o-series reasoning model
    local is_o_series = model:find("^o1") or model:find("^o3")

    local messages_for_api = {}
    if system_message_text and system_message_text ~= "" then
        -- Reasoning models prefer "developer" role
        local system_role = (is_o_series or use_responses_api) and "developer" or "system"
        table.insert(messages_for_api, {role=system_role, content=system_message_text})
    end

    local include_queue = true
    if cmd_opts.is_search_command and vim.g.qllm_ground_include_queue == false then
        include_queue = false
    end

    if include_queue then
        for _, msg in ipairs(past_messages) do
            table.insert(messages_for_api, msg)
        end
    end
    table.insert(messages_for_api, {role="user", content=new_user_message_text})

    local request = {
        model = model,
        command = command, -- Store for logging, will be deleted before API call
    }

    if cmd_opts.output_tokens then
        request.max_tokens = cmd_opts.output_tokens
    end

    -- 1. Route to correct API structure
    if use_responses_api then
        request.input = messages_for_api
        if cmd_opts.is_search_command then
            request.tools = { { type = "web_search" } }
        end
        -- New Responses API uses nested reasoning object
        if cmd_opts.thinking then
            request.reasoning = {
                effort = "medium",
                summary = "auto" -- Opt-in to visible reasoning summaries
            }
            -- Reasoning often requires an explicit token limit (increased to 8192 to prevent mid-code truncation)
            if not request.max_tokens and not request.max_output_tokens then
                request.max_output_tokens = 8192
            end
        end
    else
        request.messages = messages_for_api
        -- Standard o-series reasoning
        if is_o_series or cmd_opts.thinking then
            request.reasoning_effort = "medium"
            request.temperature = 1.0
        end
    end

    request = vim.tbl_extend("force", request, cmd_opts.extra_params)

    -- 2. Token Parameter Normalization
    if use_responses_api then
        if request.max_tokens then
            request.max_output_tokens = request.max_tokens
            request.max_tokens = nil
        end
    elseif is_o_series and request.max_tokens then
        request.max_completion_tokens = request.max_tokens
        request.max_tokens = nil
    end

    return request, new_user_message_text
end

local function curl_callback(response, user_message_text, cb, bufnr)
    local status = response.status
    local body = response.body

    if status ~= 200 then
        body = body:gsub("%s+", " ")
        print("Error: " .. status .. " " .. body)
        Api.run_finished_hook()
        return
    end

    if body == nil or body == "" then
        print("Error: No body")
        Api.run_finished_hook()
        return
    end

    vim.schedule_wrap(function(msg)
        local ok, json = pcall(vim.fn.json_decode, msg)
        if not ok or json == vim.NIL then
            print("Error: Failed to decode API response. Body was:")
            print(msg)
            Api.run_finished_hook()
            return
        end
        OpenAIProvider.handle_response(json, user_message_text, cb, bufnr)
    end)(body)

    Api.run_finished_hook()
end

function OpenAIProvider.make_headers()
    local token = vim.g.qllm_openai_api_key or os.getenv("OPENAI_API_KEY")
    if not token then
        error(
            "OpenAIApi Key not found, set in vim with 'qllm_openai_api_key' or as the env variable 'OPENAI_API_KEY'"
        )
    end

    return { ["Content-Type"] = "application/json", Authorization = "Bearer " .. token }
end

function OpenAIProvider.handle_response(json, user_message_text, cb, bufnr)
    if json == nil then
        print("Response empty")
    elseif json.error and json.error.message then
        print("Error: " .. json.error.message)
    elseif json.output then
        -- Handle v1/responses format
        local response_text = ""
        local sources = {}
        for _, out_item in ipairs(json.output) do
            if out_item.type == "message" and out_item.content then
                for _, content_item in ipairs(out_item.content) do
                    if content_item.type == "output_text" then
                        if content_item.text then
                            response_text = response_text .. content_item.text
                        end
                        if content_item.annotations then
                            for _, annotation in ipairs(content_item.annotations) do
                                if annotation.type == "url_citation" and annotation.url then
                                    local title = annotation.title or "Untitled"
                                    table.insert(sources, string.format("- [%s](%s)", title, annotation.url))
                                end
                            end
                        end
                    end
                end
            end
        end

        if #sources > 0 and vim.g.qllm_show_search_sources then
            response_text = response_text .. "\n\n**Sources:**\n" .. table.concat(sources, "\n")
        end

        if response_text ~= "" then
            Queue.add_message(bufnr, "user", user_message_text)
            Queue.add_message(bufnr, "assistant", response_text)
            if vim.g.qllm_clear_visual_selection and vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_set_mark(bufnr, "<", 0, 0, {})
                vim.api.nvim_buf_set_mark(bufnr, ">", 0, 0, {})
            end
            cb(Utils.parse_lines(response_text))
        else
            print("Error: No response text found in v1/responses output")
        end
    elseif json.choices and json.choices[1] and json.choices[1].message then
        local message = json.choices[1].message
        local response_text = message.content

        if response_text ~= nil then
            if type(response_text) ~= "string" or response_text == "" then
                print("Error: No response text " .. type(response_text))
            else
                -- Add queue (Clean: only the answer)
                Queue.add_message(bufnr, "user", user_message_text)
                Queue.add_message(bufnr, "assistant", response_text)

                if vim.g.qllm_clear_visual_selection and vim.api.nvim_buf_is_valid(bufnr) then
                    vim.api.nvim_buf_set_mark(bufnr, "<", 0, 0, {})
                    vim.api.nvim_buf_set_mark(bufnr, ">", 0, 0, {})
                end
                cb(Utils.parse_lines(response_text))
            end
        else
            print("Error: No message in response")
        end
    else
        print("Error: Unexpected response format: " .. vim.fn.json_encode(json))
    end
end

function OpenAIProvider.make_call(payload, user_message_text, cb, bufnr)
    local url = vim.g.qllm_chat_completions_url
    -- If the payload uses "input" (Responses API) instead of "messages" (Chat API)
    if payload.input then
        url = vim.g.qllm_openai_responses_url or "https://api.openai.com/v1/responses"
    end
    local headers = OpenAIProvider.make_headers()
    Api.run_started_hook()

    -- Extract command for logging and remove from strict payload
    local command_name = payload.command or "query"

    -- Build a clean payload copy WITHOUT the command field
    -- payload.command = nil
    local api_payload = vim.tbl_extend("force", {}, payload)
    api_payload.command = nil

    -- TRACE: Log the outgoing request
    local ok, err = pcall(Logger.log_request, "openai", command_name, api_payload)
    if not ok then
        vim.notify("[qllm] Logger.log_request failed: " .. tostring(err), vim.log.levels.WARN)
    end

    if type(cb) == "table" then
        -- Streaming Mode
        api_payload.stream = true
        local payload_str = vim.fn.json_encode(api_payload)
        local partial_data = ""
        local full_text = ""

        -- Callback synchronization state to prevent multiple/hanging invocations on errors
        local finished = false
        local function safe_on_error(err)
            if finished then return end
            finished = true
            cb.on_error(err)
        end

        local function safe_on_complete(text)
            if finished then return end
            finished = true
            cb.on_complete(text)
        end

        curl.post(url, {
            body = payload_str,
            headers = headers,
            raw = { "--no-buffer" },
            stream = function(err, chunk)
                if err then
                    vim.schedule(function() 
                        safe_on_error(err)
                        Api.run_finished_hook()
                    end)
                    return
                end
                if not chunk then 
                    -- End of stream
                    vim.schedule(function()
                        if Utils.handle_stream_end(partial_data, full_text, { on_error = safe_on_error }, "openai") then
                            Api.run_finished_hook()
                            return
                        end

                        -- TRACE: Log the final response
                        local log_ok, log_err = pcall(Logger.log_response, "openai", command_name, full_text)
                        if not log_ok then
                            vim.notify("[qllm] Logger.log_response failed: " .. tostring(log_err), vim.log.levels.WARN)
                        end
                        safe_on_complete(full_text)
                        Api.run_finished_hook()
                    end)
                    return 
                end

                partial_data = partial_data .. chunk
                local current_buffer = partial_data
                local processed_segment_end = 0

                while true do
                    local data_start_idx = string.find(current_buffer, "data: ", processed_segment_end + 1, true)
                    if not data_start_idx then break end

                    local json_start_idx = data_start_idx + string.len("data: ")

                    -- Check for [DONE]
                    if string.sub(current_buffer, json_start_idx, json_start_idx + 5) == "[DONE]" then
                        processed_segment_end = json_start_idx + 6
                        break
                    end

                    local ok, json, next_idx = Utils.decode_json_stream(current_buffer, json_start_idx)
                    if not ok then break end -- Wait for more data

                    processed_segment_end = next_idx

                    if json then
                        if json.error then
                            vim.schedule(function()
                                -- DELEGATION: All UI error rendering is now handled by the orchestration layer (commands.lua).
                                safe_on_error(json.error)
                                Api.run_finished_hook()
                            end)
                            return

                        -- 1. Handle Status Updates (Responses API)
                        -- This provides visual feedback while the model is searching or thinking
                        elseif json.type == "response.status_updated" and json.status then
                            -- We send status as a "thinking" chunk (empty text) to trigger spinner updates in Commands.run_cmd
                            -- Commands.run_cmd handles the logic for switching messages based on thinking state.
                            cb.on_chunk("", true) 

                        -- 2. Handle Text Content
                        elseif (json.type == "response.output_text.delta" or json.type == "response.text_delta") and json.delta then
                            full_text = full_text .. json.delta
                            cb.on_chunk(json.delta, false)

                        -- 3. Handle Reasoning/Thinking Content
                        elseif (json.type == "response.summary_text.delta" or 
                                json.type == "response.reasoning_content.delta" or
                                json.type == "response.reasoning.delta" or
                                json.type == "reasoning.delta" or
                                json.type == "response.reasoning_text.delta") and json.delta then
                            -- API-NATIVE TRUST: Stream reasoning in sequence, but keep out of queue
                            cb.on_chunk(json.delta, true)

                        elseif json.reasoning_delta then
                            -- Catch reasoning_delta field directly if present (keep out of queue)
                            cb.on_chunk(json.reasoning_delta, true)

                        -- 4. Handle Completion & Citations
                        elseif json.type == "response.completed" and json.response and json.response.output then
                            -- Extract citations from final response
                            local sources = {}
                            for _, out_item in ipairs(json.response.output) do
                                if out_item.type == "message" and out_item.content then
                                    for _, content_item in ipairs(out_item.content) do
                                        if content_item.type == "output_text" and content_item.annotations then
                                            for _, annotation in ipairs(content_item.annotations) do
                                                if annotation.type == "url_citation" and annotation.url then
                                                    local title = annotation.title or "Untitled"
                                                    table.insert(sources, string.format("- [%s](%s)", title, annotation.url))
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            if #sources > 0 and vim.g.qllm_show_search_sources then
                                local sources_text = "\n\n**Sources:**\n" .. table.concat(sources, "\n")
                                -- Sources are added to queue
                                full_text = full_text .. sources_text
                                cb.on_chunk(sources_text, false)
                            end

                        -- 5. Standard Chat API Fallback
                        elseif json.choices and json.choices[1] and json.choices[1].delta then
                            local delta = json.choices[1].delta
                            -- Handle Reasoning/Thinking (e.g. o1/o3 models)
                            if delta.reasoning_content then
                                -- Stream thinking but keep out of queue
                                cb.on_chunk(delta.reasoning_content, true)
                            end
                            -- Handle Actual Answer
                            if delta.content then
                                full_text = full_text .. delta.content
                                cb.on_chunk(delta.content, false)
                            end
                        end
                    end
                end

                partial_data = string.sub(current_buffer, processed_segment_end + 1)
            end,
            on_error = function(err)
                safe_on_error(err.message)
                Api.run_finished_hook()
            end
        })
    else
        -- Legacy Mode
        local payload_str = vim.fn.json_encode(api_payload)
        curl.post(url, {
            body = payload_str,
            headers = headers,
            callback = function(response)
                -- TRACE: Log the response in legacy mode too
                curl_callback(response, user_message_text, function(txt)
                    local log_ok, log_err = pcall(Logger.log_response, "openai", command_name, table.concat(txt, "\n"))
                    if not log_ok then
                        vim.notify("[qllm] Logger.log_response failed: " .. tostring(log_err), vim.log.levels.WARN)
                    end
                    cb(txt)
                end, bufnr)
            end,
            on_error = function(err)
                print('Error:', err.message)
                Api.run_finished_hook()
            end,
        })
    end
end

return OpenAIProvider

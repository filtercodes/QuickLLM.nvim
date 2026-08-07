-- add public vim commands
require("qllm.config")
local qllmModule = require("qllm")
local function create_command(name)
    vim.api.nvim_create_user_command(name, function(opts)
        opts.name = name
        return qllmModule.run_cmd(opts)
    end, {
        range = true,
        nargs = "*",
        complete = require("qllm.commands_list").complete,
    })
end

create_command("Que")

-- Dynamically create preset user commands (Pre1 through Pre9) based on user configuration
local function is_preset_defined(i)
    if i == 1 then return true end -- Pre1 always available as baseline
    return vim.g["qllm_api_provider" .. i] ~= nil
        or vim.g["qllm_search_provider" .. i] ~= nil
        or vim.g["qllm_commands_defaults" .. i] ~= nil
        or vim.g["qllm_provider_defaults" .. i] ~= nil
        or vim.g["qllm_search_model" .. i] ~= nil
end

for i = 1, 9 do
    if is_preset_defined(i) then
        create_command("Pre" .. i)
    end
end
create_command("Gemini")
create_command("Claude")
create_command("Openai")
create_command("Ollama")
create_command("Groq")

-- Path Command-Line Enter:
-- Prevents accidental execution of files/scan commands if a bracket [ is unclosed.
-- Allows using Enter to select files from the completion menu.
vim.keymap.set("c", "<CR>", function()
    return require("qllm.utils").handle_cmdline_enter()
end, { expr = true })


vim.api.nvim_create_user_command("QLLMStatus", function(opts)
	return qllmModule.get_status(opts)
end, {
	range = true,
	nargs = "*",
})

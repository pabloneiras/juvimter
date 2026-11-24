--- User command `:Juvimter <subcommand>` with full tab-completion.
local M = {}

local SUBCOMMANDS = {
  "new",
  "run",
  "run_in_place",
  "run_all",
  "run_above",
  "run_below",
  "kernel",
  "interrupt",
  "restart",
  "variables",
  "add_code",
  "add_code_above",
  "add_markdown",
  "add_markdown_above",
  "delete",
  "move_up",
  "move_down",
  "toggle_type",
  "edit_markdown",
  "split",
  "merge",
  "clear",
  "clear_all",
  "toggle_output",
  "inspect",
  "open_image",
  "health",
}

function M.register()
  vim.api.nvim_create_user_command("Juvimter", function(cmd_opts)
    local args = cmd_opts.fargs
    local sub = args[1] or "kernel"
    local buffer = require("juvimter.buffer")
    local bufnr = vim.api.nvim_get_current_buf()

    if sub == "new" then
      local filename = args[2] or "untitled.ipynb"
      if not filename:match("%.ipynb$") then
        filename = filename .. ".ipynb"
      end
      vim.cmd("edit " .. vim.fn.fnameescape(filename))
      return
    elseif sub == "health" then
      vim.cmd("checkhealth juvimter")
      return
    end

    if not vim.b[bufnr].juvimter_active then
      vim.notify("juvimter: current buffer is not an .ipynb notebook (use :Juvimter new <file.ipynb>)", vim.log.levels.WARN)
      return
    end

    local actions = {
      run = function() buffer.run_cell(bufnr, true) end,
      run_in_place = function() buffer.run_cell(bufnr, false) end,
      run_all = function() buffer.run_all(bufnr) end,
      run_above = function() buffer.run_above(bufnr) end,
      run_below = function() buffer.run_below(bufnr) end,
      kernel = function() buffer.select_kernel(bufnr) end,
      interrupt = function() buffer.interrupt_kernel(bufnr) end,
      restart = function() buffer.restart_kernel(bufnr) end,
      variables = function() buffer.open_variables(bufnr) end,
      add_code = function() buffer.insert_cell_below(bufnr, "code") end,
      add_code_above = function() buffer.insert_cell_above(bufnr, "code") end,
      add_markdown = function() buffer.insert_cell_below(bufnr, "markdown") end,
      add_markdown_above = function() buffer.insert_cell_above(bufnr, "markdown") end,
      delete = function() buffer.delete_cell(bufnr) end,
      move_up = function() buffer.move_cell(bufnr, -1) end,
      move_down = function() buffer.move_cell(bufnr, 1) end,
      toggle_type = function() buffer.toggle_cell_type(bufnr) end,
      edit_markdown = function() buffer.edit_markdown(bufnr) end,
      split = function() buffer.split_cell(bufnr) end,
      merge = function() buffer.merge_cell_below(bufnr) end,
      clear = function() buffer.clear_output(bufnr) end,
      clear_all = function() buffer.clear_all_outputs(bufnr) end,
      toggle_output = function() buffer.toggle_output(bufnr) end,
      inspect = function() buffer.inspect_output(bufnr) end,
      open_image = function() buffer.open_image(bufnr) end,
    }

    local fn = actions[sub]
    if fn then
      fn()
    else
      vim.notify("juvimter: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function(arg_lead, cmd_line)
      local parts = vim.split(cmd_line, "%s+")
      if #parts <= 2 then
        return vim.tbl_filter(function(item)
          return vim.startswith(item, arg_lead)
        end, SUBCOMMANDS)
      end
      return {}
    end,
    desc = "Juvimter Jupyter Notebook commands",
  })
end

return M

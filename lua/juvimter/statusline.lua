--- Statusline & Lualine integration for juvimter.nvim.
local config = require("juvimter.config")
local kernel = require("juvimter.kernel")

local M = {}

--- Returns true if the current buffer is a juvimter notebook.
---@return boolean
function M.is_notebook()
  local buf = vim.api.nvim_get_current_buf()
  return vim.b[buf].juvimter_active == true
end

--- Render a compact status string (great for lualine or custom statusline).
---@return string
function M.status()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.b[buf].juvimter_active then
    return ""
  end

  local icons = config.options.ui.icons
  local sess = kernel.get_session(buf)
  local klabel = "No Kernel"
  local state_icon = "○"

  if sess and sess.spec then
    klabel = sess.spec.display_name or sess.spec.name
    if sess.state == "idle" then
      state_icon = "●"
    elseif sess.state == "busy" then
      state_icon = "◐"
    elseif sess.state == "starting" then
      state_icon = "◌"
    elseif sess.state == "error" then
      state_icon = "✗"
    end
  end

  local cell_info = vim.b[buf].juvimter_cell_pos or ""
  if cell_info ~= "" then
    return string.format("%s %s %s · %s", icons.kernel, state_icon, klabel, cell_info)
  end
  return string.format("%s %s %s", icons.kernel, state_icon, klabel)
end

--- Ready-to-use lualine component table.
--- Usage in lualine opts: `table.insert(opts.sections.lualine_x, require("juvimter.statusline").lualine())`
---@return table
function M.lualine()
  return {
    function()
      return M.status()
    end,
    cond = M.is_notebook,
    color = function()
      local sess = kernel.get_session(vim.api.nvim_get_current_buf())
      if not sess or sess.state == "stopped" then
        return { fg = "#6c7086" }
      elseif sess.state == "busy" or sess.state == "starting" then
        return { fg = "#f9e2af" }
      elseif sess.state == "error" then
        return { fg = "#f38ba8" }
      end
      return { fg = "#a6e3a1" }
    end,
  }
end

return M

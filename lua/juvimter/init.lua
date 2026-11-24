--- juvimter.nvim — VS Code-inspired Jupyter Notebooks natively inside Neovim.
local commands = require("juvimter.commands")
local config = require("juvimter.config")
local images = require("juvimter.images")
local kernel = require("juvimter.kernel")

local M = {}

M._initialized = false

---@param opts? table
function M.setup(opts)
  config.setup(opts)

  if M._initialized then
    return
  end
  M._initialized = true

  commands.register()

  local group = vim.api.nvim_create_augroup("JuvimterCore", { clear = true })

  if config.options.auto_attach then
    vim.api.nvim_create_autocmd({ "BufReadCmd", "BufNewFile" }, {
      group = group,
      pattern = "*.ipynb",
      callback = function(ev)
        require("juvimter.buffer").open_ipynb(ev.buf, ev.file)
      end,
    })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      pattern = "*.ipynb",
      callback = function(ev)
        require("juvimter.buffer").write_ipynb(ev.buf, ev.file)
      end,
    })
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      kernel.shutdown_all()
      images.clear_all()
    end,
  })
end

--- Convenience exports
M.statusline = require("juvimter.statusline")

return M

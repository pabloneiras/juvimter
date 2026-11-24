-- Auto-register :Juvimter command and lazy-bootstrap *.ipynb handling.
if vim.g.loaded_juvimter then
  return
end
vim.g.loaded_juvimter = true

require("juvimter.commands").register()

vim.api.nvim_create_autocmd({ "BufReadCmd", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("JuvimterBootstrap", { clear = true }),
  pattern = "*.ipynb",
  once = true,
  callback = function(ev)
    local jv = require("juvimter")
    if not jv._initialized then
      jv.setup()
      require("juvimter.buffer").open_ipynb(ev.buf, ev.file)
    end
  end,
})

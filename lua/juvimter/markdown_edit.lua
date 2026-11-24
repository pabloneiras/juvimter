--- Clean VS Code-style Markdown cell editor float.
--- Opens a Markdown cell in a clean floating buffer with filetype=markdown
--- (zero `# ` comment prefixes!) and syncs back into the notebook cell on save/close.
local M = {}

---@param lines string[]
---@param on_save fun(new_lines: string[])
---@param cell_idx number
function M.open(lines, on_save, cell_idx)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, string.format("juvimter://markdown-cell-%d.md", cell_idx))

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buf].modified = false

  local ui = vim.api.nvim_list_uis()[1]
  local max_w = ui and math.floor(ui.width * 0.78) or 86
  local max_h = ui and math.floor(ui.height * 0.65) or 24
  local width = math.min(max_w, math.max(64, math.floor(max_w * 0.9)))
  local height = math.min(max_h, math.max(8, #lines + 4))
  local row = ui and math.floor((ui.height - height) / 2) or 4
  local col = ui and math.floor((ui.width - width) / 2) or 8

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = string.format("  Markdown Cell #%d  (<C-s> / :w / q to save & close) ", cell_idx),
    title_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].conceallevel = 2

  local saved = false
  local function commit(close_win)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.bo[buf].modified = false
    saved = true
    on_save(new_lines)
    if close_win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      commit(false)
      vim.notify("juvimter: markdown cell updated", vim.log.levels.INFO)
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not saved then
        commit(false)
      end
    end,
  })

  local map = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end

  map("n", "q", function()
    commit(true)
  end, "Save & close markdown cell")

  map("n", "<Esc>", function()
    commit(true)
  end, "Save & close markdown cell")

  map({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    commit(true)
  end, "Save & close markdown cell")

  map({ "n", "i" }, "<S-CR>", function()
    vim.cmd("stopinsert")
    commit(true)
  end, "Render & close markdown cell")
end

return M

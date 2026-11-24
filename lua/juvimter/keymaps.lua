--- Buffer-local VS Code-like keymaps & cell textobjects for juvimter.nvim.
local config = require("juvimter.config")

local M = {}

---@param bufnr number
function M.attach(bufnr)
  local km = config.options.keymaps or {}
  local buffer = require("juvimter.buffer")

  local function map(modes, lhs, rhs, desc)
    if not lhs or lhs == false or lhs == "" then
      return
    end
    vim.keymap.set(modes, lhs, rhs, { buffer = bufnr, silent = true, desc = "Juvimter: " .. desc })
  end

  -- Execution (Shift+Enter & Ctrl+Enter work in Normal AND Insert mode, just like VS Code!)
  map({ "n", "i" }, km.run_and_advance, function()
    if vim.fn.mode() == "i" then
      vim.cmd("stopinsert")
    end
    buffer.run_cell(bufnr, true)
  end, "Run cell and advance")

  map({ "n", "i" }, km.run_in_place, function()
    if vim.fn.mode() == "i" then
      vim.cmd("stopinsert")
    end
    buffer.run_cell(bufnr, false)
  end, "Run cell in place")

  map("n", km.run_all, function()
    buffer.run_all(bufnr)
  end, "Run all cells")

  map("n", km.run_above, function()
    buffer.run_above(bufnr)
  end, "Run cells above")

  map("n", km.run_below, function()
    buffer.run_below(bufnr)
  end, "Run cell and below")

  -- Cell creation / deletion / reordering
  map("n", km.add_code_below, function()
    buffer.insert_cell_below(bufnr, "code")
  end, "Add code cell below")

  map("n", km.add_code_above, function()
    buffer.insert_cell_above(bufnr, "code")
  end, "Add code cell above")

  map("n", km.add_md_below, function()
    buffer.insert_cell_below(bufnr, "markdown")
  end, "Add markdown cell below")

  map("n", km.add_md_above, function()
    buffer.insert_cell_above(bufnr, "markdown")
  end, "Add markdown cell above")

  map("n", km.delete_cell, function()
    buffer.delete_cell(bufnr)
  end, "Delete cell")

  map("n", km.move_cell_up, function()
    buffer.move_cell(bufnr, -1)
  end, "Move cell up")

  map("n", km.move_cell_down, function()
    buffer.move_cell(bufnr, 1)
  end, "Move cell down")

  map("n", km.toggle_cell_type, function()
    buffer.toggle_cell_type(bufnr)
  end, "Toggle Code / Markdown")

  -- Smart <CR>: on a Markdown cell, opens clean pure-Markdown editor; otherwise normal <CR>
  if km.edit_markdown and km.edit_markdown ~= false then
    vim.keymap.set("n", km.edit_markdown, function()
      if not buffer.edit_markdown(bufnr) then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
      end
    end, { buffer = bufnr, silent = true, desc = "Juvimter: Edit markdown cell" })
  end

  map("n", km.split_cell, function()
    buffer.split_cell(bufnr)
  end, "Split cell at cursor")

  map("n", km.merge_cell_below, function()
    buffer.merge_cell_below(bufnr)
  end, "Merge with cell below")

  -- Outputs & images
  map("n", km.clear_output, function()
    buffer.clear_output(bufnr)
  end, "Clear cell output")

  map("n", km.clear_all_outputs, function()
    buffer.clear_all_outputs(bufnr)
  end, "Clear all outputs")

  map("n", km.toggle_output, function()
    buffer.toggle_output(bufnr)
  end, "Toggle output fold")

  map("n", km.inspect_output, function()
    buffer.inspect_output(bufnr)
  end, "Inspect full output")

  map("n", km.open_image, function()
    buffer.open_image(bufnr)
  end, "Open cell image externally")

  map("n", km.preview_image, function()
    buffer.preview_image(bufnr)
  end, "Preview cell image (zoomable popup)")

  map("n", km.zoom_in_image, function()
    buffer.zoom_image(bufnr, 0.25)
  end, "Zoom in inline image")

  map("n", km.zoom_out_image, function()
    buffer.zoom_image(bufnr, -0.25)
  end, "Zoom out inline image")

  map("n", km.zoom_reset_image, function()
    buffer.zoom_image(bufnr, nil)
  end, "Reset inline image zoom")

  -- Kernel & Variables
  map("n", km.select_kernel, function()
    buffer.select_kernel(bufnr)
  end, "Select kernel")

  map("n", km.interrupt_kernel, function()
    buffer.interrupt_kernel(bufnr)
  end, "Interrupt kernel")

  map("n", km.restart_kernel, function()
    buffer.restart_kernel(bufnr)
  end, "Restart kernel")

  map("n", km.variables, function()
    buffer.open_variables(bufnr)
  end, "Variable explorer")

  -- Cell navigation
  map("n", km.next_cell, function()
    buffer.goto_next_cell(bufnr)
  end, "Next cell")

  map("n", km.prev_cell, function()
    buffer.goto_prev_cell(bufnr)
  end, "Previous cell")

  -- Cell textobjects (ic = inner cell, ac = around cell)
  map({ "o", "x" }, "ic", function()
    buffer.select_cell_textobj(bufnr, true)
  end, "Inner cell")

  map({ "o", "x" }, "ac", function()
    buffer.select_cell_textobj(bufnr, false)
  end, "Around cell")

  -- Optional which-key group label
  local ok_wk, wk = pcall(require, "which-key")
  if ok_wk and wk.add then
    pcall(wk.add, {
      { "<leader>j", group = "Jupyter (Juvimter)", buffer = bufnr },
    })
  end
end

return M

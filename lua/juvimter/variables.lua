--- VS Code-style Variable Explorer floating window for juvimter.nvim.
local config = require("juvimter.config")

local M = {}

---@param s string
---@param max_w number
---@return string
local function trunc(s, max_w)
  s = tostring(s or "")
  if vim.fn.strdisplaywidth(s) <= max_w then
    return s
  end
  if max_w <= 1 then
    return "…"
  end
  local out = s
  while vim.fn.strdisplaywidth(out) > max_w - 1 and #out > 0 do
    out = out:sub(1, #out - 1)
  end
  return out .. "…"
end

---@param s string
---@param w number
---@return string
local function pad(s, w)
  local dw = vim.fn.strdisplaywidth(s)
  return s .. string.rep(" ", math.max(0, w - dw))
end

--- Open the Variable Explorer for a given kernel session.
---@param session JuvimterSession
function M.open(session)
  if not session or not session:is_running() then
    vim.notify("juvimter: start a kernel first to inspect variables", vim.log.levels.WARN)
    return
  end

  local ui = vim.api.nvim_list_uis()[1]
  local width = math.floor((ui and ui.width or 100) * (config.options.variables.width or 0.72))
  local height = math.floor((ui and ui.height or 36) * (config.options.variables.height or 0.60))
  width = math.max(60, width)
  height = math.max(12, height)
  local row = math.floor(((ui and ui.height or 36) - height) / 2)
  local col = math.floor(((ui and ui.width or 100) - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = config.options.variables.border or "rounded",
    title = " 󰀫 Juvimter Variables  (r: refresh · <CR>: inspect · q: close) ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local ns = vim.api.nvim_create_namespace("juvimter_vars")
  local current_vars = {}

  local function render(vars, err)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    if err then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  Error: " .. tostring(err) })
      vim.bo[buf].modifiable = false
      return
    end

    current_vars = vars or {}
    if #current_vars == 0 then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  (No user variables defined in current kernel session)" })
      vim.bo[buf].modifiable = false
      return
    end

    local w_name = 14
    local w_type = 14
    local w_shape = 14
    for _, v in ipairs(current_vars) do
      w_name = math.min(24, math.max(w_name, vim.fn.strdisplaywidth(v.name or "")))
      w_type = math.min(20, math.max(w_type, vim.fn.strdisplaywidth(v.type or "")))
      w_shape = math.min(18, math.max(w_shape, vim.fn.strdisplaywidth(v.shape or "")))
    end
    local w_val = math.max(20, width - w_name - w_type - w_shape - 13)

    local lines = {}
    local header = string.format(
      "  %s │ %s │ %s │ %s",
      pad("Name", w_name),
      pad("Type", w_type),
      pad("Shape / Size", w_shape),
      "Value"
    )
    local sep = "  "
      .. string.rep("─", w_name)
      .. "─┼─"
      .. string.rep("─", w_type)
      .. "─┼─"
      .. string.rep("─", w_shape)
      .. "─┼─"
      .. string.rep("─", w_val)

    lines[1] = header
    lines[2] = sep

    for _, v in ipairs(current_vars) do
      lines[#lines + 1] = string.format(
        "  %s │ %s │ %s │ %s",
        pad(trunc(v.name or "", w_name), w_name),
        pad(trunc(v.type or "", w_type), w_type),
        pad(trunc(v.shape or "-", w_shape), w_shape),
        trunc(v.value or "", w_val)
      )
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_add_highlight(buf, ns, "JuvimterTableHeader", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, ns, "JuvimterTableBorder", 1, 0, -1)
    for idx = 3, #lines do
      local row_i = idx - 1
      vim.api.nvim_buf_add_highlight(buf, ns, "Identifier", row_i, 2, 2 + w_name)
      vim.api.nvim_buf_add_highlight(buf, ns, "Type", row_i, 5 + w_name, 5 + w_name + w_type)
    end
    vim.bo[buf].modifiable = false
  end

  local function refresh()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  Loading kernel variables..." })
      vim.bo[buf].modifiable = false
    end
    session:inspect_variables(function(ok, data)
      if ok then
        render(data, nil)
      else
        render(nil, data)
      end
    end)
  end

  local function inspect_selected()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local var = current_vars[lnum - 2]
    if not var then
      return
    end
    local ibuf = vim.api.nvim_create_buf(false, true)
    vim.bo[ibuf].buftype = "nofile"
    vim.bo[ibuf].bufhidden = "wipe"
    local content = {
      string.format("Name:  %s", var.name or ""),
      string.format("Type:  %s", var.type or ""),
      string.format("Shape: %s", var.shape ~= "" and var.shape or "-"),
      string.rep("─", 56),
      var.value or "",
    }
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, content)
    vim.bo[ibuf].modifiable = false
    local iwin = vim.api.nvim_open_win(ibuf, true, {
      relative = "editor",
      width = math.min(80, width - 4),
      height = math.min(16, math.max(8, #content + 2)),
      row = row + 2,
      col = col + 2,
      style = "minimal",
      border = "rounded",
      title = " Variable: " .. (var.name or "") .. " ",
      title_pos = "center",
    })
    vim.wo[iwin].wrap = true
    local close_i = function()
      if vim.api.nvim_win_is_valid(iwin) then
        vim.api.nvim_win_close(iwin, true)
      end
    end
    vim.keymap.set("n", "q", close_i, { buffer = ibuf, silent = true })
    vim.keymap.set("n", "<Esc>", close_i, { buffer = ibuf, silent = true })
  end

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "r", refresh, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", inspect_selected, { buffer = buf, silent = true })

  refresh()
end

return M

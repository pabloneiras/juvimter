--- Core Notebook Buffer Controller for juvimter.nvim.
--- Handles *.ipynb BufReadCmd / BufWriteCmd, buffer <-> notebook sync,
--- cell editing operations, execution orchestration, and output inspection.
local ansi = require("juvimter.ansi")
local config = require("juvimter.config")
local images = require("juvimter.images")
local kernel = require("juvimter.kernel")
local markdown_edit = require("juvimter.markdown_edit")
local notebook = require("juvimter.notebook")
local picker = require("juvimter.picker")
local renderer = require("juvimter.renderer")
local variables = require("juvimter.variables")

local M = {}

---@type table<number, table>
M.docs = {}

---@param prefix string
---@param cell table
---@return string
local function format_header_line(prefix, cell)
  if cell.cell_type == "markdown" then
    return string.format("%s %%%% [markdown id:%s]", prefix, cell.id)
  elseif cell.cell_type == "raw" then
    return string.format("%s %%%% [raw id:%s]", prefix, cell.id)
  end
  return string.format("%s %%%% [id:%s]", prefix, cell.id)
end

---@param line string
---@param prefix string
---@return { cell_type: string, id: string? }?
local function parse_header_line(line, prefix)
  local esc = vim.pesc(prefix)
  local rest = line:match("^" .. esc .. "%s*%%%%(.*)$")
  if not rest then
    return nil
  end
  local ctype = "code"
  if rest:find("markdown", 1, true) then
    ctype = "markdown"
  elseif rest:find("raw", 1, true) then
    ctype = "raw"
  end
  local id = rest:match("id:([%w_%-]+)")
  return { cell_type = ctype, id = id }
end

---@param lines string[]
---@param prefix string
---@return string[]
local function prefix_markdown_lines(lines, prefix)
  local out = {}
  if #lines == 0 then
    return { prefix .. " " }
  end
  for i, l in ipairs(lines) do
    if l == "" then
      out[i] = prefix
    else
      out[i] = prefix .. " " .. l
    end
  end
  return out
end

---@param lines string[]
---@param prefix string
---@return string[]
local function strip_markdown_lines(lines, prefix)
  local esc = vim.pesc(prefix)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = (l:gsub("^" .. esc .. " ?", "", 1))
  end
  return out
end

--- Convert Notebook model to buffer lines and populate doc.cell_store.
---@param nb table
---@param prefix string
---@param cell_store table<string, table>
---@return string[]
local function notebook_to_buffer_lines(nb, prefix, cell_store)
  local lines = {}
  for _, cell in ipairs(nb.cells) do
    cell.id = cell.id or notebook.new_cell_id()
    cell_store[cell.id] = cell
    lines[#lines + 1] = format_header_line(prefix, cell)
    local src = cell.source or { "" }
    if #src == 0 then
      src = { "" }
    end
    if cell.cell_type == "markdown" or cell.cell_type == "raw" then
      for _, ml in ipairs(prefix_markdown_lines(src, prefix)) do
        lines[#lines + 1] = ml
      end
    else
      for _, cl in ipairs(src) do
        lines[#lines + 1] = cl
      end
    end
  end
  return lines
end

--- Parse current buffer lines back into doc.ranges and doc.nb.cells (preserving outputs & metadata).
---@param bufnr number
---@return table? doc
function M.sync_from_buffer(bufnr)
  local doc = M.docs[bufnr]
  if not doc or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local prefix = doc.comment_prefix or "#"

  local ranges = {}
  for row = 0, #lines - 1 do
    local hdr = parse_header_line(lines[row + 1], prefix)
    if hdr then
      if #ranges > 0 then
        ranges[#ranges].end_row = row - 1
      end
      ranges[#ranges + 1] = {
        header_row = row,
        start_row = row + 1,
        end_row = #lines - 1,
        cell_type = hdr.cell_type,
        id = hdr.id,
      }
    end
  end

  -- Handle case where user deleted the very first header line
  if #ranges == 0 then
    local id = notebook.new_cell_id()
    local cell = {
      id = id,
      cell_type = "code",
      metadata = {},
      execution_count = nil,
      source = lines,
      outputs = {},
      state = "idle",
      collapsed = false,
    }
    doc.cell_store[id] = cell
    doc.nb.cells = { cell }
    doc.ranges = {
      { header_row = 0, start_row = 0, end_row = math.max(0, #lines - 1), cell_type = "code", id = id },
    }
    return doc
  end

  local cells = {}
  local used_ids = {}
  for i, r in ipairs(ranges) do
    local id = r.id
    if not id or used_ids[id] then
      id = notebook.new_cell_id()
      r.id = id
    end
    used_ids[id] = true

    local existing = doc.cell_store[id]
    local body_lines = {}
    if r.start_row <= r.end_row then
      for row = r.start_row, r.end_row do
        body_lines[#body_lines + 1] = lines[row + 1]
      end
    else
      body_lines = { "" }
    end

    local source
    if r.cell_type == "markdown" or r.cell_type == "raw" then
      source = strip_markdown_lines(body_lines, prefix)
    else
      source = body_lines
    end

    local cell
    if existing then
      cell = existing
      cell.cell_type = r.cell_type
      cell.source = source
      if cell.cell_type ~= "code" then
        cell.execution_count = nil
        cell.outputs = {}
      end
    else
      cell = {
        id = id,
        cell_type = r.cell_type,
        metadata = {},
        execution_count = nil,
        source = source,
        outputs = {},
        state = "idle",
        elapsed_ms = nil,
        collapsed = false,
      }
      doc.cell_store[id] = cell
    end
    cells[i] = cell
  end

  doc.ranges = ranges
  doc.nb.cells = cells
  return doc
end

--- Update buffer-local cell position string for lualine/statusline.
---@param bufnr number
local function update_cell_pos_var(bufnr)
  local doc = M.docs[bufnr]
  if not doc or not doc.ranges or #doc.ranges == 0 then
    return
  end
  local idx = M.current_cell_index(bufnr) or 1
  vim.b[bufnr].juvimter_cell_pos = string.format("Cell %d/%d", idx, #doc.ranges)
end

--- Re-sync and re-render a notebook buffer.
---@param bufnr number
function M.refresh(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  update_cell_pos_var(bufnr)
  renderer.render(bufnr, doc)
end

--- Get 1-based index of the cell under cursor (and its range + cell object).
---@param bufnr number
---@return number?, table?, table?
function M.current_cell_index(bufnr)
  local doc = M.docs[bufnr]
  if not doc or not doc.ranges then
    return nil, nil, nil
  end
  local wins = vim.fn.win_findbuf(bufnr)
  local row = 0
  if vim.api.nvim_get_current_buf() == bufnr then
    row = vim.api.nvim_win_get_cursor(0)[1] - 1
  elseif #wins > 0 then
    row = vim.api.nvim_win_get_cursor(wins[1])[1] - 1
  end
  for i, r in ipairs(doc.ranges) do
    if row >= r.header_row and row <= r.end_row then
      return i, r, doc.nb.cells[i]
    end
  end
  return 1, doc.ranges[1], doc.nb.cells[1]
end

--- Get working directory for a notebook buffer.
---@param bufnr number
---@return string
function M.get_cwd(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name and name ~= "" then
    local dir = vim.fn.fnamemodify(name, ":p:h")
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return vim.uv.cwd() or "."
end

--- Move cursor to the first editable body line of cell `idx`.
---@param bufnr number
---@param idx number
function M.focus_cell(bufnr, idx)
  local doc = M.sync_from_buffer(bufnr)
  if not doc or not doc.ranges[idx] then
    return
  end
  local r = doc.ranges[idx]
  local target_row = math.min(r.start_row, r.end_row)
  local lnum = math.max(1, math.min(target_row + 1, vim.api.nvim_buf_line_count(bufnr)))
  if vim.api.nvim_get_current_buf() == bufnr then
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  end
  M.refresh(bufnr)
end

--- Sync active kernel's Python executable with attached Python LSP servers
--- (basedpyright / pyright / pylsp) so completions like `np.` use the kernel's venv.
---@param bufnr number
---@param python_path? string
function M.sync_lsp_python_path(bufnr, python_path)
  if not python_path or python_path == "" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local doc = M.docs[bufnr]
  if doc then
    doc.lsp_python_path = python_path
  end
  -- Neovim answers the server's `workspace/configuration` pull requests from
  -- `client.settings` (not `client.config.settings`), and basedpyright/pyright
  -- re-read their config that way after `didChangeConfiguration`. Update both
  -- tables, otherwise the server keeps the old interpreter.
  local function apply(client, extra)
    local settings = vim.tbl_deep_extend("force", client.settings or client.config.settings or {}, extra)
    client.settings = settings
    client.config.settings = settings
    client:notify("workspace/didChangeConfiguration", { settings = settings })
  end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.name == "basedpyright" or client.name == "pyright" then
      apply(client, { python = { pythonPath = python_path } })
    elseif client.name == "pylsp" then
      apply(client, { pylsp = { plugins = { jedi = { environment = python_path } } } })
    end
  end
end

-- ============================================================================
-- BufReadCmd / BufWriteCmd (Lossless .ipynb open & save)
-- ============================================================================

--- Open an .ipynb file into `bufnr`.
---@param bufnr number
---@param filepath string
function M.open_ipynb(bufnr, filepath)
  local raw = ""
  if filepath ~= "" and vim.fn.filereadable(filepath) == 1 then
    local ok, lines = pcall(vim.fn.readfile, filepath)
    if ok then
      raw = table.concat(lines, "\n")
    end
  end

  local nb, err = notebook.parse(raw)
  if not nb then
    vim.notify("juvimter: " .. tostring(err), vim.log.levels.ERROR)
    nb = notebook.empty("python")
  end

  local ft = notebook.get_filetype(nb)
  local prefix = notebook.comment_prefix(ft)
  local cell_store = {}
  local buf_lines = notebook_to_buffer_lines(nb, prefix, cell_store)

  local doc = {
    bufnr = bufnr,
    filepath = filepath,
    nb = nb,
    ft = ft,
    comment_prefix = prefix,
    cell_store = cell_store,
    ranges = {},
    lsp_python_path = nil,
  }
  M.docs[bufnr] = doc

  -- Only pre-sync a default kernel's Python path when auto_start_kernel is enabled;
  -- otherwise wait until the user explicitly selects a kernel.
  if ft == "python" and config.options.auto_start_kernel then
    local default_spec = kernel.pick_default_kernel(nb, M.get_cwd(bufnr))
    if default_spec and default_spec.python_path then
      doc.lsp_python_path = default_spec.python_path
    end
  end

  -- Keep buftype="" so Neovim's vim.lsp, blink.cmp, and treesitter attach normally.
  -- BufWriteCmd on *.ipynb still intercepts :w to write lossless nbformat 4.5 JSON.
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].swapfile = false

  -- BufReadCmd bypasses BufReadPre/BufReadPost; fire them so lazy-loaded LSPs
  -- (e.g. LazyVim's nvim-lspconfig on BufReadPre) initialize cleanly.
  pcall(vim.api.nvim_exec_autocmds, "BufReadPre", { buffer = bufnr, modeline = false })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buf_lines)
  vim.bo[bufnr].modified = false
  pcall(vim.api.nvim_exec_autocmds, "BufReadPost", { buffer = bufnr, modeline = false })

  -- Prevent LazyVim autoformat-on-save from mangling raw # %% cells
  vim.b[bufnr].autoformat = false
  vim.b[bufnr].juvimter_active = true

  -- Clean sign column for the VS Code left cell bar
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].signcolumn = "yes:1"
    vim.wo[win].conceallevel = 2
  end

  -- Create kernel session holder for this buffer
  if not kernel.get_session(bufnr) then
    kernel.new_session(bufnr, function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.cmd("redrawstatus")
      end
    end)
  end

  -- Setup buffer-local autocmds
  local aug = vim.api.nvim_create_augroup("JuvimterBuf_" .. bufnr, { clear = true })

  -- Whenever a Python LSP attaches to this notebook, point it at the kernel's venv
  vim.api.nvim_create_autocmd("LspAttach", {
    group = aug,
    buffer = bufnr,
    callback = function()
      if doc.lsp_python_path then
        M.sync_lsp_python_path(bufnr, doc.lsp_python_path)
      end
    end,
  })

  -- Set filetype after BufReadPre/BufReadPost so LSP servers attach immediately
  vim.bo[bufnr].filetype = ft
  if doc.lsp_python_path then
    M.sync_lsp_python_path(bufnr, doc.lsp_python_path)
  end
  local render_scheduled = false
  local function schedule_refresh()
    if render_scheduled then
      return
    end
    render_scheduled = true
    vim.schedule(function()
      render_scheduled = false
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.refresh(bufnr)
      end
    end)
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CursorMoved", "CursorMovedI", "WinResized", "BufEnter" }, {
    group = aug,
    buffer = bufnr,
    callback = schedule_refresh,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = aug,
    buffer = bufnr,
    once = true,
    callback = function()
      renderer.clear(bufnr)
      local sess = kernel.get_session(bufnr)
      if sess then
        sess:shutdown()
        kernel.sessions[bufnr] = nil
      end
      M.docs[bufnr] = nil
    end,
  })

  local keymaps = require("juvimter.keymaps")
  keymaps.attach(bufnr)
  -- Re-apply after any scheduled FileType autocmds (e.g. Python/Julia REPL plugins)
  -- and ensure LSP attaches if lazy.nvim finished loading nvim-lspconfig asynchronously.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].juvimter_active then
      if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
        pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = bufnr, modeline = false })
      end
      if doc.lsp_python_path then
        M.sync_lsp_python_path(bufnr, doc.lsp_python_path)
      end
      keymaps.attach(bufnr)
    end
  end)

  -- Focus first body line (below cell #1 header) and render
  M.sync_from_buffer(bufnr)
  update_cell_pos_var(bufnr)
  if vim.api.nvim_get_current_buf() == bufnr and #buf_lines >= 2 then
    pcall(vim.api.nvim_win_set_cursor, 0, { 2, 0 })
  end
  renderer.render(bufnr, doc)
end

--- Save buffer back to lossless nbformat 4.5 .ipynb JSON.
---@param bufnr number
---@param target_path? string
function M.write_ipynb(bufnr, target_path)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end

  local path = (target_path and target_path ~= "") and target_path or vim.api.nvim_buf_get_name(bufnr)
  if not path or path == "" then
    vim.notify("juvimter: no file name specified", vim.log.levels.ERROR)
    return
  end
  path = vim.fn.fnamemodify(path, ":p")

  -- Sync active kernel metadata into notebook (just like VS Code!)
  local sess = kernel.get_session(bufnr)
  if sess and sess.spec then
    doc.nb.metadata = doc.nb.metadata or {}
    doc.nb.metadata.kernelspec = {
      display_name = sess.spec.display_name or sess.spec.name,
      language = sess.spec.language or doc.ft,
      name = sess.spec.name,
    }
    if sess.kernel_info and type(sess.kernel_info.language_info) == "table" and next(sess.kernel_info.language_info) then
      doc.nb.metadata.language_info = sess.kernel_info.language_info
    end
  end

  local encoded = notebook.serialize(doc.nb)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f, err = io.open(path, "wb")
  if not f then
    vim.notify("juvimter: failed to write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  f:write(encoded)
  f:close()

  doc.filepath = path
  vim.bo[bufnr].modified = false
  vim.notify(
    string.format('"%s" %d cells written (nbformat %d.%d)', vim.fn.fnamemodify(path, ":t"), #doc.nb.cells, doc.nb.nbformat, doc.nb.nbformat_minor),
    vim.log.levels.INFO
  )
end

-- ============================================================================
-- Kernel Management & Cell Execution
-- ============================================================================

--- Ensure kernel is running (auto-starts preferred kernel or prompts picker), then call `cb(session)`.
---@param bufnr number
---@param cb fun(session: JuvimterSession)
function M.ensure_kernel(bufnr, cb)
  local doc = M.docs[bufnr]
  if not doc then
    return
  end
  local sess = kernel.get_session(bufnr) or kernel.new_session(bufnr)
  if sess:is_running() then
    cb(sess)
    return
  end

  local cwd = M.get_cwd(bufnr)
  local function start_spec(spec)
    vim.notify("juvimter: starting kernel " .. (spec.display_name or spec.name) .. "...", vim.log.levels.INFO)
    sess:start(spec, cwd, function(ok, info_or_err)
      if not ok then
        vim.notify("juvimter: " .. tostring(info_or_err), vim.log.levels.ERROR)
        return
      end
      vim.notify("juvimter: kernel ready (" .. (spec.display_name or spec.name) .. ")", vim.log.levels.INFO)
      if spec.python_path then
        M.sync_lsp_python_path(bufnr, spec.python_path)
      end
      vim.cmd("redrawstatus")
      cb(sess)
    end)
  end

  if config.options.auto_start_kernel then
    local default_spec = kernel.pick_default_kernel(doc.nb, cwd)
    if default_spec and default_spec.has_ipykernel ~= false then
      start_spec(default_spec)
      return
    end
  end

  picker.select_kernel(cwd, sess.spec, start_spec)
end

--- Open kernel picker and switch/start the chosen kernel.
---@param bufnr number
function M.select_kernel(bufnr)
  local sess = kernel.get_session(bufnr) or kernel.new_session(bufnr)
  local cwd = M.get_cwd(bufnr)
  picker.select_kernel(cwd, sess.spec, function(spec)
    vim.notify("juvimter: starting kernel " .. (spec.display_name or spec.name) .. "...", vim.log.levels.INFO)
    sess:start(spec, cwd, function(ok, info_or_err)
      if not ok then
        vim.notify("juvimter: " .. tostring(info_or_err), vim.log.levels.ERROR)
        return
      end
      vim.notify("juvimter: connected to " .. (spec.display_name or spec.name), vim.log.levels.INFO)
      if spec.python_path then
        M.sync_lsp_python_path(bufnr, spec.python_path)
      end
      vim.cmd("redrawstatus")
      M.refresh(bufnr)
    end)
  end)
end

--- Append an IOPub output into a cell, merging consecutive streams of the same name (nbformat standard).
---@param cell table
---@param out table
---@param is_update? boolean
local function append_output(cell, out, is_update)
  cell.outputs = cell.outputs or {}
  if is_update and #cell.outputs > 0 then
    cell.outputs[#cell.outputs] = out
    return
  end
  if out.output_type == "stream" and #cell.outputs > 0 then
    local prev = cell.outputs[#cell.outputs]
    if prev.output_type == "stream" and prev.name == out.name then
      prev.text = notebook.join_text(prev.text) .. notebook.join_text(out.text)
      return
    end
  end
  cell.outputs[#cell.outputs + 1] = out
end

--- Execute a specific cell by 1-based index.
---@param bufnr number
---@param cell_idx number
---@param opts? { on_done?: fun() }
function M.execute_cell_index(bufnr, cell_idx, opts)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local cell = doc.nb.cells[cell_idx]
  if not cell then
    return
  end
  if cell.cell_type ~= "code" then
    M.refresh(bufnr)
    if opts and opts.on_done then
      opts.on_done()
    end
    return
  end

  local code = table.concat(cell.source or {}, "\n")
  if vim.trim(code) == "" then
    cell.outputs = {}
    cell.state = "idle"
    M.refresh(bufnr)
    if opts and opts.on_done then
      opts.on_done()
    end
    return
  end

  cell.state = "queued"
  M.refresh(bufnr)

  M.ensure_kernel(bufnr, function(sess)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    cell.state = "running"
    cell.started_at = vim.uv.hrtime()
    cell.outputs = {}
    cell.collapsed = false
    local clear_pending = false
    M.refresh(bufnr)

    sess:execute(cell.id, code, {
      on_output = function(out, is_update)
        if clear_pending then
          cell.outputs = {}
          clear_pending = false
        end
        append_output(cell, out, is_update)
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.bo[bufnr].modified = true
          M.refresh(bufnr)
        end
      end,
      on_clear_output = function(wait)
        if wait then
          clear_pending = true
        else
          cell.outputs = {}
          if vim.api.nvim_buf_is_valid(bufnr) then
            M.refresh(bufnr)
          end
        end
      end,
      on_done = function(reply)
        cell.started_at = nil
        cell.elapsed_ms = reply.elapsed_ms
        if reply.execution_count ~= nil then
          cell.execution_count = reply.execution_count
        end
        if reply.status == "ok" then
          cell.state = "ok"
        else
          cell.state = "error"
          if reply.error and #(cell.outputs or {}) == 0 then
            append_output(cell, {
              output_type = "error",
              ename = "KernelError",
              evalue = tostring(reply.error),
              traceback = {},
            })
          end
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.bo[bufnr].modified = true
          M.refresh(bufnr)
        end
        if opts and opts.on_done then
          opts.on_done()
        end
      end,
    })
  end)
end

--- Run current cell. If `advance` is true, move to next cell (or create a new one at bottom like VS Code).
---@param bufnr number
---@param advance boolean
function M.run_cell(bufnr, advance)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local idx = M.current_cell_index(bufnr)
  if not idx then
    return
  end

  M.execute_cell_index(bufnr, idx)

  if advance then
    if idx < #doc.ranges then
      M.focus_cell(bufnr, idx + 1)
    else
      M.insert_cell_below(bufnr, "code")
    end
  end
end

--- Run a range of cells sequentially (`from_idx`..`to_idx`).
---@param bufnr number
---@param from_idx number
---@param to_idx number
function M.run_range(bufnr, from_idx, to_idx)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local indices = {}
  for i = math.max(1, from_idx), math.min(#doc.nb.cells, to_idx) do
    if doc.nb.cells[i].cell_type == "code" then
      indices[#indices + 1] = i
      doc.nb.cells[i].state = "queued"
    end
  end
  M.refresh(bufnr)
  if #indices == 0 then
    return
  end

  local pos = 1
  local function step()
    if pos > #indices or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local ci = indices[pos]
    pos = pos + 1
    M.execute_cell_index(bufnr, ci, { on_done = step })
  end
  step()
end

function M.run_all(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  if doc then
    M.run_range(bufnr, 1, #doc.nb.cells)
  end
end

function M.run_above(bufnr)
  local idx = M.current_cell_index(bufnr)
  if idx and idx > 1 then
    M.run_range(bufnr, 1, idx - 1)
  end
end

function M.run_below(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  local idx = M.current_cell_index(bufnr)
  if doc and idx then
    M.run_range(bufnr, idx, #doc.nb.cells)
  end
end

function M.interrupt_kernel(bufnr)
  local sess = kernel.get_session(bufnr)
  if not sess then
    vim.notify("juvimter: no active kernel", vim.log.levels.WARN)
    return
  end
  sess:interrupt(function(ok, err)
    if ok then
      vim.notify("juvimter: kernel interrupted", vim.log.levels.INFO)
    else
      vim.notify("juvimter: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

function M.restart_kernel(bufnr)
  local sess = kernel.get_session(bufnr)
  if not sess then
    vim.notify("juvimter: no active kernel", vim.log.levels.WARN)
    return
  end
  vim.notify("juvimter: restarting kernel...", vim.log.levels.INFO)
  sess:restart(function(ok, err)
    if ok then
      vim.notify("juvimter: kernel restarted", vim.log.levels.INFO)
      vim.cmd("redrawstatus")
      M.refresh(bufnr)
    else
      vim.notify("juvimter: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

function M.open_variables(bufnr)
  local sess = kernel.get_session(bufnr)
  variables.open(sess)
end

-- ============================================================================
-- Cell Manipulation (Add, Delete, Move, Toggle, Split, Merge, Markdown Edit)
-- ============================================================================

---@param bufnr number
---@param ctype "code"|"markdown"|"raw"
function M.insert_cell_below(bufnr, ctype)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local idx, r = M.current_cell_index(bufnr)
  if not idx or not r then
    return
  end

  ctype = ctype or "code"
  local cell = {
    id = notebook.new_cell_id(),
    cell_type = ctype,
    metadata = {},
    execution_count = nil,
    source = { "" },
    outputs = {},
    state = "idle",
    collapsed = false,
  }
  doc.cell_store[cell.id] = cell

  local prefix = doc.comment_prefix or "#"
  local new_lines = {
    format_header_line(prefix, cell),
    (ctype == "markdown" or ctype == "raw") and (prefix .. " ") or "",
  }
  local insert_at = r.end_row + 1
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, new_lines)
  M.focus_cell(bufnr, idx + 1)
end

---@param bufnr number
---@param ctype "code"|"markdown"|"raw"
function M.insert_cell_above(bufnr, ctype)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local idx, r = M.current_cell_index(bufnr)
  if not idx or not r then
    return
  end

  ctype = ctype or "code"
  local cell = {
    id = notebook.new_cell_id(),
    cell_type = ctype,
    metadata = {},
    execution_count = nil,
    source = { "" },
    outputs = {},
    state = "idle",
    collapsed = false,
  }
  doc.cell_store[cell.id] = cell

  local prefix = doc.comment_prefix or "#"
  local new_lines = {
    format_header_line(prefix, cell),
    (ctype == "markdown" or ctype == "raw") and (prefix .. " ") or "",
  }
  vim.api.nvim_buf_set_lines(bufnr, r.header_row, r.header_row, false, new_lines)
  M.focus_cell(bufnr, idx)
end

---@param bufnr number
function M.delete_cell(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local idx, r = M.current_cell_index(bufnr)
  if not idx or not r then
    return
  end
  if #doc.ranges == 1 then
    -- Keep at least one empty cell in notebook
    local prefix = doc.comment_prefix or "#"
    local cell = doc.nb.cells[1]
    cell.outputs = {}
    cell.execution_count = nil
    cell.state = "idle"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { format_header_line(prefix, cell), "" })
    M.focus_cell(bufnr, 1)
    return
  end

  vim.api.nvim_buf_set_lines(bufnr, r.header_row, r.end_row + 1, false, {})
  M.focus_cell(bufnr, math.min(idx, #doc.ranges - 1))
end

---@param bufnr number
---@param direction -1|1
function M.move_cell(bufnr, direction)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local idx = M.current_cell_index(bufnr)
  if not idx then
    return
  end
  local target = idx + direction
  if target < 1 or target > #doc.ranges then
    return
  end

  local r_a = doc.ranges[math.min(idx, target)]
  local r_b = doc.ranges[math.max(idx, target)]
  local lines_a = vim.api.nvim_buf_get_lines(bufnr, r_a.header_row, r_a.end_row + 1, false)
  local lines_b = vim.api.nvim_buf_get_lines(bufnr, r_b.header_row, r_b.end_row + 1, false)

  local combined = {}
  vim.list_extend(combined, lines_b)
  vim.list_extend(combined, lines_a)
  vim.api.nvim_buf_set_lines(bufnr, r_a.header_row, r_b.end_row + 1, false, combined)
  M.focus_cell(bufnr, target)
end

--- Toggle current cell between Code and Markdown (exact VS Code M / Y behavior).
---@param bufnr number
function M.toggle_cell_type(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local idx, r, cell = M.current_cell_index(bufnr)
  if not idx or not r or not cell then
    return
  end

  local prefix = doc.comment_prefix or "#"
  local new_type = cell.cell_type == "markdown" and "code" or "markdown"
  cell.cell_type = new_type
  if new_type ~= "code" then
    cell.outputs = {}
    cell.execution_count = nil
    cell.state = "idle"
  end

  local replacement = { format_header_line(prefix, cell) }
  local body = cell.source or { "" }
  if new_type == "markdown" then
    vim.list_extend(replacement, prefix_markdown_lines(body, prefix))
  else
    vim.list_extend(replacement, #body > 0 and body or { "" })
  end

  vim.api.nvim_buf_set_lines(bufnr, r.header_row, r.end_row + 1, false, replacement)
  M.focus_cell(bufnr, idx)
end

--- Open clean floating pure-Markdown editor if cursor is on a Markdown cell.
---@param bufnr number
---@return boolean handled
function M.edit_markdown(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return false
  end
  local idx, r, cell = M.current_cell_index(bufnr)
  if not idx or not r or not cell or cell.cell_type ~= "markdown" then
    return false
  end

  local prefix = doc.comment_prefix or "#"
  local cell_id = cell.id
  markdown_edit.open(cell.source or { "" }, function(new_lines)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local fresh_doc = M.sync_from_buffer(bufnr)
    if not fresh_doc then
      return
    end
    for i, fr in ipairs(fresh_doc.ranges) do
      if fr.id == cell_id then
        local c = fresh_doc.nb.cells[i]
        c.source = new_lines
        local replacement = { format_header_line(prefix, c) }
        vim.list_extend(replacement, prefix_markdown_lines(new_lines, prefix))
        vim.api.nvim_buf_set_lines(bufnr, fr.header_row, fr.end_row + 1, false, replacement)
        M.refresh(bufnr)
        break
      end
    end
  end, idx)
  return true
end

--- Split current cell at cursor line into two cells.
---@param bufnr number
function M.split_cell(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local idx, r, cell = M.current_cell_index(bufnr)
  if not idx or not r or not cell then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if row <= r.header_row then
    row = r.start_row
  end
  local new_cell = {
    id = notebook.new_cell_id(),
    cell_type = cell.cell_type,
    metadata = {},
    execution_count = nil,
    source = { "" },
    outputs = {},
    state = "idle",
    collapsed = false,
  }
  doc.cell_store[new_cell.id] = new_cell
  local prefix = doc.comment_prefix or "#"
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { format_header_line(prefix, new_cell) })
  M.focus_cell(bufnr, idx + 1)
end

--- Merge current cell with the cell below it.
---@param bufnr number
function M.merge_cell_below(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  if not doc then
    return
  end
  local idx = M.current_cell_index(bufnr)
  if not idx or idx >= #doc.ranges then
    return
  end
  local next_r = doc.ranges[idx + 1]
  vim.api.nvim_buf_set_lines(bufnr, next_r.header_row, next_r.header_row + 1, false, {})
  M.refresh(bufnr)
end

-- ============================================================================
-- Outputs, Navigation & Textobjects
-- ============================================================================

function M.clear_output(bufnr)
  local _, _, cell = M.current_cell_index(bufnr)
  if not cell then
    return
  end
  cell.outputs = {}
  cell.elapsed_ms = nil
  cell.state = "idle"
  vim.bo[bufnr].modified = true
  M.refresh(bufnr)
end

function M.clear_all_outputs(bufnr)
  local doc = M.docs[bufnr]
  if not doc then
    return
  end
  for _, cell in ipairs(doc.nb.cells) do
    cell.outputs = {}
    cell.execution_count = nil
    cell.elapsed_ms = nil
    cell.state = "idle"
  end
  vim.bo[bufnr].modified = true
  M.refresh(bufnr)
end

function M.toggle_output(bufnr)
  local _, _, cell = M.current_cell_index(bufnr)
  if not cell then
    return
  end
  cell.collapsed = not cell.collapsed
  M.refresh(bufnr)
end

--- Open full raw output of the current cell in a scrollable floating window.
---@param bufnr number
function M.inspect_output(bufnr)
  local idx, _, cell = M.current_cell_index(bufnr)
  if not cell or #(cell.outputs or {}) == 0 then
    vim.notify("juvimter: current cell has no output", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for _, out in ipairs(cell.outputs) do
    if out.output_type == "stream" then
      for _, l in ipairs(vim.split(ansi.strip(notebook.join_text(out.text)), "\n", { plain = true })) do
        lines[#lines + 1] = l
      end
    elseif out.output_type == "execute_result" or out.output_type == "display_data" then
      local data = out.data or {}
      if data["text/plain"] then
        for _, l in ipairs(vim.split(ansi.strip(notebook.join_text(data["text/plain"])), "\n", { plain = true })) do
          lines[#lines + 1] = l
        end
      elseif data["image/png"] or data["image/jpeg"] then
        lines[#lines + 1] = "[Image output — press " .. (config.options.keymaps.open_image or "<leader>ji") .. " to open externally]"
      end
    elseif out.output_type == "error" then
      lines[#lines + 1] = string.format("%s: %s", out.ename or "Error", out.evalue or "")
      for _, tb in ipairs(out.traceback or {}) do
        for _, l in ipairs(vim.split(ansi.strip(tostring(tb)), "\n", { plain = true })) do
          lines[#lines + 1] = l
        end
      end
    end
  end

  local ui = vim.api.nvim_list_uis()[1]
  local width = math.floor((ui and ui.width or 100) * 0.78)
  local height = math.floor((ui and ui.height or 36) * 0.68)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor(((ui and ui.height or 36) - height) / 2),
    col = math.floor(((ui and ui.width or 100) - width) / 2),
    style = "minimal",
    border = "rounded",
    title = string.format(" Cell #%d Output (%d lines) — q to close ", idx or 0, #lines),
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
end

--- Open the rendered plot/image of the current cell in the OS image viewer.
---@param bufnr number
function M.open_image(bufnr)
  local _, _, cell = M.current_cell_index(bufnr)
  if not cell then
    return
  end
  local paths = cell._image_paths or {}
  if #paths == 0 then
    -- Attempt to cache on demand if outputs have image data
    for _, out in ipairs(cell.outputs or {}) do
      local data = out.data or {}
      local mime = data["image/png"] and "image/png" or (data["image/jpeg"] and "image/jpeg" or nil)
      if mime then
        local cached = images.ensure_cached(data[mime], mime)
        if cached then
          paths[#paths + 1] = cached.path
        end
      end
    end
  end
  if #paths == 0 then
    vim.notify("juvimter: current cell has no image output", vim.log.levels.INFO)
    return
  end
  images.open_external(paths[#paths])
end

function M.goto_next_cell(bufnr)
  local doc = M.sync_from_buffer(bufnr)
  local idx = M.current_cell_index(bufnr)
  if doc and idx and idx < #doc.ranges then
    M.focus_cell(bufnr, idx + 1)
  end
end

function M.goto_prev_cell(bufnr)
  local idx = M.current_cell_index(bufnr)
  if idx and idx > 1 then
    M.focus_cell(bufnr, idx - 1)
  end
end

--- Select inner (`ic`) or around (`ac`) cell textobject in visual/operator-pending mode.
---@param bufnr number
---@param inner boolean
function M.select_cell_textobj(bufnr, inner)
  local _, r = M.current_cell_index(bufnr)
  if not r then
    return
  end
  local s = inner and math.min(r.start_row, r.end_row) or r.header_row
  local e = r.end_row
  vim.api.nvim_win_set_cursor(0, { s + 1, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { e + 1, 0 })
end

return M

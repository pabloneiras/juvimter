--- VS Code-inspired Notebook Renderer for juvimter.nvim.
--- Renders cell headers, active left accent bar, rendered Markdown preview,
--- ANSI-colored text/tracebacks, Unicode DataFrame tables, and inline Kitty images.
local ansi = require("juvimter.ansi")
local config = require("juvimter.config")
local html_table = require("juvimter.html_table")
local images = require("juvimter.images")
local notebook = require("juvimter.notebook")

local M = {}

local ns_chrome = vim.api.nvim_create_namespace("juvimter_chrome")
local ns_markdown = vim.api.nvim_create_namespace("juvimter_markdown")
local ns_outputs = vim.api.nvim_create_namespace("juvimter_outputs")

local spinner_timers = {} ---@type table<number, uv.uv_timer_t>
local spinner_frame = 1

---@param bufnr number
---@return number
local function get_render_width(bufnr)
  local cfg_w = config.options.ui.border_width or 0
  if cfg_w > 0 then
    return cfg_w
  end
  local wins = vim.fn.win_findbuf(bufnr)
  local w = 84
  if #wins > 0 then
    local win = wins[1]
    local info = vim.fn.getwininfo(win)[1]
    local textoff = info and info.textoff or 6
    w = math.max(40, vim.api.nvim_win_get_width(win) - textoff - 2)
  end
  return math.min(w, 120)
end

---@param chunks table[]
---@return number
local function chunks_width(chunks)
  local w = 0
  for _, c in ipairs(chunks) do
    w = w + vim.fn.strdisplaywidth(c[1])
  end
  return w
end

--- Soft-wrap a list of `{ text, hl }` chunks to fit within `max_w` display columns.
--- Breaks on whitespace when possible, falling back to character boundaries for long tokens.
---@param chunks table[]
---@param max_w number
---@return table[][]
local function wrap_chunks(chunks, max_w)
  max_w = math.max(16, max_w)
  if chunks_width(chunks) <= max_w then
    return { chunks }
  end

  local lines = {}
  local cur_line = {}
  local cur_w = 0

  local function flush()
    lines[#lines + 1] = #cur_line > 0 and cur_line or { { "", "Normal" } }
    cur_line = {}
    cur_w = 0
  end

  local function push_seg(txt, hl)
    if txt == "" then
      return
    end
    local last = cur_line[#cur_line]
    if last and last[2] == hl then
      last[1] = last[1] .. txt
    else
      cur_line[#cur_line + 1] = { txt, hl }
    end
    cur_w = cur_w + vim.fn.strdisplaywidth(txt)
  end

  for _, chunk in ipairs(chunks) do
    local text, hl = chunk[1], chunk[2]
    local nchars = vim.fn.strchars(text)
    local i = 0
    while i < nchars do
      -- Collect next word or whitespace run
      local ch = vim.fn.strcharpart(text, i, 1)
      local is_space = (ch == " " or ch == "\t")
      local j = i + 1
      while j < nchars do
        local cj = vim.fn.strcharpart(text, j, 1)
        local sp = (cj == " " or cj == "\t")
        if sp ~= is_space then
          break
        end
        j = j + 1
      end
      local token = vim.fn.strcharpart(text, i, j - i)
      local tw = vim.fn.strdisplaywidth(token)

      if cur_w + tw <= max_w then
        push_seg(token, hl)
      elseif is_space then
        -- Drop trailing spaces at wrap boundary
        flush()
      elseif tw <= max_w then
        -- Token fits on a fresh line
        if cur_w > 0 then
          flush()
        end
        push_seg(token, hl)
      else
        -- Very long unbroken token (URL, tensor repr, etc.): split by character
        local k = 0
        local tlen = j - i
        while k < tlen do
          local c = vim.fn.strcharpart(token, k, 1)
          local cw = vim.fn.strdisplaywidth(c)
          if cur_w + cw > max_w and cur_w > 0 then
            flush()
          end
          push_seg(c, hl)
          k = k + 1
        end
      end
      i = j
    end
  end

  if #cur_line > 0 or #lines == 0 then
    flush()
  end
  return lines
end

---@param ms number?
---@return string
local function format_duration(ms)
  if not ms then
    return ""
  end
  if ms < 1000 then
    return string.format("%dms", ms)
  elseif ms < 60000 then
    return string.format("%.2fs", ms / 1000)
  else
    local secs = ms / 1000
    local mins = math.floor(secs / 60)
    return string.format("%dm %.1fs", mins, secs % 60)
  end
end

---@param ft string
---@return string, string
local function lang_badge(ft)
  local icons = config.options.ui.icons
  if ft == "julia" then
    return icons.julia, "Julia"
  elseif ft == "r" then
    return icons.r, "R"
  end
  return icons.code, "Python"
end

--- Parse inline markdown spans (**bold**, *italic*, `code`) into highlight chunks.
---@param text string
---@param base_hl string
---@return table[]
local function render_inline_md(text, base_hl)
  local chunks = {}
  local pos = 1
  local len = #text

  while pos <= len do
    local s_code, e_code, code_txt = text:find("`([^`]+)`", pos)
    local s_bold, e_bold, bold_txt = text:find("%*%*([^%*]+)%*%*", pos)
    local s_ital, e_ital, ital_txt = text:find("%*([^%*]+)%*", pos)

    -- Avoid matching ** as *
    if s_ital and s_bold and s_ital == s_bold then
      s_ital = nil
    end

    local best_s, best_e, best_txt, best_hl
    if s_code then
      best_s, best_e, best_txt, best_hl = s_code, e_code, code_txt, "JuvimterMdCode"
    end
    if s_bold and (not best_s or s_bold < best_s) then
      best_s, best_e, best_txt, best_hl = s_bold, e_bold, bold_txt, "JuvimterMdBold"
    end
    if s_ital and (not best_s or s_ital < best_s) then
      best_s, best_e, best_txt, best_hl = s_ital, e_ital, ital_txt, "JuvimterMdItalic"
    end

    if not best_s then
      local tail = text:sub(pos)
      if tail ~= "" then
        chunks[#chunks + 1] = { tail, base_hl }
      end
      break
    end

    if best_s > pos then
      chunks[#chunks + 1] = { text:sub(pos, best_s - 1), base_hl }
    end
    chunks[#chunks + 1] = { best_txt, best_hl }
    pos = best_e + 1
  end

  if #chunks == 0 then
    chunks[1] = { "", base_hl }
  end
  return chunks
end

--- Render a single raw markdown line into clean VS Code-style overlay chunks.
---@param md_line string
---@param width number
---@return table[]
local function render_markdown_line(md_line, width)
  -- Horizontal rule
  if md_line:match("^%s*[%-%*_][%-%*_][%-%*_]+%s*$") then
    return { { string.rep("─", math.min(width, 60)), "JuvimterMdRule" } }
  end

  -- Headings
  local hashes, heading_text = md_line:match("^(#+)%s+(.*)$")
  if hashes then
    local lvl = math.min(#hashes, 4)
    local icons = { "󰲡 ", "󰲣 ", "󰲥 ", "󰲧 " }
    local hls = { "JuvimterMdH1", "JuvimterMdH2", "JuvimterMdH3", "JuvimterMdH4" }
    return {
      { icons[lvl], hls[lvl] },
      { heading_text, hls[lvl] },
    }
  end

  -- Blockquote
  local q = md_line:match("^%s*>%s?(.*)$")
  if q then
    local out = { { " ▎ ", "JuvimterMdQuote" } }
    vim.list_extend(out, render_inline_md(q, "JuvimterMdQuote"))
    return out
  end

  -- Bullet list
  local indent, bullet_txt = md_line:match("^(%s*)[%-%*%+]%s+(.*)$")
  if bullet_txt then
    local out = { { indent .. " • ", "JuvimterMdBullet" } }
    vim.list_extend(out, render_inline_md(bullet_txt, "Normal"))
    return out
  end

  -- Numbered list
  local n_indent, num, num_txt = md_line:match("^(%s*)(%d+%.)%s+(.*)$")
  if num_txt then
    local out = { { n_indent .. " " .. num .. " ", "JuvimterMdBullet" } }
    vim.list_extend(out, render_inline_md(num_txt, "Normal"))
    return out
  end

  -- Code fence delimiter
  local fence = md_line:match("^%s*```(.*)$")
  if fence then
    local label = vim.trim(fence)
    local txt = label ~= "" and ("── " .. label .. " ──") or "────────"
    return { { txt, "JuvimterOutputMeta" } }
  end

  return render_inline_md(md_line, "Normal")
end

--- Build virtual lines for a cell's outputs (text, ANSI, DataFrames, PNG images, errors).
---@param cell table
---@param win_width number
---@return table[], string[] image_paths
local function build_output_virt_lines(cell, win_width)
  local outputs = cell.outputs or {}
  if #outputs == 0 then
    return {}, {}
  end

  local icons = config.options.ui.icons
  local out_bar = icons.output_bar .. " "
  local max_lines = config.options.ui.max_output_lines or 30

  if cell.collapsed then
    return {
      {
        { out_bar, "JuvimterOutputBar" },
        {
          string.format(
            "▸ Output collapsed (%d %s) — press %s to expand",
            #outputs,
            #outputs == 1 and "item" or "items",
            config.options.keymaps.toggle_output or "<leader>jz"
          ),
          "JuvimterOutputMeta",
        },
      },
    }, {}
  end

  local vlines = {}
  local image_paths = {}
  local text_line_count = 0
  local hidden_lines = 0
  local wrap_w = math.max(24, win_width - 4)

  local function push_text_line(chunks, bar_hl, no_wrap)
    local wrapped = no_wrap and { chunks } or wrap_chunks(chunks, wrap_w)
    for _, wline in ipairs(wrapped) do
      if text_line_count < max_lines then
        local line = { { out_bar, bar_hl or "JuvimterOutputBar" } }
        for _, c in ipairs(wline) do
          line[#line + 1] = c
        end
        vlines[#vlines + 1] = line
        text_line_count = text_line_count + 1
      else
        hidden_lines = hidden_lines + 1
      end
    end
  end

  for _, out in ipairs(outputs) do
    local otype = out.output_type

    if otype == "stream" then
      local is_err = (out.name == "stderr")
      local def_hl = is_err and "JuvimterOutputStderr" or "JuvimterOutputText"
      local bar_hl = is_err and "JuvimterOutputBarError" or "JuvimterOutputBar"
      local raw = notebook.join_text(out.text)
      -- Drop single trailing newline to avoid extra blank output line
      if raw:sub(-1) == "\n" then
        raw = raw:sub(1, -2)
      end
      for _, l in ipairs(vim.split(raw, "\n", { plain = true })) do
        push_text_line(ansi.parse_line(l, def_hl), bar_hl)
      end
    elseif otype == "execute_result" or otype == "display_data" then
      local data = out.data or {}

      -- 1. Inline image (PNG / JPEG)
      local img_mime = data["image/png"] and "image/png" or (data["image/jpeg"] and "image/jpeg" or nil)
      if img_mime then
        local img_lines, img_path = images.render_virt_lines(data[img_mime], img_mime, win_width, cell.image_scale)
        if img_path then
          image_paths[#image_paths + 1] = img_path
        end
        for _, il in ipairs(img_lines) do
          local line = { { out_bar, "JuvimterOutputBar" } }
          for _, c in ipairs(il) do
            line[#line + 1] = c
          end
          vlines[#vlines + 1] = line
        end
        if img_path then
          local zoom_pct = math.floor((cell.image_scale or 1.0) * 100 + 0.5)
          local hint = string.format(
            "%s %d%%  (%s preview · %s/%s zoom · %s open)",
            icons.image,
            zoom_pct,
            config.options.keymaps.preview_image or "<leader>jp",
            config.options.keymaps.zoom_in_image or "<leader>j+",
            config.options.keymaps.zoom_out_image or "<leader>j-",
            config.options.keymaps.open_image or "<leader>ji"
          )
          vlines[#vlines + 1] = { { out_bar, "JuvimterOutputBar" }, { hint, "JuvimterOutputMeta" } }
        end
      else
        -- 2. HTML Table (pandas / polars DataFrame)
        local rendered_table = nil
        if data["text/html"] then
          local html = notebook.join_text(data["text/html"])
          if html:find("<table", 1, true) then
            rendered_table = html_table.render(html, 26, 20)
          end
        end

        if rendered_table then
          for _, tl in ipairs(rendered_table) do
            push_text_line(tl, "JuvimterOutputBar", true)
          end
        elseif data["text/plain"] then
          local txt = notebook.join_text(data["text/plain"])
          if txt:sub(-1) == "\n" then
            txt = txt:sub(1, -2)
          end
          for _, l in ipairs(vim.split(txt, "\n", { plain = true })) do
            push_text_line(ansi.parse_line(l, "JuvimterOutputText"), "JuvimterOutputBar")
          end
        end
      end
    elseif otype == "error" then
      local header = string.format("%s %s: %s", icons.error, out.ename or "Error", out.evalue or "")
      push_text_line({ { header, "JuvimterOutputError" } }, "JuvimterOutputBarError")
      local tb = type(out.traceback) == "table" and out.traceback or {}
      for _, tb_entry in ipairs(tb) do
        for _, l in ipairs(vim.split(tostring(tb_entry), "\n", { plain = true })) do
          push_text_line(ansi.parse_line(l, "JuvimterOutputError"), "JuvimterOutputBarError")
        end
      end
    end
  end

  if hidden_lines > 0 then
    vlines[#vlines + 1] = {
      { out_bar, "JuvimterOutputBar" },
      {
        string.format(
          "… %d more lines (%s inspect · %s fold)",
          hidden_lines,
          config.options.keymaps.inspect_output or "<leader>jo",
          config.options.keymaps.toggle_output or "<leader>jz"
        ),
        "JuvimterOutputMeta",
      },
    }
  end

  return vlines, image_paths
end

--- Format Vim keymap strings into human-readable labels for cell header hints.
---@param lhs string
---@return string
local function format_key_hint(lhs)
  local s = tostring(lhs or "")
  s = s:gsub("<S%-CR>", "Shift+Enter")
  s = s:gsub("<C%-CR>", "Ctrl+Enter")
  s = s:gsub("<M%-CR>", "Alt+Enter")
  s = s:gsub("<CR>", "Enter")
  return s
end

--- Build the VS Code-style header overlay chunks for a cell.
---@param cell table
---@param is_active boolean
---@param ft string
---@param width number
---@param raw_line_len number
---@return table[]
local function build_cell_header(cell, is_active, ft, width, raw_line_len)
  local icons = config.options.ui.icons
  local border_hl = is_active and "JuvimterCellBorderActive" or "JuvimterCellBorder"
  local header_hl = is_active and "JuvimterCellHeaderActive" or "JuvimterCellHeader"

  local chunks = {
    { "╭─ ", border_hl },
  }

  if cell.cell_type == "code" then
    -- Execution counter badge: [1] / [*] / [ ]
    local count_str
    if cell.state == "running" then
      count_str = "[*]"
    elseif cell.execution_count ~= nil then
      count_str = string.format("[%s]", tostring(cell.execution_count))
    else
      count_str = "[ ]"
    end
    chunks[#chunks + 1] = { count_str .. " ", "JuvimterExecCount" }

    local l_icon, l_name = lang_badge(ft)
    chunks[#chunks + 1] = { l_icon .. " " .. l_name .. " ", header_hl }

    -- Status badge
    if cell.state == "running" then
      local frames = icons.spinner
      local sp = frames[((spinner_frame - 1) % #frames) + 1]
      local elapsed = cell.started_at and format_duration(math.floor((vim.uv.hrtime() - cell.started_at) / 1e6)) or ""
      local label = elapsed ~= "" and (sp .. " Running (" .. elapsed .. ")") or (sp .. " Running")
      chunks[#chunks + 1] = { " " .. label .. " ", "JuvimterStatusRunning" }
    elseif cell.state == "queued" then
      chunks[#chunks + 1] = { " " .. icons.queued .. " Queued ", "JuvimterStatusQueued" }
    elseif cell.state == "error" then
      local dur = cell.elapsed_ms and (" " .. format_duration(cell.elapsed_ms)) or ""
      chunks[#chunks + 1] = { " " .. icons.error .. dur .. " ", "JuvimterStatusError" }
    elseif cell.state == "ok" or cell.execution_count ~= nil then
      local dur = cell.elapsed_ms and (" " .. format_duration(cell.elapsed_ms)) or ""
      if dur ~= "" then
        chunks[#chunks + 1] = { " " .. icons.ok .. dur .. " ", "JuvimterStatusOk" }
      elseif cell.state == "ok" then
        chunks[#chunks + 1] = { " " .. icons.ok .. " ", "JuvimterStatusOk" }
      end
    end
  elseif cell.cell_type == "markdown" then
    chunks[#chunks + 1] = { icons.markdown .. " Markdown ", "JuvimterCellBarMarkdown" }
  else
    chunks[#chunks + 1] = { icons.raw .. " Raw ", header_hl }
  end

  local hint_chunks = {}
  if is_active and config.options.ui.show_hints then
    if cell.cell_type == "code" then
      hint_chunks = {
        { " ", border_hl },
        { format_key_hint(config.options.keymaps.run_and_advance or "<S-CR>") .. " run", "JuvimterHint" },
        { " · ", border_hl },
        { format_key_hint(config.options.keymaps.select_kernel or "<leader>jK") .. " kernel ", "JuvimterHint" },
      }
    elseif cell.cell_type == "markdown" then
      hint_chunks = {
        { " ", border_hl },
        { format_key_hint(config.options.keymaps.edit_markdown or "<CR>") .. " edit markdown ", "JuvimterHint" },
      }
    end
  end

  local left_w = chunks_width(chunks)
  local right_w = chunks_width(hint_chunks)
  local target_w = math.max(width, raw_line_len + 2)
  local fill_w = math.max(2, target_w - left_w - right_w - 1)

  chunks[#chunks + 1] = { string.rep("─", fill_w), border_hl }
  for _, hc in ipairs(hint_chunks) do
    chunks[#chunks + 1] = hc
  end
  chunks[#chunks + 1] = { "╮", border_hl }

  return chunks
end

--- Ensure running-cell spinner timer is active when any cell is running.
---@param bufnr number
---@param any_running boolean
---@param rerender_cb fun()
local function update_spinner(bufnr, any_running, rerender_cb)
  local timer = spinner_timers[bufnr]
  if any_running then
    if not timer then
      timer = vim.uv.new_timer()
      spinner_timers[bufnr] = timer
      timer:start(
        100,
        100,
        vim.schedule_wrap(function()
          if not vim.api.nvim_buf_is_valid(bufnr) then
            M.stop_spinner(bufnr)
            return
          end
          spinner_frame = spinner_frame + 1
          rerender_cb()
        end)
      )
    end
  elseif timer then
    M.stop_spinner(bufnr)
  end
end

---@param bufnr number
function M.stop_spinner(bufnr)
  local timer = spinner_timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    spinner_timers[bufnr] = nil
  end
end

--- Render all cells, active indicators, markdown previews, and inline outputs for a notebook buffer.
---@param bufnr number
---@param doc table Notebook buffer document ({ nb, cells, ranges, ft, comment_prefix })
function M.render(bufnr, doc)
  if not vim.api.nvim_buf_is_valid(bufnr) or not doc or not doc.ranges then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns_chrome, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_markdown, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_outputs, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local width = get_render_width(bufnr)
  local icons = config.options.ui.icons

  -- Determine active cell index from cursor position
  local cursor_row = 0
  if vim.api.nvim_get_current_buf() == bufnr then
    cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  end

  local active_idx = 1
  for i, r in ipairs(doc.ranges) do
    if cursor_row >= r.header_row and cursor_row <= r.end_row then
      active_idx = i
      break
    end
  end

  local any_running = false
  local prefix = doc.comment_prefix or "#"

  for i, r in ipairs(doc.ranges) do
    local cell = doc.nb.cells[i]
    if cell and r.header_row < line_count then
      local is_active = (i == active_idx)
      if cell.state == "running" then
        any_running = true
      end

      -- 1. Cell Header Overlay (hides `# %%` delimiter completely!)
      local raw_header = vim.api.nvim_buf_get_lines(bufnr, r.header_row, r.header_row + 1, false)[1] or ""
      local header_chunks = build_cell_header(cell, is_active, doc.ft, width, vim.fn.strdisplaywidth(raw_header))
      vim.api.nvim_buf_set_extmark(bufnr, ns_chrome, r.header_row, 0, {
        virt_text = header_chunks,
        virt_text_pos = "overlay",
        hl_mode = "replace",
        priority = 200,
      })

      -- 2. Left Gutter Cell Bar (VS Code active blue bar vs subtle inactive bar)
      if config.options.ui.show_cell_bar then
        local bar_text = is_active and icons.bar_active or icons.bar_inactive
        local bar_hl
        if is_active then
          bar_hl = cell.cell_type == "markdown" and "JuvimterCellBarMarkdown" or "JuvimterCellBarActive"
        else
          bar_hl = "JuvimterCellBarInactive"
        end
        for row = r.header_row, math.min(r.end_row, line_count - 1) do
          vim.api.nvim_buf_set_extmark(bufnr, ns_chrome, row, 0, {
            sign_text = bar_text,
            sign_hl_group = bar_hl,
            priority = 50,
          })
        end
      end

      -- 3. Rendered Markdown Preview (when cursor is outside the markdown cell, or always in normal mode outside it)
      if cell.cell_type == "markdown" and config.options.ui.render_markdown and not is_active then
        local start_body = r.header_row + 1
        local end_body = math.min(r.end_row, line_count - 1)
        if start_body <= end_body then
          local body_lines = vim.api.nvim_buf_get_lines(bufnr, start_body, end_body + 1, false)
          local esc_prefix = vim.pesc(prefix)
          for offset, raw_line in ipairs(body_lines) do
            local row = start_body + offset - 1
            local stripped = raw_line:gsub("^" .. esc_prefix .. " ?", "", 1)
            local md_chunks = render_markdown_line(stripped, width)
            local wrapped_md = wrap_chunks(md_chunks, width)
            local first_line = wrapped_md[1]
            local raw_w = vim.fn.strdisplaywidth(raw_line)
            local rendered_w = chunks_width(first_line)
            if raw_w > rendered_w then
              first_line[#first_line + 1] = { string.rep(" ", raw_w - rendered_w), "Normal" }
            end
            local ext_opts = {
              virt_text = first_line,
              virt_text_pos = "overlay",
              hl_mode = "replace",
              priority = 180,
            }
            if #wrapped_md > 1 then
              local cont = {}
              for k = 2, #wrapped_md do
                cont[#cont + 1] = wrapped_md[k]
              end
              ext_opts.virt_lines = cont
              ext_opts.virt_lines_above = false
            end
            vim.api.nvim_buf_set_extmark(bufnr, ns_markdown, row, 0, ext_opts)
          end
        end
      end

      -- 4. Cell Footer Border + Inline Outputs + Cell Spacing
      local footer_row = math.min(r.end_row, line_count - 1)
      local border_hl = is_active and "JuvimterCellBorderActive" or "JuvimterCellBorder"
      local virt_lines = {}
      virt_lines[#virt_lines + 1] = { { "╰" .. string.rep("─", math.max(10, width - 2)) .. "╯", border_hl } }

      if cell.cell_type == "code" then
        local out_lines, img_paths = build_output_virt_lines(cell, width)
        cell._image_paths = img_paths
        for _, ol in ipairs(out_lines) do
          virt_lines[#virt_lines + 1] = ol
        end
      end

      -- Clean breathing space between cells (except after last cell)
      if i < #doc.ranges then
        virt_lines[#virt_lines + 1] = { { "", "Normal" } }
      end

      vim.api.nvim_buf_set_extmark(bufnr, ns_outputs, footer_row, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
        priority = 100,
      })
    end
  end

  update_spinner(bufnr, any_running, function()
    M.render(bufnr, doc)
  end)
end

--- Clear all rendered extmarks for a buffer.
---@param bufnr number
function M.clear(bufnr)
  M.stop_spinner(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_chrome, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_markdown, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_outputs, 0, -1)
  end
end

return M

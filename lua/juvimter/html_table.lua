--- Lightweight HTML <table> parser for rendering pandas / polars DataFrames
--- as clean Unicode box-drawing tables inside Neovim virtual lines.
local M = {}

local ENTITIES = {
  ["&nbsp;"] = " ",
  ["&lt;"] = "<",
  ["&gt;"] = ">",
  ["&amp;"] = "&",
  ["&quot;"] = '"',
  ["&#39;"] = "'",
  ["&apos;"] = "'",
  ["&hellip;"] = "…",
  ["&mdash;"] = "—",
  ["&ndash;"] = "–",
}

---@param s string
---@return string
local function clean_cell_text(s)
  -- Remove nested tags, decode basic HTML entities, collapse whitespace
  s = s:gsub("<[^>]+>", " ")
  for k, v in pairs(ENTITIES) do
    s = s:gsub(k, v)
  end
  s = s:gsub("&#(%d+);", function(n)
    local cp = tonumber(n)
    return cp and vim.fn.nr2char(cp) or ""
  end)
  s = s:gsub("%s+", " ")
  return vim.trim(s)
end

---@param html string
---@return { headers: string[][], rows: string[][], footer: string? }?
function M.parse(html)
  if type(html) ~= "string" then
    return nil
  end
  local table_body = html:match("<table[^>]*>(.-)</table>")
  if not table_body then
    return nil
  end

  -- Strip <style> blocks
  table_body = table_body:gsub("<style[^>]*>.-</style>", "")

  local headers = {}
  local rows = {}

  local thead = table_body:match("<thead[^>]*>(.-)</thead>")
  if thead then
    for tr in thead:gmatch("<tr[^>]*>(.-)</tr>") do
      local cols = {}
      for cell in tr:gmatch("<t[hd][^>]*>(.-)</t[hd]>") do
        cols[#cols + 1] = clean_cell_text(cell)
      end
      if #cols > 0 then
        headers[#headers + 1] = cols
      end
    end
  end

  local tbody = table_body:match("<tbody[^>]*>(.-)</tbody>") or table_body
  if thead and tbody == table_body then
    tbody = tbody:gsub("<thead[^>]*>.-</thead>", "")
  end

  for tr in tbody:gmatch("<tr[^>]*>(.-)</tr>") do
    local cols = {}
    for cell in tr:gmatch("<t[hd][^>]*>(.-)</t[hd]>") do
      cols[#cols + 1] = clean_cell_text(cell)
    end
    if #cols > 0 then
      rows[#rows + 1] = cols
    end
  end

  if #headers == 0 and #rows == 0 then
    return nil
  end

  -- Capture pandas shape footer like "<p>5 rows × 3 columns</p>"
  local after_table = html:match("</table>(.*)$") or ""
  local footer = after_table:match("<p[^>]*>(.-)</p>")
  if footer then
    footer = clean_cell_text(footer)
    if footer == "" then
      footer = nil
    end
  end

  return {
    headers = headers,
    rows = rows,
    footer = footer,
  }
end

---@param s string
---@param max_w number
---@return string
local function truncate(s, max_w)
  local w = vim.fn.strdisplaywidth(s)
  if w <= max_w then
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
---@param width number
---@param right_align? boolean
---@return string
local function pad(s, width, right_align)
  local w = vim.fn.strdisplaywidth(s)
  local diff = math.max(0, width - w)
  if right_align then
    return string.rep(" ", diff) .. s
  end
  return s .. string.rep(" ", diff)
end

--- Render an HTML table into Neovim virtual lines (array of { {text, hl}, ... }).
---@param html string
---@param max_col_width? number
---@param max_rows? number
---@return table[]?
function M.render(html, max_col_width, max_rows)
  local parsed = M.parse(html)
  if not parsed then
    return nil
  end

  max_col_width = max_col_width or 28
  max_rows = max_rows or 20

  local num_cols = 0
  for _, h in ipairs(parsed.headers) do
    num_cols = math.max(num_cols, #h)
  end
  for _, r in ipairs(parsed.rows) do
    num_cols = math.max(num_cols, #r)
  end
  if num_cols == 0 then
    return nil
  end

  local widths = {}
  local is_numeric = {}
  for c = 1, num_cols do
    widths[c] = 1
    is_numeric[c] = true
  end

  local function measure(row_list, check_num)
    for _, r in ipairs(row_list) do
      for c = 1, num_cols do
        local txt = truncate(r[c] or "", max_col_width)
        widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(txt))
        if check_num and txt ~= "" and txt ~= "..." and txt ~= "NaN" and not txt:match("^[%-+]?%d+%.?%d*[eE]?[%-+]?%d*$") then
          is_numeric[c] = false
        end
      end
    end
  end

  measure(parsed.headers, false)
  local display_rows = {}
  local truncated_rows = 0
  if #parsed.rows > max_rows then
    local head_n = math.floor(max_rows / 2)
    local tail_n = max_rows - head_n
    for i = 1, head_n do
      display_rows[#display_rows + 1] = parsed.rows[i]
    end
    local ellipsis = {}
    for c = 1, num_cols do
      ellipsis[c] = "…"
    end
    display_rows[#display_rows + 1] = ellipsis
    for i = #parsed.rows - tail_n + 1, #parsed.rows do
      display_rows[#display_rows + 1] = parsed.rows[i]
    end
    truncated_rows = #parsed.rows - max_rows
  else
    display_rows = parsed.rows
  end
  measure(display_rows, true)

  local function hline(left, mid, right)
    local segs = {}
    for c = 1, num_cols do
      segs[c] = string.rep("─", widths[c] + 2)
    end
    return { { left .. table.concat(segs, mid) .. right, "JuvimterTableBorder" } }
  end

  local function row_line(r, text_hl, allow_right_align)
    local chunks = { { "│", "JuvimterTableBorder" } }
    for c = 1, num_cols do
      local txt = truncate(r[c] or "", max_col_width)
      local cell_hl = (c == 1 and allow_right_align) and "JuvimterTableHeader" or text_hl
      chunks[#chunks + 1] = { " " .. pad(txt, widths[c], allow_right_align and is_numeric[c]) .. " ", cell_hl }
      chunks[#chunks + 1] = { "│", "JuvimterTableBorder" }
    end
    return chunks
  end

  local lines = {}
  lines[#lines + 1] = hline("┌", "┬", "┐")
  if #parsed.headers > 0 then
    for _, h in ipairs(parsed.headers) do
      lines[#lines + 1] = row_line(h, "JuvimterTableHeader", false)
    end
    lines[#lines + 1] = hline("├", "┼", "┤")
  end
  for _, r in ipairs(display_rows) do
    lines[#lines + 1] = row_line(r, "JuvimterOutputText", true)
  end
  lines[#lines + 1] = hline("└", "┴", "┘")

  if parsed.footer then
    lines[#lines + 1] = { { " " .. parsed.footer, "JuvimterOutputMeta" } }
  elseif truncated_rows > 0 then
    lines[#lines + 1] = { { string.format(" (%d rows omitted)", truncated_rows), "JuvimterOutputMeta" } }
  end

  return lines
end

return M

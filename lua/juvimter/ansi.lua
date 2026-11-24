--- ANSI SGR escape code parser -> Neovim virtual-line highlight chunks.
--- Handles standard 16 colors, 256-color palette, 24-bit RGB, bold/italic/underline.
local M = {}

local ANSI_16 = {
  [30] = "#45475a",
  [31] = "#f38ba8",
  [32] = "#a6e3a1",
  [33] = "#f9e2af",
  [34] = "#89b4fa",
  [35] = "#cba6f7",
  [36] = "#94e2d5",
  [37] = "#cdd6f4",
  [90] = "#6c7086",
  [91] = "#f38ba8",
  [92] = "#a6e3a1",
  [93] = "#f9e2af",
  [94] = "#89b4fa",
  [95] = "#cba6f7",
  [96] = "#94e2d5",
  [97] = "#ffffff",
}

local hl_cache = {}

---@param idx number
---@return string
local function xterm256_to_hex(idx)
  if idx < 8 then
    return ANSI_16[30 + idx] or "#cdd6f4"
  elseif idx < 16 then
    return ANSI_16[82 + idx] or "#ffffff"
  elseif idx < 232 then
    local n = idx - 16
    local r = math.floor(n / 36)
    local g = math.floor((n % 36) / 6)
    local b = n % 6
    local levels = { 0, 95, 135, 175, 215, 255 }
    return string.format("#%02x%02x%02x", levels[r + 1], levels[g + 1], levels[b + 1])
  else
    local v = 8 + (idx - 232) * 10
    return string.format("#%02x%02x%02x", v, v, v)
  end
end

---@param state table
---@param default_hl string
---@return string
local function get_hl_group(state, default_hl)
  if not state.fg and not state.bg and not state.bold and not state.italic and not state.underline then
    return default_hl
  end
  local key = string.format(
    "%s_%s_%d_%d_%d",
    state.fg or "",
    state.bg or "",
    state.bold and 1 or 0,
    state.italic and 1 or 0,
    state.underline and 1 or 0
  )
  if hl_cache[key] then
    return hl_cache[key]
  end
  local name = "JuvimterAnsi_" .. key:gsub("#", "")
  local spec = {}
  if state.fg then
    spec.fg = state.fg
  end
  if state.bg then
    spec.bg = state.bg
  end
  if state.bold then
    spec.bold = true
  end
  if state.italic then
    spec.italic = true
  end
  if state.underline then
    spec.underline = true
  end
  vim.api.nvim_set_hl(0, name, spec)
  hl_cache[key] = name
  return name
end

---@param state table
---@param code_str string
local function apply_sgr(state, code_str)
  if code_str == "" then
    state.fg = nil
    state.bg = nil
    state.bold = false
    state.italic = false
    state.underline = false
    return
  end
  local parts = {}
  for num in code_str:gmatch("%d+") do
    parts[#parts + 1] = tonumber(num)
  end
  if #parts == 0 then
    parts[1] = 0
  end
  local i = 1
  while i <= #parts do
    local c = parts[i]
    if c == 0 then
      state.fg = nil
      state.bg = nil
      state.bold = false
      state.italic = false
      state.underline = false
    elseif c == 1 then
      state.bold = true
    elseif c == 3 then
      state.italic = true
    elseif c == 4 then
      state.underline = true
    elseif c == 22 then
      state.bold = false
    elseif c == 23 then
      state.italic = false
    elseif c == 24 then
      state.underline = false
    elseif (c >= 30 and c <= 37) or (c >= 90 and c <= 97) then
      state.fg = ANSI_16[c]
    elseif c == 39 then
      state.fg = nil
    elseif (c >= 40 and c <= 47) or (c >= 100 and c <= 107) then
      state.bg = ANSI_16[c - 10]
    elseif c == 49 then
      state.bg = nil
    elseif c == 38 or c == 48 then
      local is_fg = (c == 38)
      local mode = parts[i + 1]
      if mode == 5 and parts[i + 2] then
        local hex = xterm256_to_hex(parts[i + 2])
        if is_fg then
          state.fg = hex
        else
          state.bg = hex
        end
        i = i + 2
      elseif mode == 2 and parts[i + 4] then
        local hex = string.format("#%02x%02x%02x", parts[i + 2], parts[i + 3], parts[i + 4])
        if is_fg then
          state.fg = hex
        else
          state.bg = hex
        end
        i = i + 4
      end
    end
    i = i + 1
  end
end

--- Strip all ANSI escape codes from a string.
---@param s string
---@return string
function M.strip(s)
  return (s:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""))
end

--- Parse a single line containing ANSI codes into extmark chunks: { { text, hl }, ... }
---@param line string
---@param default_hl? string
---@return table[]
function M.parse_line(line, default_hl)
  default_hl = default_hl or "JuvimterOutputText"
  -- Handle carriage returns (e.g. tqdm progress bars): keep last segment after \r
  if line:find("\r", 1, true) then
    local segs = vim.split(line, "\r", { plain = true })
    line = segs[#segs]
    if line == "" and #segs > 1 then
      line = segs[#segs - 1]
    end
  end

  if not line:find("\27", 1, true) then
    return { { line, default_hl } }
  end

  local chunks = {}
  local state = {}
  local pos = 1
  local len = #line

  while pos <= len do
    local s, e, params = line:find("\27%[([%d;]*)m", pos)
    if not s then
      local tail = line:sub(pos):gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
      if tail ~= "" then
        chunks[#chunks + 1] = { tail, get_hl_group(state, default_hl) }
      end
      break
    end
    if s > pos then
      local text = line:sub(pos, s - 1):gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
      if text ~= "" then
        chunks[#chunks + 1] = { text, get_hl_group(state, default_hl) }
      end
    end
    apply_sgr(state, params)
    pos = e + 1
  end

  if #chunks == 0 then
    chunks[1] = { "", default_hl }
  end
  return chunks
end

return M

--- Inline image renderer for juvimter.nvim using Kitty Graphics Protocol
--- Unicode Placeholders (U=1), supporting Ghostty, Kitty, and tmux passthrough,
--- with pure-Lua PNG/JPEG dimension parsing (zero external CLI dependencies).
local config = require("juvimter.config")

local M = {}

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

-- Official Kitty Graphics Protocol Unicode Placeholder diacritics table (rows/cols 0..296)
-- stylua: ignore
local DIACRITICS_HEX = vim.split(
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244",
  ","
)

local diacritic_chars = setmetatable({}, {
  __index = function(t, idx)
    local hex = DIACRITICS_HEX[idx]
    local ch = hex and vim.fn.nr2char(tonumber(hex, 16)) or ""
    t[idx] = ch
    return ch
  end,
})

local cache_dir = vim.fn.stdpath("cache") .. "/juvimter/images"
local next_image_id = 0x020001 -- 24-bit IDs avoiding low IDs used by other plugins
local transmitted = {} ---@type table<string, { id: number, path: string, width: number, height: number, cols: number, rows: number, hl: string }>
local term_cell_size = nil

--- Detect terminal graphics capability.
---@return { supported: boolean, unicode_placeholders: boolean, in_tmux: boolean, name: string }
function M.detect_terminal()
  local backend = config.options.images.backend
  local in_tmux = (os.getenv("TMUX") ~= nil and os.getenv("TMUX") ~= "")

  if backend == "none" or not config.options.images.enabled then
    return { supported = false, unicode_placeholders = false, in_tmux = in_tmux, name = "disabled" }
  end
  if backend == "kitty_unicode" then
    return { supported = true, unicode_placeholders = true, in_tmux = in_tmux, name = "kitty_unicode" }
  end

  local term = (os.getenv("TERM") or ""):lower()
  local term_prog = (os.getenv("TERM_PROGRAM") or ""):lower()

  if term_prog:find("ghostty", 1, true) or os.getenv("GHOSTTY_RESOURCES_DIR") then
    return { supported = true, unicode_placeholders = true, in_tmux = in_tmux, name = "ghostty" }
  end
  if term:find("kitty", 1, true) or os.getenv("KITTY_WINDOW_ID") then
    return { supported = true, unicode_placeholders = true, in_tmux = in_tmux, name = "kitty" }
  end
  return { supported = false, unicode_placeholders = false, in_tmux = in_tmux, name = term_prog ~= "" and term_prog or term }
end

--- Query terminal cell pixel dimensions via ioctl(TIOCGWINSZ).
---@return { cell_w: number, cell_h: number }
function M.cell_pixel_size()
  if term_cell_size then
    return term_cell_size
  end
  local cw, ch = 9, 18
  pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
      typedef struct {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
      } juvimter_winsize;
      int ioctl(int, unsigned long, ...);
    ]])
    local TIOCGWINSZ = vim.fn.has("linux") == 1 and 0x5413 or 0x40087468
    local sz = ffi.new("juvimter_winsize")
    if ffi.C.ioctl(1, TIOCGWINSZ, sz) == 0 and sz.ws_col > 0 and sz.ws_row > 0 and sz.ws_xpixel > 0 and sz.ws_ypixel > 0 then
      cw = sz.ws_xpixel / sz.ws_col
      ch = sz.ws_ypixel / sz.ws_row
    end
  end)
  term_cell_size = { cell_w = cw, cell_h = ch }
  return term_cell_size
end

vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("JuvimterImageResize", { clear = true }),
  callback = function()
    term_cell_size = nil
  end,
})

--- Parse image pixel dimensions directly from PNG or JPEG binary header (pure Lua).
---@param bytes string
---@param mime string
---@return number, number
function M.parse_dimensions(bytes, mime)
  if mime == "image/png" and #bytes >= 24 and bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
    local b1, b2, b3, b4 = bytes:byte(17, 20)
    local h1, h2, h3, h4 = bytes:byte(21, 24)
    local w = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    local h = ((h1 * 256 + h2) * 256 + h3) * 256 + h4
    if w > 0 and h > 0 then
      return w, h
    end
  elseif (mime == "image/jpeg" or mime == "image/jpg") and #bytes >= 4 and bytes:byte(1) == 0xFF and bytes:byte(2) == 0xD8 then
    local i = 3
    while i < #bytes - 8 do
      if bytes:byte(i) ~= 0xFF then
        break
      end
      local marker = bytes:byte(i + 1)
      local seg_len = bytes:byte(i + 2) * 256 + bytes:byte(i + 3)
      if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
        local h = bytes:byte(i + 5) * 256 + bytes:byte(i + 6)
        local w = bytes:byte(i + 7) * 256 + bytes:byte(i + 8)
        if w > 0 and h > 0 then
          return w, h
        end
      end
      if seg_len < 2 then
        break
      end
      i = i + 2 + seg_len
    end
  end
  return 640, 480
end

---@param seq string
---@param in_tmux boolean
local function write_tty(seq, in_tmux)
  if in_tmux then
    pcall(vim.fn.system, { "tmux", "set", "-p", "allow-passthrough", "all" })
    seq = "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
  end
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(seq)
  else
    io.stdout:write(seq)
    io.stdout:flush()
  end
end

---@param opts table<string, string|number>
---@param payload? string
---@param in_tmux boolean
local function kitty_cmd(opts, payload, in_tmux)
  local parts = {}
  for k, v in pairs(opts) do
    parts[#parts + 1] = string.format("%s=%s", k, v)
  end
  local seq = "\27_G" .. table.concat(parts, ",") .. (payload and (";" .. payload) or "") .. "\27\\"
  write_tty(seq, in_tmux)
end

--- Compute terminal grid size (cols, rows) fitting within max bounds while preserving aspect ratio.
--- Supports smart upscaling of small plots and user zoom factor.
---@param px_w number
---@param px_h number
---@param max_cols number
---@param max_rows number
---@param opts? { scale?: number, min_rows?: number, max_upscale?: number, fill?: boolean }
---@return number, number
function M.fit_cells(px_w, px_h, max_cols, max_rows, opts)
  opts = opts or {}
  local sz = M.cell_pixel_size()
  local raw_cols = math.max(1, px_w / sz.cell_w)
  local raw_rows = math.max(1, px_h / sz.cell_h)

  local user_scale = opts.scale or 1.0
  local min_rows = opts.min_rows or 0
  local max_upscale = opts.max_upscale or (config.options.images.max_upscale or 2.5)

  local fit_scale = math.min(max_cols / raw_cols, max_rows / raw_rows)
  local target_scale

  if opts.fill then
    -- Lightbox mode: fill available window cleanly up to max_upscale
    target_scale = math.min(fit_scale, max_upscale) * user_scale
  else
    target_scale = math.min(1.0, fit_scale)
    -- Upscale tiny/low-DPI images so they stay readable inline
    if min_rows > 0 and (raw_rows * target_scale) < min_rows then
      local needed = min_rows / raw_rows
      target_scale = math.min(fit_scale, math.min(needed, max_upscale))
    end
    target_scale = target_scale * user_scale
  end

  -- Never exceed max_cols / max_rows bounds (except slight zoom within max_cols)
  local final_scale = math.min(target_scale, fit_scale)
  local cols = math.max(4, math.floor(raw_cols * final_scale + 0.5))
  local rows = math.max(2, math.floor(raw_rows * final_scale + 0.5))
  return cols, rows
end

--- Save base64 image data to cache file and return metadata + path.
---@param b64_data string|string[]
---@param mime string
---@return { path: string, width: number, height: number, hash: string }?
function M.ensure_cached(b64_data, mime)
  local raw_b64 = type(b64_data) == "table" and table.concat(b64_data, "") or tostring(b64_data or "")
  raw_b64 = raw_b64:gsub("%s+", "")
  if raw_b64 == "" then
    return nil
  end

  local hash = vim.fn.sha256(raw_b64):sub(1, 20)
  local ext = mime == "image/jpeg" and "jpg" or "png"
  vim.fn.mkdir(cache_dir, "p")
  local path = cache_dir .. "/" .. hash .. "." .. ext

  local ok_dec, bytes = pcall(vim.base64.decode, raw_b64)
  if not ok_dec or not bytes then
    return nil
  end

  if vim.fn.filereadable(path) == 0 then
    local f = io.open(path, "wb")
    if f then
      f:write(bytes)
      f:close()
    end
  end

  local w, h = M.parse_dimensions(bytes, mime)
  return { path = path, width = w, height = h, hash = hash }
end

--- Transmit a cached PNG to the terminal and return Unicode placeholder virt_lines.
---@param cached { path: string, width: number, height: number, hash: string }
---@param cols number
---@param rows number
---@param term table
---@return table[]
local function build_kitty_grid(cached, cols, rows, term)
  local cache_key = string.format("%s_%dx%d", cached.hash, cols, rows)
  local entry = transmitted[cache_key]

  if not entry then
    local id = next_image_id
    next_image_id = next_image_id + 1
    if next_image_id > 0xFFFFFE then
      next_image_id = 0x020001
    end

    local hl = string.format("JuvimterImg_%x", id)
    vim.api.nvim_set_hl(0, hl, { fg = id, sp = 1, nocombine = true })

    local b64_path = vim.base64.encode(cached.path)
    kitty_cmd({ a = "t", f = 100, t = "f", i = id, q = 2 }, b64_path, term.in_tmux)
    kitty_cmd({ a = "p", U = 1, i = id, p = 1, c = cols, r = rows, q = 2 }, nil, term.in_tmux)

    entry = {
      id = id,
      path = cached.path,
      width = cached.width,
      height = cached.height,
      cols = cols,
      rows = rows,
      hl = hl,
    }
    transmitted[cache_key] = entry
  end

  local lines = {}
  local tail_placeholders = string.rep(PLACEHOLDER, math.max(0, cols - 1))
  for r = 1, rows do
    local row_str = PLACEHOLDER .. diacritic_chars[r] .. diacritic_chars[1] .. tail_placeholders
    lines[#lines + 1] = { { row_str, entry.hl } }
  end
  return lines
end

--- Prepare virtual lines to render an image inline below a cell.
--- Returns: virt_lines (array of extmark chunk lines), image_path (for preview/external open).
---@param b64_data string|string[]
---@param mime string
---@param win_width? number
---@param scale? number
---@return table[], string?
function M.render_virt_lines(b64_data, mime, win_width, scale)
  local cached = M.ensure_cached(b64_data, mime)
  if not cached then
    return { { { " [Image decode error]", "JuvimterOutputError" } } }, nil
  end

  local icon = config.options.ui.icons.image
  local term = M.detect_terminal()

  if not term.supported or not term.unicode_placeholders or mime ~= "image/png" or vim.fn.has("gui_running") == 1 then
    local badge = string.format(
      " %s Image (%dx%d %s) — %s preview · %s open",
      icon,
      cached.width,
      cached.height,
      mime:gsub("^image/", ""):upper(),
      config.options.keymaps.preview_image or "<leader>jp",
      config.options.keymaps.open_image or "<leader>ji"
    )
    return { { { badge, "JuvimterImageBadge" } } }, cached.path
  end

  local cfg_max_w = config.options.images.max_width or 120
  local max_w = (cfg_max_w > 0) and cfg_max_w or 200
  if win_width and win_width > 12 then
    max_w = math.min(max_w, win_width - 6)
  end
  local zoom = scale or 1.0
  local max_h = math.floor((config.options.images.max_height or 30) * math.max(1.0, zoom))
  local min_h = config.options.images.min_height or 12
  local cols, rows = M.fit_cells(cached.width, cached.height, max_w, max_h, {
    scale = zoom,
    min_rows = min_h,
  })

  local lines = build_kitty_grid(cached, cols, rows, term)
  return lines, cached.path
end

--- Open a large interactive floating preview (lightbox) of a cached PNG image inside Neovim.
---@param path string
function M.open_preview(path)
  if not path or vim.fn.filereadable(path) == 0 then
    vim.notify("juvimter: image file not found", vim.log.levels.WARN)
    return
  end

  local term = M.detect_terminal()
  if not term.supported or not term.unicode_placeholders or not path:match("%.png$") then
    M.open_external(path)
    return
  end

  local f = io.open(path, "rb")
  if not f then
    M.open_external(path)
    return
  end
  local bytes = f:read("*a")
  f:close()
  local px_w, px_h = M.parse_dimensions(bytes, "image/png")
  local hash = vim.fn.sha256(bytes):sub(1, 20)
  local cached = { path = path, width = px_w, height = px_h, hash = hash }

  local ui = vim.api.nvim_list_uis()[1]
  local win_w = math.max(40, math.floor((ui and ui.width or 120) * 0.88))
  local win_h = math.max(16, math.floor((ui and ui.height or 40) * 0.84))
  local row = math.floor(((ui and ui.height or 40) - win_h) / 2)
  local col = math.floor(((ui and ui.width or 120) - win_w) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = win_w,
    height = win_h,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = string.format(" 󰋩 Image Preview (%dx%d)  [+/-: zoom · 0: fit · o: external · q: close] ", px_w, px_h),
    title_pos = "center",
  })

  local ns = vim.api.nvim_create_namespace("juvimter_img_preview")
  local zoom = 1.0

  local function render_preview()
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local cols, rows = M.fit_cells(px_w, px_h, win_w - 2, win_h - 1, {
      scale = zoom,
      max_upscale = 4.0,
      fill = true,
    })
    local pad_left = math.max(0, math.floor((win_w - cols) / 2))
    local pad_top = math.max(0, math.floor((win_h - rows) / 2))
    local grid = build_kitty_grid(cached, cols, rows, term)

    local vlines = {}
    for _ = 1, pad_top do
      vlines[#vlines + 1] = { { "", "Normal" } }
    end
    for _, gl in ipairs(grid) do
      if pad_left > 0 then
        vlines[#vlines + 1] = { { string.rep(" ", pad_left), "Normal" }, gl[1] }
      else
        vlines[#vlines + 1] = gl
      end
    end
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_lines = vlines,
      virt_lines_above = false,
    })
  end

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "o", function()
    M.open_external(path)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "+", function()
    zoom = math.min(2.5, zoom + 0.2)
    render_preview()
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "=", function()
    zoom = math.min(2.5, zoom + 0.2)
    render_preview()
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "-", function()
    zoom = math.max(0.3, zoom - 0.2)
    render_preview()
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "0", function()
    zoom = 1.0
    render_preview()
  end, { buffer = buf, silent = true })

  render_preview()
end

--- Clear all transmitted Kitty images (called on VimLeavePre or manual refresh).
function M.clear_all()
  local term = M.detect_terminal()
  if term.supported then
    kitty_cmd({ a = "d", d = "A", q = 2 }, nil, term.in_tmux)
  end
  transmitted = {}
end

--- Open an image file externally with the system viewer.
---@param path string
function M.open_external(path)
  if not path or vim.fn.filereadable(path) == 0 then
    vim.notify("juvimter: image file not found", vim.log.levels.WARN)
    return
  end
  local cmd
  if vim.fn.has("mac") == 1 then
    cmd = { "open", path }
  elseif vim.fn.has("win32") == 1 then
    cmd = { "cmd.exe", "/c", "start", "", path }
  else
    cmd = { "xdg-open", path }
  end
  vim.fn.jobstart(cmd, { detach = true })
end

return M

---@class JuvimterKeymaps
---@field run_and_advance string
---@field run_in_place string
---@field run_all string
---@field run_above string
---@field run_below string
---@field add_code_below string
---@field add_code_above string
---@field add_md_below string
---@field add_md_above string
---@field delete_cell string
---@field move_cell_up string
---@field move_cell_down string
---@field toggle_cell_type string
---@field edit_markdown string
---@field split_cell string
---@field merge_cell_below string
---@field clear_output string
---@field clear_all_outputs string
---@field toggle_output string
---@field inspect_output string
---@field open_image string
---@field select_kernel string
---@field interrupt_kernel string
---@field restart_kernel string
---@field variables string
---@field next_cell string
---@field prev_cell string

---@class JuvimterConfig
local M = {}

---@type table
M.defaults = {
  -- Automatically attach to *.ipynb files via BufReadCmd / BufWriteCmd
  auto_attach = true,

  -- Automatically start the notebook's preferred kernel when running the first cell
  -- (when false, prompts the kernel picker until you choose a kernel explicitly)
  auto_start_kernel = false,

  -- Directories to scan for Python virtual environments (in addition to cwd .venv and Jupyter kernelspecs)
  venv_dirs = {
    "~/.venvs",
    "~/.virtualenvs",
    "~/.local/share/virtualenvs",
    "~/miniconda3/envs",
    "~/anaconda3/envs",
    "~/miniforge3/envs",
  },

  -- Python executable used to host kernel_bridge.py (auto-detected if nil)
  bridge_python = nil,

  -- UI appearance (VS Code Notebook inspired)
  ui = {
    -- Maximum number of output text lines shown inline before folding
    max_output_lines = 30,
    -- Maximum line width for cell borders (0 = adapt to window width)
    border_width = 0,
    -- Render markdown cells visually when cursor is outside the cell
    render_markdown = true,
    -- Show active/inactive left accent bar in sign column
    show_cell_bar = true,
    -- Show keybind hints on active cell header
    show_hints = true,
    -- Icons (Nerd Font defaults; works nicely with CaskaydiaCove, JetBrainsMono, etc.)
    icons = {
      code = "󰌠",
      julia = "",
      r = "󰟔",
      markdown = "",
      raw = "󰈙",
      ok = "✓",
      error = "✗",
      queued = "◷",
      kernel = "󰣖",
      image = "󰋩",
      bar_active = "▎",
      bar_inactive = "▏",
      output_bar = "┃",
      spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    },
  },

  -- Inline image rendering
  images = {
    enabled = true,
    -- "auto" (detect Ghostty/Kitty Unicode placeholders), "kitty_unicode", "none"
    backend = "auto",
    -- Max dimensions in terminal cells (0 = adapt to window width)
    max_width = 120,
    max_height = 30,
    -- Minimum target height in rows so small/low-DPI plots remain readable
    min_height = 12,
    -- Maximum upscale factor for small images
    max_upscale = 2.5,
  },

  -- Variable explorer window
  variables = {
    width = 0.72,
    height = 0.60,
    border = "rounded",
  },

  -- Default buffer-local keymaps (set to false to disable individual mappings)
  keymaps = {
    run_and_advance = "<S-CR>",
    run_in_place = "<C-CR>",
    run_all = "<leader>jA",
    run_above = "<leader>j^",
    run_below = "<leader>j$",
    add_code_below = "<leader>ja",
    add_code_above = "<leader>jO",
    add_md_below = "<leader>jm",
    add_md_above = "<leader>jM",
    delete_cell = "<leader>jd",
    move_cell_up = "<leader>jk",
    move_cell_down = "<leader>jj",
    toggle_cell_type = "<leader>jt",
    edit_markdown = "<CR>",
    split_cell = "<leader>js",
    merge_cell_below = "<leader>jJ",
    clear_output = "<leader>jc",
    clear_all_outputs = "<leader>jC",
    toggle_output = "<leader>jz",
    inspect_output = "<leader>jo",
    open_image = "<leader>ji",
    preview_image = "<leader>jp",
    zoom_in_image = "<leader>j+",
    zoom_out_image = "<leader>j-",
    zoom_reset_image = "<leader>j=",
    select_kernel = "<leader>jK",
    interrupt_kernel = "<leader>jI",
    restart_kernel = "<leader>jR",
    variables = "<leader>jv",
    next_cell = "]c",
    prev_cell = "[c",
  },
}

---@type table
M.options = vim.deepcopy(M.defaults)

--- Setup default highlight groups linked to standard colorscheme groups so they
--- automatically look great in Catppuccin, Tokyonight, Matugen, Gruvbox, etc.
function M.setup_highlights()
  local set = function(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end

  set("JuvimterCellHeader", { link = "Comment" })
  set("JuvimterCellHeaderActive", { link = "Function" })
  set("JuvimterCellBorder", { link = "FloatBorder" })
  set("JuvimterCellBorderActive", { link = "DiagnosticInfo" })
  set("JuvimterCellBarActive", { link = "DiagnosticInfo" })
  set("JuvimterCellBarInactive", { link = "LineNr" })
  set("JuvimterCellBarMarkdown", { link = "Special" })
  set("JuvimterExecCount", { link = "Number" })
  set("JuvimterStatusOk", { link = "DiagnosticOk" })
  set("JuvimterStatusError", { link = "DiagnosticError" })
  set("JuvimterStatusRunning", { link = "DiagnosticWarn" })
  set("JuvimterStatusQueued", { link = "Comment" })
  set("JuvimterHint", { link = "NonText" })

  set("JuvimterOutputBar", { link = "DiagnosticHint" })
  set("JuvimterOutputBarError", { link = "DiagnosticError" })
  set("JuvimterOutputText", { link = "Normal" })
  set("JuvimterOutputStderr", { link = "DiagnosticWarn" })
  set("JuvimterOutputError", { link = "DiagnosticError" })
  set("JuvimterOutputMeta", { link = "Comment" })
  set("JuvimterTableBorder", { link = "FloatBorder" })
  set("JuvimterTableHeader", { link = "Title" })
  set("JuvimterImageBadge", { link = "DiagnosticInfo" })

  set("JuvimterMdH1", { link = "Title" })
  set("JuvimterMdH2", { link = "Function" })
  set("JuvimterMdH3", { link = "Type" })
  set("JuvimterMdH4", { link = "Statement" })
  set("JuvimterMdBullet", { link = "Special" })
  set("JuvimterMdQuote", { link = "Comment" })
  set("JuvimterMdCode", { link = "String" })
  set("JuvimterMdBold", { bold = true })
  set("JuvimterMdItalic", { italic = true })
  set("JuvimterMdRule", { link = "FloatBorder" })
end

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  M.setup_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("JuvimterHighlights", { clear = true }),
    callback = function()
      M.setup_highlights()
    end,
  })
end

return M

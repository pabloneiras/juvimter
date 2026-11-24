# juvimter.nvim

A **VS Code-inspired Jupyter Notebook** experience natively inside **Neovim** — single plugin, pure Lua UI, lossless `nbformat 4.5` `.ipynb` editing, inline DataFrames & plots, and a built-in Variable Explorer.

> Edit, execute, and save standard `.ipynb` notebooks that open identically in **VS Code**, **JupyterLab**, and **Google Colab** — without stitching together 5 fragile plugins or dealing with `:UpdateRemotePlugins` / `pynvim`.

---

## Features

- **Native `.ipynb` support (`nbformat 4.5`)**: Opens `.ipynb` files transparently and saves valid, pretty-printed JSON preserving cell IDs, metadata, `execution_count`, text outputs, HTML tables, and base64 PNG plots.
- **VS Code Notebook UX inside Neovim**:
  - Sleek cell cards with execution counters (`[1]`, `[*]`, `[ ]`), elapsed timers (`✓ 0.14s`, `✗`), animated running spinners, and an active left gutter accent bar (`▎`).
  - **Native LSP, Treesitter & Completion across all code cells** (`basedpyright`, `pyright`, `ruff`, `julials`, `blink.cmp`, `nvim-cmp`) — variables defined in Cell 1 are immediately known in Cell 2, 3, 4.
  - **Clean Markdown cells**: rendered visually inline when navigating; press `<CR>` on any Markdown cell to edit pure Markdown in a floating editor (zero `# ` prefixes!).
- **Rich Inline Outputs**:
  - Real-time streaming `stdout` / `stderr` with full **ANSI color** support (colored Python/Julia tracebacks!).
  - **Pandas / Polars DataFrames** automatically rendered as clean Unicode box-drawing tables.
  - **Inline Matplotlib / Seaborn / PIL plots** via **Kitty Graphics Protocol Unicode Placeholders** (works natively in **Ghostty** and **Kitty**, with tmux passthrough; zero flicker on scroll/resize, zero ImageMagick dependency!). Clean clickable fallback badge on other terminals (`<leader>ji` opens externally).
- **VS Code-style Kernel Picker (`<leader>jK`)**:
  - Automatically discovers project `.venv` / `venv`, active `VIRTUAL_ENV` / `CONDA_PREFIX`, user venvs (`~/.venvs/*`, conda envs), and all registered Jupyter kernelspecs (Python, Julia `IJulia`, R `IRkernel`, etc.).
  - Uses `vim.ui.select` so it integrates automatically with `snacks.picker`, `telescope.nvim`, or `fzf-lua`.
- **Variable Explorer (`<leader>jv`)**:
  - Floating panel listing live kernel variables (`Name | Type | Shape/Size | Value`), with refresh (`r`) and full value inspection (`<CR>`).
- **Lualine / Statusline integration**: Displays active kernel, idle/busy state, and current cell (`Cell 2/6`).

---

## Requirements

- **Neovim `>= 0.10`**
- A Python environment with `jupyter_client` and `ipykernel` installed (or [`uv`](https://docs.astral.sh/uv/) for zero-setup bridge startup)
- *(Optional, for inline plots)* A terminal supporting Kitty Graphics Unicode Placeholders such as **Ghostty** or **Kitty**
- *(Optional)* A Nerd Font for crisp icons

---

## Installation

### LazyVim (`lua/plugins/juvimter.lua`)

```lua
return {
  {
    "pabloneiras/juvimter",
    lazy = false,
    opts = {
      -- Set to true to auto-start the matching kernel on first cell run
      auto_start_kernel = false,
      -- Extra directories to scan for Python virtualenvs
      venv_dirs = { "~/.venvs", "~/.virtualenvs", "~/miniconda3/envs" },
    },
  },
  -- Optional: show active kernel & cell counter in lualine
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      opts.sections = opts.sections or {}
      opts.sections.lualine_x = opts.sections.lualine_x or {}
      table.insert(opts.sections.lualine_x, 1, require("juvimter.statusline").lualine())
    end,
  },
}
```

### Standard `lazy.nvim`

```lua
{
  "pabloneiras/juvimter",
  lazy = false,
  opts = {},
}
```

Run `:checkhealth juvimter` to verify detected kernels, Python bridge, and inline graphics support.

---

## Default Keymaps (Buffer-local in `.ipynb`)

| Mode | Key | Action |
| :--- | :--- | :--- |
| `n`, `i` | `<S-CR>` | Run cell and advance to next cell (creates new cell at bottom) |
| `n`, `i` | `<C-CR>` | Run cell in place |
| `n` | `<leader>jA` | Run all cells |
| `n` | `<leader>j^` | Run cells above |
| `n` | `<leader>j$` | Run current cell and below |
| `n` | `<leader>ja` | Add code cell below |
| `n` | `<leader>jO` | Add code cell above |
| `n` | `<leader>jm` | Add markdown cell below |
| `n` | `<leader>jM` | Add markdown cell above |
| `n` | `<CR>` | Edit Markdown cell in clean floating editor (when on Markdown cell) |
| `n` | `<leader>jt` | Toggle cell type (`Code` ↔ `Markdown`) |
| `n` | `<leader>jd` | Delete current cell |
| `n` | `<leader>jk` / `<leader>jj` | Move cell up / down |
| `n` | `<leader>js` / `<leader>jJ` | Split cell at cursor / Merge with cell below |
| `n` | `<leader>jc` / `<leader>jC` | Clear cell output / Clear all outputs |
| `n` | `<leader>jz` | Collapse / expand cell output |
| `n` | `<leader>jo` | Inspect full cell output in floating window |
| `n` | `<leader>ji` | Open cell image/plot externally |
| `n` | `<leader>jK` | Select Jupyter kernel / Python venv |
| `n` | `<leader>jI` / `<leader>jR` | Interrupt / Restart kernel |
| `n` | `<leader>jv` | Open Variable Explorer |
| `n` | `]c` / `[c` | Jump to next / previous cell |
| `x`, `o` | `ic` / `ac` | Inner cell / Around cell textobjects |

---

## Commands

- `:Juvimter new [name.ipynb]` — Create and open a new notebook
- `:Juvimter kernel` — Open the kernel picker
- `:Juvimter run` / `run_all` / `run_above` / `run_below`
- `:Juvimter variables` — Open the Variable Explorer
- `:Juvimter interrupt` / `restart`
- `:Juvimter clear` / `clear_all`
- `:Juvimter health` — Run diagnostics

---

## Running Tests

```bash
# Lua unit tests (headless Neovim)
nvim --headless -u NONE --cmd "set rtp+=." -l tests/test_notebook.lua

# Python kernel bridge + nbformat 4.5 integration tests
python3 tests/test_bridge.py
```

---

## License

MIT — see [LICENSE](LICENSE).

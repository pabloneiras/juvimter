--- `:checkhealth juvimter` diagnostics.
local images = require("juvimter.images")
local kernel = require("juvimter.kernel")

local M = {}

function M.check()
  vim.health.start("juvimter.nvim")

  -- 1. Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10 detected (" .. tostring(vim.version()) .. ")")
  else
    vim.health.error("Neovim >= 0.10 is required")
  end

  -- 2. Kernel bridge script & Python/jupyter_client
  local bridge = kernel.bridge_script_path()
  if vim.fn.filereadable(bridge) == 1 then
    vim.health.ok("kernel_bridge.py found: " .. bridge)
  else
    vim.health.error("kernel_bridge.py missing at " .. bridge)
  end

  local cmd, err = kernel.resolve_bridge_cmd(nil, vim.uv.cwd())
  if cmd then
    vim.health.ok("Bridge command: " .. table.concat(cmd, " "))
  else
    vim.health.error(err or "No Python with jupyter_client found")
  end

  -- 3. Discovered kernels
  local kernels = kernel.discover_kernels(vim.uv.cwd())
  if #kernels > 0 then
    vim.health.ok(string.format("Discovered %d kernel(s):", #kernels))
    for _, k in ipairs(kernels) do
      local status = (k.kind == "venv" and not k.has_ipykernel) and " (missing ipykernel)" or " (ready)"
      vim.health.info(string.format("  - %s [%s/%s]%s", k.display_name, k.language, k.kind, status))
    end
  else
    vim.health.warn("No Jupyter kernels or Python virtualenvs discovered yet")
  end

  -- 4. Inline graphics support
  local term = images.detect_terminal()
  if term.supported and term.unicode_placeholders then
    vim.health.ok(string.format("Inline plots enabled via Kitty Graphics Unicode Placeholders (%s)", term.name))
  else
    vim.health.warn(
      string.format("Terminal '%s' does not advertise Kitty Graphics Unicode Placeholders; plots will show clickable badges (<leader>ji to open externally)", term.name)
    )
  end
end

return M

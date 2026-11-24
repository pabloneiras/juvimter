--- VS Code-style Kernel Picker using vim.ui.select
--- (automatically styled by snacks.picker, telescope, fzf-lua, or dressing.nvim).
local kernel = require("juvimter.kernel")

local M = {}

---@param cwd string
---@param active_spec? JuvimterKernelSpec
---@param on_choice fun(spec: JuvimterKernelSpec)
function M.select_kernel(cwd, active_spec, on_choice)
  local kernels = kernel.discover_kernels(cwd)
  if #kernels == 0 then
    vim.notify("juvimter: no Jupyter kernels or Python virtualenvs found", vim.log.levels.WARN)
    return
  end

  vim.ui.select(kernels, {
    prompt = "Select Jupyter Kernel:",
    format_item = function(item)
      local active_mark = (active_spec and active_spec.id == item.id) and "● " or "  "
      local lang = item.language or "python"
      local status = ""
      if item.kind == "venv" then
        status = item.has_ipykernel and " [ready]" or " [needs ipykernel]"
      else
        status = " [kernelspec]"
      end
      local path_hint = item.python_path and (" · " .. vim.fn.fnamemodify(item.python_path, ":~")) or ""
      return string.format("%s%s (%s)%s%s", active_mark, item.display_name, lang, status, path_hint)
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.kind == "venv" and choice.has_ipykernel == false then
      vim.notify(
        string.format(
          "juvimter: '%s' does not have ipykernel installed. Run: %s -m pip install ipykernel",
          choice.name,
          choice.python_path
        ),
        vim.log.levels.ERROR
      )
      return
    end
    on_choice(choice)
  end)
end

return M

--- Jupyter kernel discovery and async JSON-RPC lifecycle manager.
--- Discovers Jupyter kernelspecs (Python, Julia, R, etc.) and Python virtualenvs
--- automatically — just like VS Code's Jupyter kernel picker.
local config = require("juvimter.config")

local M = {}

---@class JuvimterKernelSpec
---@field id string Unique identifier
---@field name string Kernel name (e.g. "python3", "my_venv", "julia-1.11")
---@field display_name string Human-readable label
---@field language string Programming language ("python", "julia", "r", ...)
---@field kind "kernelspec"|"venv"
---@field python_path? string Direct python executable (when kind == "venv")
---@field resource_dir? string Kernelspec directory (when kind == "kernelspec")
---@field has_ipykernel? boolean

---@type table<number, JuvimterSession>
M.sessions = {}

--- Locate python/kernel_bridge.py relative to this Lua module.
---@return string
function M.bridge_script_path()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local plugin_root = vim.fn.fnamemodify(src, ":h:h:h")
  return plugin_root .. "/python/kernel_bridge.py"
end

---@param py string
---@param module_name string
---@return boolean
local function python_has_module(py, module_name)
  if not py or vim.fn.executable(py) ~= 1 then
    return false
  end
  -- Fast filesystem check in site-packages before spawning python
  local venv_root = vim.fn.fnamemodify(py, ":h:h")
  local sp_matches = vim.fn.glob(venv_root .. "/lib/python*/site-packages/" .. module_name, false, true)
  if #sp_matches > 0 then
    return true
  end
  local sp_win = vim.fn.glob(venv_root .. "/Lib/site-packages/" .. module_name, false, true)
  if #sp_win > 0 then
    return true
  end
  -- Fallback quick check for system python or non-standard layouts
  local res = vim.fn.system({ py, "-c", "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('" .. module_name .. "') else 1)" })
  local _ = res
  return vim.v.shell_error == 0
end

--- Collect candidate Python executables from cwd, active env, and configured venv_dirs.
---@param cwd? string
---@return { path: string, name: string, source: string }[]
local function collect_venvs(cwd)
  cwd = cwd or vim.uv.cwd() or "."
  local seen = {}
  local found = {}

  local function add(py, name, source)
    if not py or py == "" then
      return
    end
    local real = vim.uv.fs_realpath(py) or py
    if seen[real] or vim.fn.executable(py) ~= 1 then
      return
    end
    seen[real] = true
    found[#found + 1] = { path = py, name = name, source = source }
  end

  -- 1. Active VIRTUAL_ENV / CONDA_PREFIX
  for _, env_var in ipairs({ "VIRTUAL_ENV", "CONDA_PREFIX" }) do
    local dir = os.getenv(env_var)
    if dir and dir ~= "" then
      local py = dir .. "/bin/python"
      add(py, vim.fn.fnamemodify(dir, ":t"), "active")
    end
  end

  -- 2. Project local virtualenvs (walking up to git root)
  local dir = cwd
  for _ = 1, 4 do
    for _, sub in ipairs({ ".venv", "venv", ".conda", "env" }) do
      local py = dir .. "/" .. sub .. "/bin/python"
      if vim.fn.executable(py) == 1 then
        add(py, vim.fn.fnamemodify(dir, ":t") .. "/" .. sub, "project")
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end

  -- 3. Configured global venv directories (e.g. ~/.venvs/*)
  for _, pattern_dir in ipairs(config.options.venv_dirs or {}) do
    local expanded = vim.fn.expand(pattern_dir)
    if vim.fn.isdirectory(expanded) == 1 then
      local entries = vim.fn.glob(expanded .. "/*", false, true)
      table.sort(entries)
      for _, entry in ipairs(entries) do
        local py = entry .. "/bin/python"
        if vim.fn.executable(py) == 1 then
          add(py, vim.fn.fnamemodify(entry, ":t"), "venv")
        end
      end
    end
  end

  return found
end

--- Discover installed Jupyter kernelspecs from standard Jupyter data paths.
---@return JuvimterKernelSpec[]
local function collect_kernelspecs()
  local dirs = {}
  local xdg = os.getenv("XDG_DATA_HOME") or vim.fn.expand("~/.local/share")
  dirs[#dirs + 1] = xdg .. "/jupyter/kernels"
  dirs[#dirs + 1] = vim.fn.expand("~/.local/share/jupyter/kernels")
  dirs[#dirs + 1] = "/usr/local/share/jupyter/kernels"
  dirs[#dirs + 1] = "/usr/share/jupyter/kernels"
  local jpath = os.getenv("JUPYTER_PATH")
  if jpath and jpath ~= "" then
    for _, p in ipairs(vim.split(jpath, ":", { plain = true })) do
      dirs[#dirs + 1] = p .. "/kernels"
    end
  end

  local seen_dirs = {}
  local seen_names = {}
  local specs = {}

  for _, root in ipairs(dirs) do
    local real_root = vim.uv.fs_realpath(root) or root
    if not seen_dirs[real_root] and vim.fn.isdirectory(real_root) == 1 then
      seen_dirs[real_root] = true
      local kdirs = vim.fn.glob(real_root .. "/*", false, true)
      table.sort(kdirs)
      for _, kdir in ipairs(kdirs) do
        local kjson = kdir .. "/kernel.json"
        if vim.fn.filereadable(kjson) == 1 then
          local name = vim.fn.fnamemodify(kdir, ":t")
          if not seen_names[name] then
            local ok, content = pcall(vim.fn.readfile, kjson)
            if ok then
              local ok_dec, parsed = pcall(vim.json.decode, table.concat(content, "\n"))
              if ok_dec and type(parsed) == "table" then
                seen_names[name] = true
                local argv = type(parsed.argv) == "table" and parsed.argv or {}
                local py_bin = (type(argv[1]) == "string" and argv[1]:find("python", 1, true)) and argv[1] or nil
                specs[#specs + 1] = {
                  id = "spec:" .. name,
                  name = name,
                  display_name = parsed.display_name or name,
                  language = (parsed.language or "python"):lower(),
                  kind = "kernelspec",
                  python_path = py_bin,
                  resource_dir = kdir,
                  has_ipykernel = true,
                }
              end
            end
          end
        end
      end
    end
  end

  return specs
end

--- Discover all selectable kernels (kernelspecs + Python virtualenvs).
---@param cwd? string
---@return JuvimterKernelSpec[]
function M.discover_kernels(cwd)
  local kernels = {}
  local seen_py = {}

  -- Project & active venvs first (just like VS Code!)
  local venvs = collect_venvs(cwd)
  for _, v in ipairs(venvs) do
    if v.source == "project" or v.source == "active" then
      local real = vim.uv.fs_realpath(v.path) or v.path
      seen_py[real] = true
      kernels[#kernels + 1] = {
        id = "venv:" .. v.path,
        name = v.name,
        display_name = string.format("%s (%s)", v.name, v.source == "project" and "project venv" or "active venv"),
        language = "python",
        kind = "venv",
        python_path = v.path,
        has_ipykernel = python_has_module(v.path, "ipykernel"),
      }
    end
  end

  -- Registered Jupyter kernelspecs (Python, Julia, R, etc.)
  local specs = collect_kernelspecs()
  for _, s in ipairs(specs) do
    if s.python_path then
      local real = vim.uv.fs_realpath(s.python_path) or s.python_path
      seen_py[real] = true
    end
    kernels[#kernels + 1] = s
  end

  -- Remaining user virtualenvs (~/.venvs/*, conda, etc.)
  for _, v in ipairs(venvs) do
    if v.source ~= "project" and v.source ~= "active" then
      local real = vim.uv.fs_realpath(v.path) or v.path
      if not seen_py[real] then
        seen_py[real] = true
        kernels[#kernels + 1] = {
          id = "venv:" .. v.path,
          name = v.name,
          display_name = string.format("%s (venv)", v.name),
          language = "python",
          kind = "venv",
          python_path = v.path,
          has_ipykernel = python_has_module(v.path, "ipykernel"),
        }
      end
    end
  end

  -- System python3 fallback if ipykernel is installed globally
  local sys_py = vim.fn.exepath("python3")
  if sys_py ~= "" then
    local real = vim.uv.fs_realpath(sys_py) or sys_py
    if not seen_py[real] and python_has_module(sys_py, "ipykernel") then
      kernels[#kernels + 1] = {
        id = "venv:" .. sys_py,
        name = "python3",
        display_name = "Python 3 (system)",
        language = "python",
        kind = "venv",
        python_path = sys_py,
        has_ipykernel = true,
      }
    end
  end

  return kernels
end

--- Choose the best command to launch python/kernel_bridge.py (needs jupyter_client).
---@param preferred_python? string
---@param cwd? string
---@return string[]?, string?
function M.resolve_bridge_cmd(preferred_python, cwd)
  local script = M.bridge_script_path()
  if vim.fn.filereadable(script) ~= 1 then
    return nil, "kernel_bridge.py not found at " .. script
  end

  local candidates = {}
  if config.options.bridge_python then
    candidates[#candidates + 1] = vim.fn.expand(config.options.bridge_python)
  end
  if preferred_python then
    candidates[#candidates + 1] = preferred_python
  end
  for _, v in ipairs(collect_venvs(cwd)) do
    candidates[#candidates + 1] = v.path
  end
  local sys_py = vim.fn.exepath("python3")
  if sys_py ~= "" then
    candidates[#candidates + 1] = sys_py
  end

  local seen = {}
  for _, py in ipairs(candidates) do
    local real = vim.uv.fs_realpath(py) or py
    if not seen[real] then
      seen[real] = true
      if python_has_module(py, "jupyter_client") then
        return { py, "-u", script }, nil
      end
    end
  end

  -- Zero-setup fallback: use `uv run --with jupyter-client` if uv is installed
  if vim.fn.executable("uv") == 1 then
    return { "uv", "run", "--quiet", "--with", "jupyter-client", "python3", "-u", script }, nil
  end

  return nil, "Could not find Python with 'jupyter_client' installed (or 'uv'). Install jupyter_client or ipykernel in your venv."
end

--- Pick the best default kernel matching notebook metadata.
---@param nb table
---@param cwd? string
---@return JuvimterKernelSpec?
function M.pick_default_kernel(nb, cwd)
  local kernels = M.discover_kernels(cwd)
  if #kernels == 0 then
    return nil
  end

  local wanted_name = nb.metadata and nb.metadata.kernelspec and nb.metadata.kernelspec.name
  local wanted_lang = nb.metadata and nb.metadata.kernelspec and nb.metadata.kernelspec.language
  if wanted_lang then
    wanted_lang = wanted_lang:lower()
  end

  -- 1. Exact kernelspec name match
  if wanted_name then
    for _, k in ipairs(kernels) do
      if k.name == wanted_name and k.has_ipykernel ~= false then
        return k
      end
    end
  end

  -- 2. Language match with ipykernel available
  if wanted_lang then
    for _, k in ipairs(kernels) do
      if k.language == wanted_lang and k.has_ipykernel ~= false then
        return k
      end
    end
  end

  -- 3. First ready kernel
  for _, k in ipairs(kernels) do
    if k.has_ipykernel ~= false then
      return k
    end
  end
  return kernels[1]
end

-- ============================================================================
-- KernelSession (one active bridge + kernel per notebook buffer)
-- ============================================================================

---@class JuvimterSession
---@field bufnr number
---@field job_id number?
---@field state "stopped"|"starting"|"idle"|"busy"|"error"
---@field spec JuvimterKernelSpec?
---@field kernel_info table?
---@field next_req_id number
---@field pending table<number, fun(msg: table)>
---@field exec_handlers table<number, table>
---@field on_state_change? fun(state: string)
---@field _stdout_buf string
local Session = {}
Session.__index = Session

---@param bufnr number
---@param on_state_change? fun(state: string)
---@return JuvimterSession
function M.new_session(bufnr, on_state_change)
  local self = setmetatable({
    bufnr = bufnr,
    job_id = nil,
    state = "stopped",
    spec = nil,
    kernel_info = nil,
    next_req_id = 1,
    pending = {},
    exec_handlers = {},
    on_state_change = on_state_change,
    _stdout_buf = "",
    _ready_callbacks = {},
    _bridge_ready = false,
  }, Session)
  M.sessions[bufnr] = self
  return self
end

---@param bufnr number
---@return JuvimterSession?
function M.get_session(bufnr)
  return M.sessions[bufnr]
end

---@param new_state string
function Session:_set_state(new_state)
  self.state = new_state
  if self.on_state_change then
    vim.schedule(function()
      self.on_state_change(new_state)
    end)
  end
end

---@param line string
function Session:_handle_line(line)
  if line == "" then
    return
  end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    return
  end

  local mtype = msg.type
  if mtype == "ready" then
    self._bridge_ready = true
    local cbs = self._ready_callbacks
    self._ready_callbacks = {}
    for _, cb in ipairs(cbs) do
      cb()
    end
    return
  elseif mtype == "fatal" then
    self:_set_state("error")
    vim.schedule(function()
      vim.notify("juvimter: " .. tostring(msg.error), vim.log.levels.ERROR)
    end)
    return
  elseif mtype == "response" then
    local cb = self.pending[msg.id]
    self.pending[msg.id] = nil
    if cb then
      vim.schedule(function()
        cb(msg)
      end)
    end
    return
  end

  local h = msg.id and self.exec_handlers[msg.id]
  if mtype == "status" then
    if msg.state == "busy" or msg.state == "idle" then
      self:_set_state(msg.state)
    end
    if h and h.on_status then
      vim.schedule(function()
        h.on_status(msg.state)
      end)
    end
  elseif mtype == "output" then
    if h and h.on_output then
      vim.schedule(function()
        h.on_output(msg.output, msg.update)
      end)
    end
  elseif mtype == "clear_output" then
    if h and h.on_clear_output then
      vim.schedule(function()
        h.on_clear_output(msg.wait)
      end)
    end
  elseif mtype == "execute_reply" then
    self.exec_handlers[msg.id] = nil
    self:_set_state("idle")
    if h and h.on_done then
      vim.schedule(function()
        h.on_done(msg)
      end)
    end
  end
end

---@param method string
---@param params? table
---@param cb? fun(msg: table)
---@return number
function Session:_send(method, params, cb)
  local id = self.next_req_id
  self.next_req_id = id + 1
  if cb then
    self.pending[id] = cb
  end
  local payload = vim.json.encode({ id = id, method = method, params = params or {} }) .. "\n"
  if self.job_id and self.job_id > 0 then
    vim.fn.chansend(self.job_id, payload)
  end
  return id
end

--- Ensure bridge process is spawned, then start the requested kernel spec.
---@param spec JuvimterKernelSpec
---@param cwd string
---@param cb? fun(ok: boolean, info_or_err: any)
function Session:start(spec, cwd, cb)
  if self.job_id then
    self:shutdown()
  end

  local cmd, err = M.resolve_bridge_cmd(spec.python_path, cwd)
  if not cmd then
    self:_set_state("error")
    if cb then
      cb(false, err)
    end
    return
  end

  self.spec = spec
  self._bridge_ready = false
  self._stdout_buf = ""
  self:_set_state("starting")

  local stderr_lines = {}
  self.job_id = vim.fn.jobstart(cmd, {
    cwd = cwd,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for i, chunk in ipairs(data) do
        if i == 1 then
          self._stdout_buf = self._stdout_buf .. chunk
        else
          self:_handle_line(self._stdout_buf)
          self._stdout_buf = chunk
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            stderr_lines[#stderr_lines + 1] = line
          end
        end
      end
    end,
    on_exit = function(_, code)
      self.job_id = nil
      self._bridge_ready = false
      if self.state ~= "stopped" then
        self:_set_state(code == 0 and "stopped" or "error")
      end
    end,
  })

  if not self.job_id or self.job_id <= 0 then
    self.job_id = nil
    self:_set_state("error")
    if cb then
      cb(false, "Failed to spawn kernel_bridge.py")
    end
    return
  end

  local start_params = {
    kernel_name = spec.name,
    cwd = cwd,
  }
  if spec.kind == "venv" and spec.python_path then
    start_params.python_path = spec.python_path
  end

  local function send_start()
    self:_send("start", start_params, function(resp)
      if resp.ok then
        self.kernel_info = resp.result
        self:_set_state("idle")
        if cb then
          cb(true, resp.result)
        end
      else
        self:_set_state("error")
        if cb then
          cb(false, resp.error or table.concat(stderr_lines, "\n"))
        end
      end
    end)
  end

  if self._bridge_ready then
    send_start()
  else
    self._ready_callbacks[#self._ready_callbacks + 1] = send_start
  end
end

---@return boolean
function Session:is_running()
  return self.job_id ~= nil and (self.state == "idle" or self.state == "busy")
end

--- Execute code in the running kernel and stream outputs back via handlers.
---@param cell_id string
---@param code string
---@param handlers { on_status?: fun(s: string), on_output?: fun(o: table, upd?: boolean), on_clear_output?: fun(wait: boolean), on_done?: fun(reply: table) }
function Session:execute(cell_id, code, handlers)
  if not self:is_running() then
    if handlers and handlers.on_done then
      handlers.on_done({ status = "error", error = "Kernel is not running", elapsed_ms = 0 })
    end
    return
  end
  local id = self.next_req_id
  self.next_req_id = id + 1
  self.exec_handlers[id] = handlers or {}
  local payload = vim.json.encode({
    id = id,
    method = "execute",
    params = { cell_id = cell_id, code = code },
  }) .. "\n"
  vim.fn.chansend(self.job_id, payload)
end

---@param cb? fun(ok: boolean, err?: string)
function Session:interrupt(cb)
  if not self.job_id then
    if cb then
      cb(false, "No active kernel")
    end
    return
  end
  self:_send("interrupt", {}, function(resp)
    if cb then
      cb(resp.ok == true, resp.error)
    end
  end)
end

---@param cb? fun(ok: boolean, err?: string)
function Session:restart(cb)
  if not self.job_id then
    if cb then
      cb(false, "No active kernel")
    end
    return
  end
  self:_set_state("starting")
  self:_send("restart", {}, function(resp)
    if resp.ok then
      self:_set_state("idle")
    else
      self:_set_state("error")
    end
    if cb then
      cb(resp.ok == true, resp.error)
    end
  end)
end

---@param cb fun(ok: boolean, vars_or_err: any)
function Session:inspect_variables(cb)
  if not self:is_running() then
    cb(false, "No active kernel")
    return
  end
  self:_send("inspect_variables", {}, function(resp)
    if resp.ok then
      cb(true, resp.result or {})
    else
      cb(false, resp.error or "Failed to inspect variables")
    end
  end)
end

function Session:shutdown()
  if self.job_id then
    local jid = self.job_id
    self.job_id = nil
    self.state = "stopped"
    pcall(vim.fn.chansend, jid, vim.json.encode({ id = 0, method = "shutdown", params = {} }) .. "\n")
    vim.defer_fn(function()
      pcall(vim.fn.jobstop, jid)
    end, 300)
  else
    self.state = "stopped"
  end
  self.pending = {}
  self.exec_handlers = {}
end

--- Shutdown all sessions cleanly on Neovim exit.
function M.shutdown_all()
  for bufnr, sess in pairs(M.sessions) do
    sess:shutdown()
    M.sessions[bufnr] = nil
  end
end

return M

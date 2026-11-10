-- A small msgpack-RPC client for the tests: spawns `nvim --embed` or connects over TCP.
-- Runs inside `nvim -l`, so it only needs vim.uv and vim.mpack.
local uv = vim.uv
local NIL = vim.NIL

local Client = {}
Client.__index = Client

local function nonil(v)
  if v == NIL then
    return nil
  end
  return v
end

local function new()
  return setmetatable({ id = 0, responses = {}, notes = {} }, Client)
end

function Client:_reader()
  local unpack = vim.mpack.Unpacker()
  return function(err, data)
    assert(not err, err)
    if not data then
      self.closed = true
      return
    end
    local pos = 1
    while pos <= #data do
      local msg
      msg, pos = unpack(data, pos)
      if msg ~= nil then
        self:_dispatch(msg)
      end
    end
  end
end

function Client:_dispatch(m)
  if m[1] == 1 then
    self.responses[m[2]] = { err = nonil(m[3]), result = nonil(m[4]) }
  elseif m[1] == 2 then
    table.insert(self.notes, { method = m[2], args = m[3] })
  elseif m[1] == 0 then
    self.out:write(vim.mpack.encode({ 1, m[2], 'requests are not supported', NIL }))
  end
end

--- Spawn `nvim --embed --headless --clean` with `rtp` prepended to the runtimepath.
function Client.spawn(opts)
  local self = new()
  local stdin, stdout, stderr = uv.new_pipe(), uv.new_pipe(), uv.new_pipe()
  local args = { '--embed', '--headless', '--clean', '-n', '-i', 'NONE', '--cmd', 'set rtp^=' .. opts.rtp }
  vim.list_extend(args, opts.args or {})
  self.proc = uv.spawn(vim.v.progpath, { args = args, stdio = { stdin, stdout, stderr }, cwd = opts.cwd }, function()
    self.exited = true
  end)
  assert(self.proc, 'could not spawn nvim')
  self.out, self.input = stdin, stdout
  stdout:read_start(self:_reader())
  stderr:read_start(function(_, data)
    if data then
      self.stderr = (self.stderr or '') .. data
    end
  end)
  return self
end

--- Connect to a Neovim listening on `host:port`.
function Client.connect(host, port)
  local self = new()
  local tcp = uv.new_tcp()
  local done, cerr
  tcp:connect(host, port, function(err)
    cerr, done = err, true
  end)
  vim.wait(5000, function()
    return done
  end, 5)
  assert(done and not cerr, 'connect failed: ' .. tostring(cerr))
  self.out, self.input = tcp, tcp
  tcp:read_start(self:_reader())
  return self
end

function Client:request(method, ...)
  self.id = self.id + 1
  local id = self.id
  self.out:write(vim.mpack.encode({ 0, id, method, { ... } }))
  local ok = vim.wait(10000, function()
    return self.responses[id] ~= nil
  end, 2)
  if not ok then
    error(('timeout waiting for %s%s'):format(method, self.stderr and (': ' .. self.stderr) or ''), 2)
  end
  local r = self.responses[id]
  self.responses[id] = nil
  if r.err then
    local msg = type(r.err) == 'table' and r.err[2] or r.err
    error(('%s failed: %s'):format(method, tostring(msg)), 2)
  end
  return r.result
end

function Client:notify(method, ...)
  self.out:write(vim.mpack.encode({ 2, method, { ... } }))
end

--- Run Lua in the server: `lua('return ...', a, b)` sees a, b as `...`.
function Client:lua(code, ...)
  return self:request('nvim_exec_lua', code, { ... })
end

--- The nvimos events received since the last `clear()`.
function Client:events(domain)
  local out = {}
  for _, n in ipairs(self.notes) do
    local ev = n.args[1]
    if n.method == 'nvimos' and (not domain or ev.domain == domain) then
      out[#out + 1] = ev
    end
  end
  return out
end

function Client:clear()
  self.notes = {}
end

--- Wait until an event matches `pred`; return it.
function Client:wait_for(pred, timeout)
  local found
  vim.wait(timeout or 3000, function()
    for _, ev in ipairs(self:events()) do
      if pred(ev) then
        found = ev
        return true
      end
    end
    return false
  end, 5)
  return found
end

--- Let the server's main loop run, so pending events arrive.
function Client:settle(ms)
  self:request('nvim_eval', '1')
  vim.wait(ms or 50)
  self:request('nvim_eval', '1')
end

function Client:close()
  if self.proc and not self.exited then
    pcall(self.notify, self, 'nvim_command', 'qa!')
    vim.wait(2000, function()
      return self.exited
    end, 10)
    if not self.exited then
      self.proc:kill('sigkill')
    end
  end
  for _, h in ipairs({ self.out, self.input }) do
    if h and not h:is_closing() then
      h:close()
    end
  end
end

return Client

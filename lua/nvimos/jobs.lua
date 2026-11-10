-- Long-running commands for the GUI (an agent drafting an OpenSpec change), run without blocking
-- Neovim. Results arrive as `jobs` domain events and stay readable with get().
local repo = require('nvimos.repo')

local M = {}

--- Commands a client may start. Tests add their own.
M.allowed = { claude = true, openspec = true, backlog = true }

local jobs = {} -- id -> { id, label, argv, started, running, code, stdout, stderr, handle }
local next_id = 0

local function tail(s, n)
  s = s or ''
  return #s > n and s:sub(-n) or s
end

local function public(j)
  return {
    id = j.id,
    label = j.label,
    running = j.running,
    code = j.code or vim.NIL,
    started = j.started,
    stdout = tail(j.stdout, 8000),
    stderr = tail(j.stderr, 4000),
  }
end

local function emit(reason, j)
  require('nvimos').emit('jobs', reason, public(j))
end

--- Start `cmd args...` in the repo root. opts.stdin, opts.label. Returns the job id.
function M.start(cmd, args, opts)
  opts = opts or {}
  if not M.allowed[cmd] then
    error('nvimos: ' .. tostring(cmd) .. ' is not allowed as a job', 0)
  end
  local exe = vim.fn.exepath(cmd)
  if exe == '' then
    error('nvimos: ' .. cmd .. ' is not installed', 0)
  end
  next_id = next_id + 1
  local j = { id = next_id, label = opts.label or cmd, started = os.time(), running = true }
  jobs[j.id] = j
  local argv = { exe }
  vim.list_extend(argv, args or {})
  j.handle = vim.system(argv, { cwd = repo.root(), text = true, stdin = opts.stdin }, function(r)
    vim.schedule(function()
      j.running = false
      j.code, j.stdout, j.stderr = r.code, r.stdout, r.stderr
      j.handle = nil
      emit('finished', j)
    end)
  end)
  emit('started', j)
  return j.id
end

function M.get(id)
  local j = jobs[id]
  return j and public(j) or vim.NIL
end

function M.list()
  local out = {}
  for _, j in pairs(jobs) do
    out[#out + 1] = public(j)
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

function M.cancel(id)
  local j = jobs[id]
  if j and j.handle then
    j.handle:kill('sigterm')
  end
  return true
end

return M

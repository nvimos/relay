local Client = require('rpc')

local M = {}
local open = {}

--- A fresh headless Neovim with the plugin on the runtimepath.
function M.nvim(opts)
  opts = opts or {}
  local c = Client.spawn({ rtp = M.root, cwd = opts.cwd, args = opts.args })
  open[#open + 1] = c
  return c
end

function M.connect(host, port)
  local c = Client.connect(host, port)
  open[#open + 1] = c
  return c
end

--- A free TCP port on 127.0.0.1 (bind to port 0, read it, close).
function M.free_port()
  local tcp = vim.uv.new_tcp()
  tcp:bind('127.0.0.1', 0)
  local port = tcp:getsockname().port
  tcp:close()
  return port
end

local tmpdirs = {}

function M.tmpdir()
  local d = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(d, 'p')
  tmpdirs[#tmpdirs + 1] = d
  return d
end

function M.cleanup()
  for _, c in ipairs(open) do
    pcall(c.close, c)
  end
  open = {}
  for _, d in ipairs(tmpdirs) do
    vim.fn.delete(d, 'rf')
  end
  tmpdirs = {}
end

function M.write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end

--- Run git in `dir`; error on failure; return stdout.
function M.git(dir, ...)
  local cmd = { 'git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'core.autocrlf=false', ... }
  local r = vim.system(cmd, { cwd = dir, text = true }):wait()
  if r.code ~= 0 then
    error(('git %s: %s'):format(table.concat({ ... }, ' '), r.stderr), 2)
  end
  return r.stdout
end

--- A temp repo with one commit on main: a.txt (5 lines) and b.txt.
function M.repo()
  local d = M.tmpdir()
  M.git(d, 'init', '-q', '-b', 'main')
  -- Neovim's git calls use the repo config, not the -c flags of M.git.
  M.git(d, 'config', 'user.name', 'Test')
  M.git(d, 'config', 'user.email', 'test@example.com')
  M.git(d, 'config', 'core.autocrlf', 'false')
  M.write(d .. '/a.txt', { 'one', 'two', 'three', 'four', 'five' })
  M.write(d .. '/b.txt', { 'bee' })
  M.git(d, 'add', '.')
  M.git(d, 'commit', '-q', '-m', 'first')
  return d
end

function M.eq(want, got, what)
  if not vim.deep_equal(want, got) then
    error(('%s\n  want: %s\n   got: %s'):format(what or 'not equal', vim.inspect(want), vim.inspect(got)), 2)
  end
end

function M.ok(cond, what)
  if not cond then
    error(what or 'expected true', 2)
  end
  return cond
end

--- Seq numbers of `events` go up by exactly one, starting after `from`.
function M.no_gaps(events, from)
  local want = from
  for _, ev in ipairs(events) do
    want = want + 1
    if ev.seq ~= want then
      error(('seq gap: want %d, got %d (%s)'):format(want, ev.seq, ev.reason), 2)
    end
  end
end

return M

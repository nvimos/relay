-- The git repo of Neovim's current directory, and a git runner for it.
local M = {}

local function abs(dir, p)
  p = vim.fs.normalize(p)
  if not p:match('^%a:/') and not p:match('^/') then
    p = vim.fs.normalize(vim.fs.joinpath(dir, p))
  end
  return p
end

--- { cwd, root, git_dir, common_dir } for `cwd` (default: Neovim's cwd), or nil outside a repo.
function M.info(cwd)
  cwd = vim.fs.normalize(cwd or vim.fn.getcwd())
  local r = vim.system({ 'git', 'rev-parse', '--show-toplevel', '--absolute-git-dir', '--git-common-dir' }, {
    cwd = cwd,
    text = true,
  }):wait()
  if r.code ~= 0 then
    return nil
  end
  local out = vim.split(vim.trim(r.stdout), '\n')
  return {
    cwd = cwd,
    root = vim.fs.normalize(out[1]),
    git_dir = vim.fs.normalize(out[2]),
    common_dir = abs(cwd, out[3]),
  }
end

local roots = {} -- cwd -> repo root; a git call per lookup is far too slow on Windows

--- Root of the current repo; errors outside one. Cached per cwd.
function M.root()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  if roots[cwd] then
    return roots[cwd]
  end
  local info = M.info(cwd)
  if not info then
    error('nvimos: ' .. cwd .. ' is not in a git repo', 0)
  end
  roots[cwd] = info.root
  return info.root
end

--- Branch name of HEAD, or the short sha when detached, read from the HEAD file (no git call).
function M.head(git_dir)
  local f = io.open(git_dir .. '/HEAD', 'r')
  if not f then
    return nil
  end
  local line = vim.trim(f:read('*l') or '')
  f:close()
  local ref = line:match('^ref: refs/heads/(.+)$')
  return ref or line:sub(1, 8)
end

--- Run git in the repo root. opts.stdin, opts.ok_codes (default { 0 }). Returns stdout; errors with
--- stderr otherwise.
function M.git(args, opts)
  opts = opts or {}
  -- --no-optional-locks: reads like `git status` must not rewrite the index, or the git dir
  -- watcher reports a change, the GUI refreshes with another `git status`, and so on forever.
  local cmd = { 'git', '--no-optional-locks', '-c', 'core.quotepath=false', '-c', 'color.ui=false' }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { cwd = opts.cwd or M.root(), text = true, stdin = opts.stdin }):wait()
  local ok = false
  for _, c in ipairs(opts.ok_codes or { 0 }) do
    ok = ok or r.code == c
  end
  if not ok then
    error(('nvimos: git %s: %s'):format(args[1], vim.trim(r.stderr ~= '' and r.stderr or r.stdout)), 0)
  end
  return r.stdout
end

--- Absolute, normalized path for a path relative to the repo root (or already absolute).
function M.path(p)
  p = vim.fs.normalize(p)
  if p:match('^%a:/') or p:match('^/') then
    return p
  end
  return vim.fs.normalize(vim.fs.joinpath(M.root(), p))
end

return M

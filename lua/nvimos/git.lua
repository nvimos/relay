-- Git commands for the GUI, run inside Neovim in the repo of its cwd. Read functions return
-- parsed data; write functions change the repo and reload affected buffers.
local repo = require('nvimos.repo')
local diffparse = require('nvimos.diffparse')

local M = {}

local SEP = '\31' -- unit separator: safe inside subjects, and git's format accepts %x1f

local DIFF = { 'diff', '--no-ext-diff', '--no-color', '-M', '--src-prefix=a/', '--dst-prefix=b/' }

local function diff_args(extra)
  local args = vim.deepcopy(DIFF)
  vim.list_extend(args, extra)
  return args
end

local function lines(text)
  local out = vim.split(text, '\n', { plain = true, trimempty = true })
  return out
end

--- Local branches: { current, branches = { { name, sha, upstream, current, date, subject } } }.
function M.branches()
  local fmt = table.concat({
    '%(refname:short)',
    '%(objectname:short)',
    '%(upstream:short)',
    '%(HEAD)',
    '%(committerdate:unix)',
    '%(contents:subject)',
  }, '%1f')
  local out = repo.git({ 'for-each-ref', '--format=' .. fmt, 'refs/heads' })
  local list = {}
  for _, l in ipairs(lines(out)) do
    local f = vim.split(l, SEP, { plain = true })
    list[#list + 1] = {
      name = f[1],
      sha = f[2],
      upstream = f[3],
      current = f[4] == '*',
      date = tonumber(f[5]),
      subject = f[6] or '',
    }
  end
  local info = repo.info()
  return { current = info and repo.head(info.git_dir) or vim.NIL, branches = list }
end

--- Commits in base..head, newest first: { { sha, short, author, date, subject } }.
function M.log(base, head, max)
  local fmt = table.concat({ '%H', '%h', '%an', '%at', '%s' }, '%x1f')
  local out = repo.git({ 'log', '--format=' .. fmt, '-n', tostring(max or 500), base .. '..' .. head, '--' })
  local list = {}
  for _, l in ipairs(lines(out)) do
    local f = vim.split(l, SEP, { plain = true })
    list[#list + 1] = { sha = f[1], short = f[2], author = f[3], date = tonumber(f[4]), subject = f[5] or '' }
  end
  return list
end

--- What head changed since it left base (base...head), like a pull request.
--- { base, head, merge_base, files } with files from diffparse.
function M.diff(base, head)
  local mb = vim.trim(repo.git({ 'merge-base', base, head }))
  return {
    base = base,
    head = head,
    merge_base = mb,
    files = diffparse.parse(repo.git(diff_args({ base .. '...' .. head, '--' }))),
  }
end

local CONFLICT = { DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true }

--- Working tree vs HEAD: { branch, files = { { path, orig, index, worktree, staged, unstaged,
--- untracked, conflicted } } }. index/worktree are git's X and Y status letters.
function M.status()
  local out = repo.git({ 'status', '--porcelain=v1', '-z', '--untracked-files=all' })
  local parts = vim.split(out, '\0', { plain = true })
  local files = {}
  local i = 1
  while i <= #parts do
    local e = parts[i]
    if #e >= 4 then
      local x, y, path = e:sub(1, 1), e:sub(2, 2), e:sub(4)
      local f = {
        path = path,
        index = x,
        worktree = y,
        untracked = x == '?',
        conflicted = CONFLICT[x .. y] == true,
      }
      f.staged = x ~= ' ' and x ~= '?' and not f.conflicted
      f.unstaged = y ~= ' ' and y ~= '?' and not f.conflicted
      if x == 'R' or x == 'C' then
        i = i + 1
        f.orig = parts[i]
      end
      files[#files + 1] = f
    end
    i = i + 1
  end
  local info = repo.info()
  return { branch = info and repo.head(info.git_dir) or vim.NIL, files = files }
end

local function untracked(path)
  local out = repo.git({ 'status', '--porcelain=v1', '--untracked-files=all', '--', path })
  return out:sub(1, 2) == '??'
end

-- Raw diff of one file: staged (index vs HEAD) or unstaged (work tree vs index; an untracked file
-- shows as all added).
function M._diff_file_raw(path, staged)
  if staged then
    return diffparse.parse(repo.git(diff_args({ '--cached', '--', path })), true)[1]
  end
  if untracked(path) then
    local out = repo.git(diff_args({ '--no-index', '--', '/dev/null', path }), { ok_codes = { 0, 1 } })
    local f = diffparse.parse(out, true)[1]
    if f then
      f.status, f.path, f.untracked = 'added', path, true
    end
    return f
  end
  return diffparse.parse(repo.git(diff_args({ '--', path })), true)[1]
end

--- Hunks of one file: staged = index vs HEAD, otherwise work tree vs index. nil if no changes.
function M.diff_file(path, staged)
  local f = M._diff_file_raw(path, staged)
  if not f then
    return vim.NIL
  end
  f._header = nil
  for _, hk in ipairs(f.hunks) do
    hk._raw = nil
  end
  return f
end

return M

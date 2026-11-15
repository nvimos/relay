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

-- Writes ---------------------------------------------------------------------------------------

local api = vim.api

local function loaded_buf(path)
  local full = vim.fs.normalize(repo.path(path)):lower()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.fs.normalize(api.nvim_buf_get_name(buf)):lower() == full then
      return buf
    end
  end
end

-- Refuse to touch a file whose buffer has unsaved changes.
local function guard(path)
  local buf = loaded_buf(path)
  if buf and vim.bo[buf].modified then
    error('nvimos: ' .. path .. ' has unsaved changes in Neovim', 0)
  end
end

-- Reload buffers whose files changed on disk ('autoread' is on by default).
local function reload(path)
  local buf = path and loaded_buf(path)
  if path and not buf then
    return
  end
  vim.cmd.checktime(buf)
end

-- Find the hunk with these start lines in a fresh diff, as a patch for git apply.
local function hunk_patch(path, staged, hunk)
  local f = M._diff_file_raw(path, staged)
  if not f then
    error('nvimos: no changes in ' .. path, 0)
  end
  for _, hk in ipairs(f.hunks) do
    if hk.old_start == hunk.old_start and hk.new_start == hunk.new_start then
      local patch = vim.list_extend(vim.deepcopy(f._header), hk._raw)
      return table.concat(patch, '\n') .. '\n', f
    end
  end
  error('nvimos: that hunk of ' .. path .. ' changed; refresh and try again', 0)
end

--- Stage a whole file (also deletions).
function M.stage(path)
  repo.git({ 'add', '-A', '--', path })
  return true
end

--- Unstage a whole file.
function M.unstage(path)
  local ok = pcall(repo.git, { 'restore', '--staged', '--', path })
  if not ok then -- no commit yet
    repo.git({ 'rm', '--cached', '-q', '--', path })
  end
  return true
end

--- Throw away the unstaged changes of a file (work tree back to the index). An untracked file is
--- deleted.
function M.discard(path)
  guard(path)
  local st = M.status()
  for _, f in ipairs(st.files) do
    if f.path == path and f.untracked then
      os.remove(repo.path(path))
      reload(path)
      return true
    end
  end
  repo.git({ 'restore', '--', path })
  reload(path)
  return true
end

--- Stage one hunk of the unstaged diff. hunk = { old_start, new_start } as diff_file returned it.
--- For an untracked file the whole file is staged.
function M.stage_hunk(path, hunk)
  local patch, f = hunk_patch(path, false, hunk)
  if f.untracked then
    return M.stage(path)
  end
  repo.git({ 'apply', '--cached', '--whitespace=nowarn', '-' }, { stdin = patch })
  return true
end

--- Unstage one hunk of the staged diff.
function M.unstage_hunk(path, hunk)
  local patch = hunk_patch(path, true, hunk)
  repo.git({ 'apply', '--cached', '--reverse', '--whitespace=nowarn', '-' }, { stdin = patch })
  return true
end

--- Throw away one hunk of the unstaged diff in the work tree.
function M.discard_hunk(path, hunk)
  guard(path)
  local patch, f = hunk_patch(path, false, hunk)
  if f.untracked then
    return M.discard(path)
  end
  repo.git({ 'apply', '--reverse', '--whitespace=nowarn', '-' }, { stdin = patch })
  reload(path)
  return true
end

--- Refuse to switch branches or merge over unsaved buffers or uncommitted changes to tracked files.
local function require_clean(what, allow_changes)
  local root = repo.root():lower()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = vim.fs.normalize(api.nvim_buf_get_name(buf)):lower()
    if vim.bo[buf].modified and name:sub(1, #root) == root then
      error('nvimos: unsaved changes in ' .. api.nvim_buf_get_name(buf), 0)
    end
  end
  if not allow_changes and vim.trim(repo.git({ 'status', '--porcelain', '--untracked-files=no' })) ~= '' then
    error('nvimos: commit or discard your changes before ' .. what, 0)
  end
end

--- Switch to a branch. Refuses with uncommitted changes to tracked files or unsaved buffers, unless
--- `how` says what to do with the changes: 'stash' stashes them first (put back when the checkout
--- fails), 'force' throws them away. Unsaved buffers always refuse.
function M.checkout(branch, how)
  if how == vim.NIL then
    how = nil
  end
  require_clean('switching branches', how ~= nil)
  if how == 'stash' then
    local msg = 'nvimos: before switching to ' .. branch
    repo.git({ 'stash', 'push', '-q', '-m', msg })
    local ok, err = pcall(repo.git, { 'checkout', '-q', branch })
    if not ok then
      pcall(repo.git, { 'stash', 'pop', '-q' })
      reload()
      error(err, 0)
    end
  elseif how == 'force' then
    repo.git({ 'checkout', '-q', '-f', branch })
  else
    repo.git({ 'checkout', '-q', branch })
  end
  reload()
  return true
end

-- Merge `head` into `base` without a work tree, for a base that is not checked out here: the merge
-- commit is made in git's object store (merge-tree, commit-tree), and base moves with update-ref
-- guarded by its old value, so a base that moved meanwhile is not overwritten. The checkout, its
-- files and its buffers are not touched. A conflict changes nothing and names the files.
local function clean_merge(base, head)
  require_clean('merging', true)
  local root = repo.root()
  -- base checked out in another worktree (an agent's, say): update-ref would leave that folder stale
  local where = nil
  local path = nil
  for _, line in ipairs(lines(repo.git({ 'worktree', 'list', '--porcelain' }))) do
    path = line:match('^worktree (.+)$') or path
    if line == 'branch refs/heads/' .. base then
      where = path
    end
  end
  if where and vim.fs.normalize(where) ~= vim.fs.normalize(root) then
    error(('nvimos: %s is checked out in %s; merge it there or detach that worktree'):format(base, where), 0)
  end
  local old = vim.trim(repo.git({ 'rev-parse', '--verify', 'refs/heads/' .. base }))
  local head_sha = vim.trim(repo.git({ 'rev-parse', '--verify', 'refs/heads/' .. head }))
  -- merge-tree exits 0 when clean, 1 with conflicts (its output then starts with the tree and lists the files)
  local r = vim.system({ 'git', '-c', 'core.quotepath=false', 'merge-tree', '--write-tree', '--name-only', base, head },
    { cwd = root, text = true }):wait()
  if r.code ~= 0 and r.code ~= 1 then
    error('nvimos: git merge-tree: ' .. vim.trim(r.stderr ~= '' and r.stderr or r.stdout), 0)
  end
  local out = lines(r.stdout)
  if r.code == 1 then
    local files = {}
    for i = 2, #out do
      if out[i] == '' then
        break
      end
      table.insert(files, out[i])
    end
    error('nvimos: merge conflict in ' .. table.concat(files, ', ') .. ' (nothing changed)', 0)
  end
  local commit = vim.trim(repo.git({
    'commit-tree', vim.trim(out[1]), '-p', old, '-p', head_sha,
    '-m', ("Merge branch '%s' into %s"):format(head, base),
  }))
  local moved = pcall(repo.git, { 'update-ref', '-m', ('nvimos: merge %s into %s'):format(head, base), 'refs/heads/' .. base, commit, old })
  if not moved then
    error(('nvimos: base moved during the merge: %s is at a new commit; nothing was saved'):format(base), 0)
  end
  return commit
end

--- Merge `head` into the local branch `base` with a merge commit (`--no-ff`). When `base` is not the
--- branch checked out here, the merge is made without a work tree (see clean_merge). Local only:
--- nothing is pushed. A conflict on the checked-out path is undone (`merge --abort`) and reported with
--- the files; returns the new base's sha.
function M.merge(base, head)
  if base == head then
    error('nvimos: base and head are the same', 0)
  end
  local ok = pcall(repo.git, { 'show-ref', '--verify', '-q', 'refs/heads/' .. base })
  if not ok then
    error('nvimos: the base must be a local branch: ' .. base, 0)
  end
  if vim.trim(repo.git({ 'rev-list', '--count', base .. '..' .. head })) == '0' then
    error(('nvimos: %s has nothing that %s lacks'):format(head, base), 0)
  end
  local current = vim.trim(repo.git({ 'branch', '--show-current' }))
  if current ~= base then
    return clean_merge(base, head)
  end
  require_clean('merging')
  local merged, err = pcall(repo.git, { 'merge', '--no-ff', '-m', ("Merge branch '%s' into %s"):format(head, base), head })
  if not merged then
    local files = vim.trim(repo.git({ 'diff', '--name-only', '--diff-filter=U' }))
    pcall(repo.git, { 'merge', '--abort' })
    reload()
    if files ~= '' then
      error('nvimos: merge conflict in ' .. table.concat(vim.split(files, '\n'), ', ') .. ' (merge undone)', 0)
    end
    error(err, 0)
  end
  reload()
  return vim.trim(repo.git({ 'rev-parse', 'HEAD' }))
end

--- Rebase the local branch `head` onto `base`, checking `head` out first when it is not the current
--- branch. Local only: nothing is pushed. A conflict is undone (`rebase --abort`) and reported with
--- the files. Returns 'up-to-date' when `head` already has all of `base`, else the new HEAD's sha.
function M.rebase(base, head)
  if base == head then
    error('nvimos: base and head are the same', 0)
  end
  local ok = pcall(repo.git, { 'show-ref', '--verify', '-q', 'refs/heads/' .. head })
  if not ok then
    error('nvimos: the head must be a local branch: ' .. head, 0)
  end
  if vim.trim(repo.git({ 'rev-list', '--count', head .. '..' .. base })) == '0' then
    return 'up-to-date'
  end
  require_clean('rebasing')
  local current = vim.trim(repo.git({ 'branch', '--show-current' }))
  if current ~= head then
    repo.git({ 'checkout', '-q', head })
  end
  local rebased, err = pcall(repo.git, { 'rebase', base })
  if not rebased then
    local files = vim.trim(repo.git({ 'diff', '--name-only', '--diff-filter=U' }))
    pcall(repo.git, { 'rebase', '--abort' })
    reload()
    if files ~= '' then
      error('nvimos: rebase conflict in ' .. table.concat(vim.split(files, '\n'), ', ') .. ' (rebase undone)', 0)
    end
    error(err, 0)
  end
  reload()
  return vim.trim(repo.git({ 'rev-parse', 'HEAD' }))
end

--- Commit the index with `message`. Returns the new commit's sha.
function M.commit(message)
  if vim.trim(message or '') == '' then
    error('nvimos: empty commit message', 0)
  end
  repo.git({ 'commit', '-q', '-F', '-' }, { stdin = message })
  return vim.trim(repo.git({ 'rev-parse', 'HEAD' }))
end

return M

-- A merge with conflicts, finished in a worktree of Ops's own (TASK-146, TASK-151 to TASK-153): the
-- main checkout never sees a conflict marker. A pre-flight with `git merge-tree` tells whether a
-- merge would conflict before anything changes. Each function reads or writes one worktree or
-- one of its files; the Ops state keeps the path.
local repo = require('nvimos.repo')

local M = {}

local MARKERS = { '^<<<<<<<', '^=======$', '^>>>>>>>' }

local function lines(text)
  return vim.split(text, '\n', { plain = true, trimempty = true })
end

-- Windows files end their lines in CRLF: the marker patterns match without the carriage return.
local function bare(line)
  return (line:gsub('\r$', ''))
end

local function is_marker(line)
  for _, pat in ipairs(MARKERS) do
    if bare(line):match(pat) then
      return true
    end
  end
  return false
end

--- The files a merge of `head` into `base` would conflict on, read only: nothing in the repo changes.
--- Returns an empty list when the merge is clean.
function M.preflight(base, head)
  local r = vim.system({ 'git', '-c', 'core.quotepath=false', 'merge-tree', '--write-tree', '--name-only', base, head },
    { cwd = repo.root(), text = true }):wait()
  if r.code == 0 then
    return {}
  end
  if r.code ~= 1 then
    error('nvimos: git merge-tree: ' .. vim.trim(r.stderr ~= '' and r.stderr or r.stdout), 0)
  end
  local out = lines(r.stdout)
  local files = {}
  for i = 2, #out do
    if out[i] == '' then
      break
    end
    table.insert(files, out[i])
  end
  return files
end

--- Files still unmerged in the worktree at `path`.
function M.unmerged(path)
  local out = vim.trim(repo.git({ 'diff', '--name-only', '--diff-filter=U' }, { cwd = path }))
  return out == '' and {} or lines(out)
end

--- Where the merge worktree for `head` lives: %TEMP%\nvimos-ops\merge.<repo>.<branch>, `/` in the
--- branch name becomes `-`.
function M.path_for(head)
  local dir = vim.fs.joinpath(vim.env.TEMP, 'nvimos-ops')
  return vim.fs.joinpath(dir, ('merge.%s.%s'):format(vim.fs.basename(repo.root()), (head:gsub('/', '-'))))
end

local function remove_worktree(path)
  pcall(repo.git, { 'worktree', 'remove', '--force', path })
  repo.git({ 'worktree', 'prune' })
  if vim.uv.fs_stat(path) then
    vim.fn.delete(path, 'rf')
  end
end

--- Start the merge of `head` into `base` in its worktree, detached at base's commit, and leave it
--- in progress (`merge --no-commit`). Returns { path, files } with the conflicted files (empty when
--- the merge is clean; it is still in progress, finish commits it). A worktree left from before is
--- removed first.
function M.start(base, head)
  local path = M.path_for(head)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  remove_worktree(path)
  repo.git({ 'worktree', 'add', '--detach', path, base })
  local r = vim.system({ 'git', 'merge', '--no-commit', '--no-ff', head }, { cwd = path, text = true }):wait()
  local files = M.unmerged(path)
  if r.code ~= 0 and #files == 0 then
    remove_worktree(path)
    error('nvimos: git merge: ' .. vim.trim(r.stderr ~= '' and r.stderr or r.stdout), 0)
  end
  return { path = path, files = files }
end

--- The conflict hunks of a file in the worktree, in order. Each hunk: { ours = {...}, theirs = {...} }
--- with the lines of each side, as they stand between the markers.
function M.hunks(path, file)
  local text = vim.fn.readfile(vim.fs.joinpath(path, file))
  local out, cur, side = {}, nil, nil
  for _, line in ipairs(text) do
    if bare(line):match('^<<<<<<<') then
      cur = { ours = {}, theirs = {} }
      side = 'ours'
    elseif cur and bare(line):match('^=======$') then
      side = 'theirs'
    elseif cur and bare(line):match('^>>>>>>>') then
      table.insert(out, cur)
      cur, side = nil, nil
    elseif cur then
      table.insert(cur[side], line)
    end
  end
  return out
end

--- Replace conflict hunk number `index` of `file` with one side, `ours` or `theirs`. The other
--- hunks keep their markers.
function M.pick(path, file, index, side)
  if side ~= 'ours' and side ~= 'theirs' then
    error('nvimos: side must be ours or theirs', 0)
  end
  local full = vim.fs.joinpath(path, file)
  local text = vim.fn.readfile(full)
  local out, n, cur, mode, keep = {}, 0, nil, nil, nil
  for _, line in ipairs(text) do
    if bare(line):match('^<<<<<<<') then
      n = n + 1
      cur = { raw = { line }, ours = {}, theirs = {} }
      mode = 'ours'
    elseif cur and bare(line):match('^=======$') then
      table.insert(cur.raw, line)
      mode = 'theirs'
    elseif cur and bare(line):match('^>>>>>>>') then
      table.insert(cur.raw, line)
      keep = n == index and cur[side] or cur.raw
      for _, l in ipairs(keep) do
        table.insert(out, l)
      end
      cur, mode = nil, nil
    elseif cur then
      table.insert(cur.raw, line)
      table.insert(cur[mode], line)
    else
      table.insert(out, line)
    end
  end
  if n < index then
    error(('nvimos: %s has no conflict hunk %d'):format(file, index), 0)
  end
  vim.fn.writefile(out, full)
end

--- Mark a file resolved (`git add`), refused while it still has a conflict marker at the start of a line.
function M.add(path, file)
  local text = vim.fn.readfile(vim.fs.joinpath(path, file))
  for i, line in ipairs(text) do
    if is_marker(line) then
      error(('nvimos: %s still has a conflict marker at line %d (%s)'):format(file, i, vim.trim(line)), 0)
    end
  end
  repo.git({ 'add', '--', file }, { cwd = path })
end

--- Complete the merge in the worktree: verify (no unmerged path, no marker in a staged file), commit,
--- then move `base` to the merge commit with update-ref, guarded by the commit it had before. The
--- worktree is removed afterwards. Refused when `base` is checked out in the main checkout (the folder
--- would be left behind) or when `base` moved. Returns the merge commit's sha.
function M.finish(base, head, path)
  local left = M.unmerged(path)
  if #left > 0 then
    error('nvimos: still unresolved: ' .. table.concat(left, ', '), 0)
  end
  for _, file in ipairs(vim.split(vim.trim(repo.git({ 'diff', '--cached', '--name-only' }, { cwd = path })), '\n', { plain = true, trimempty = true })) do
    for i, line in ipairs(vim.fn.readfile(vim.fs.joinpath(path, file))) do
      if is_marker(line) then
        error(('nvimos: %s has a conflict marker at line %d; nothing was committed'):format(file, i), 0)
      end
    end
  end
  if vim.trim(repo.git({ 'branch', '--show-current' })) == base then
    error(('nvimos: %s is checked out in the main checkout; switch to another branch first'):format(base), 0)
  end
  local old = vim.trim(repo.git({ 'rev-parse', '--verify', 'refs/heads/' .. base }))
  repo.git({ 'commit', '-q', '-m', ("Merge branch '%s' into %s"):format(head, base) }, { cwd = path })
  local commit = vim.trim(repo.git({ 'rev-parse', 'HEAD' }, { cwd = path }))
  local moved = pcall(repo.git, { 'update-ref', '-m', 'nvimos: merge into ' .. base, 'refs/heads/' .. base, commit, old })
  if not moved then
    error(('nvimos: base moved during the merge: %s is at a new commit; the merge commit is kept in %s'):format(base, path), 0)
  end
  remove_worktree(path)
  return commit
end

--- Throw the merge away: `merge --abort` and remove the worktree.
function M.abort(path)
  pcall(repo.git, { 'merge', '--abort' }, { cwd = path })
  remove_worktree(path)
end

return M
